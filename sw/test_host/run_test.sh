#!/bin/bash
# Teste de integracao da pilha de rede do Nios no Linux (WSL), como root:
#   wsl -d Ubuntu -u root -- bash run_test.sh [LOSS%] [RENEW]
# Sobe tap0 + dnsmasq (DHCP real), roda o harness e testa com ping/curl.
LOSS=${1:-0}
RENEW=${2:-0}
cd "$(dirname "$0")/.."
H=/root/harness
gcc -O1 -g -Wall -Wno-unused-variable -fsanitize=address,undefined \
    -Itest_host -Iapp -o $H test_host/harness.c app/net.c -lpthread || exit 1

pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

cleanup() {
    kill $HP $DP 2>/dev/null; wait 2>/dev/null
    ip link del tap0 2>/dev/null
}
trap cleanup EXIT
ip link del tap0 2>/dev/null
ip tuntap add dev tap0 mode tap
ip addr add 10.77.0.1/24 dev tap0
ip link set tap0 up

PCAP=/tmp/cap.pcap LOSS=$LOSS $H tap0 > /tmp/harness.log 2>&1 &
HP=$!
sleep 0.5
rm -f /tmp/dm.leases
dnsmasq --no-daemon --conf-file=/dev/null --interface=tap0 --bind-interfaces \
        --except-interface=lo --port=0 --dhcp-range=10.77.0.50,10.77.0.99,255.255.255.0,2m \
        --dhcp-leasefile=/tmp/dm.leases --log-dhcp > /tmp/dnsmasq.log 2>&1 &
DP=$!

echo "== perda simulada: ${LOSS}%"
IP=""
for i in $(seq 1 120); do
    IP=$(grep -oE "ACK  ->  IP [0-9.]+" /tmp/harness.log | head -1 | awk '{print $4}')
    [ -n "$IP" ] && break
    sleep 0.5
done
[ -n "$IP" ] && ok "DHCP: IP $IP obtido" || { bad "DHCP sem ACK"; cat /tmp/harness.log; exit 1; }
grep -q "$IP" /tmp/dm.leases && ok "lease registrada no dnsmasq" || bad "lease nao aparece no dnsmasq"

if [ "$LOSS" = 0 ]; then R=""; else R="--retry 5 --retry-all-errors"; fi
CURL="curl -s --max-time 10 $R"

ping -c 4 -W 1 -i 0.3 $IP > /tmp/ping.log && ok "ping ($(grep -oE '[0-9]+% packet loss' /tmp/ping.log))" || bad "ping"

out=$($CURL http://$IP/)
echo "$out" | grep -q "Nios II - Cyclone 10 LP" && ok "GET / (pagina, ${#out} bytes)" || bad "GET / -> '$out'"

out=$($CURL "http://$IP/api?h=414243f7ff7a")
echo "$out" | grep -q '"out":"42434400007b"' && ok "API ABC F7 FF z -> $out" || bad "API -> '$out'"

s100=$(python3 -c "print(''.join('%02x'%(0x21+i%90) for i in range(100)))")
e100=$(python3 -c "print(''.join('%02x'%((0x21+i%90)+1) for i in range(100)))")
out=$($CURL "http://$IP/api?h=$s100")
echo "$out" | grep -q "\"out\":\"$e100\"" && ok "API 100 caracteres" || bad "API 100 -> '$out'"

s120=$(python3 -c "print('41'*120)")
out=$($CURL "http://$IP/api?h=$s120")
echo "$out" | grep -q '"len":100' && ok "API limita a 100 caracteres" || bad "API 120 -> '$out'"

hdr=$(curl -s -i --max-time 10 $R -X OPTIONS -H "Access-Control-Request-Private-Network: true" "http://$IP/api?h=41")
echo "$hdr" | grep -q "204" && echo "$hdr" | grep -q "Allow-Private-Network: true" && ok "OPTIONS preflight (CORS/PNA)" || bad "OPTIONS -> $hdr"

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 $R http://$IP/favicon.ico)
[ "$code" = "404" ] && ok "404 para caminho desconhecido" || bad "favicon -> $code"

n=0
for i in $(seq 1 20); do
    out=$($CURL "http://$IP/api?h=6869")
    echo "$out" | grep -q '"out":"696a"' && n=$((n+1))
done
[ $n = 20 ] && ok "20 requisicoes sequenciais" || bad "sequenciais: $n/20"

seq 1 30 | xargs -P 10 -I{} sh -c "curl -s --max-time 30 $R 'http://$IP/api?h=3132' | grep -c '\"out\":\"3233\"'" > /tmp/par.log
n=$(grep -c 1 /tmp/par.log)
[ $n = 30 ] && ok "30 requisicoes em paralelo (10 simultaneas > 6 conexoes)" || bad "paralelas: $n/30"

if [ "$LOSS" != 0 ]; then
    n=0
    for i in $(seq 1 ${STRESS:-30}); do
        out=$(curl -s --max-time 60 "http://$IP/api?h=f7")
        if echo "$out" | grep -q '"out":"00"'; then n=$((n+1)); else echo "  falhou em $(date +%T.%N)"; fi
    done
    [ $n = ${STRESS:-30} ] && ok "${STRESS:-30} requisicoes com perda e SEM retry do curl (TCP recupera)" || bad "sem retry: $n/${STRESS:-30}"
fi

if [ "$RENEW" = 1 ]; then
    echo "== aguardando renovacao do lease (T1 = 60 s)..."
    sleep 70
    c=$(grep -c "DHCP: ACK" /tmp/harness.log)
    [ $c -ge 2 ] && ok "lease renovado ($c ACKs)" || bad "sem renovacao (ACKs=$c)"
    out=$($CURL "http://$IP/api?h=41")
    echo "$out" | grep -q '"out":"42"' && ok "API apos renovacao" || bad "API apos renovacao"
fi

sleep 1
nrst=$(tcpdump -nn -r /tmp/cap.pcap "src host $IP and tcp[tcpflags] & tcp-rst != 0" 2>/dev/null | wc -l)
if [ "$LOSS" = 0 ]; then
    [ "$nrst" = 0 ] && ok "nenhum RST enviado pela placa" || bad "placa enviou $nrst RST(s)"
else
    echo "info: RSTs enviados pela placa: $nrst"
fi
grep -E "ERROR|runtime error|esgotado" /tmp/harness.log && bad "harness reportou erros (ASan/UBSan/pool)" || ok "sem erros de memoria (ASan/UBSan)"
tail -1 /tmp/harness.log
echo "== RESULTADO: $pass PASS, $fail FAIL"
[ $fail = 0 ]
