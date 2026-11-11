# Nios II + Ethernet (DHCP / Web Server) + USER HW — Cyclone 10 LP

Execução do tutorial Nios com interface Ethernet e um USER HW específico, na placa
**Intel Cyclone 10 LP FPGA Evaluation Kit** (10CL025YU256I7G, PHY Gigabit PEF7071 em RGMII).

> **Por que Cyclone 10 LP e não DE2?** O Quartus instalado (17.1 Lite) não tem suporte à
> família Cyclone II da DE2; o último Quartus com Cyclone II é o 13.0sp1.

## Uso rápido (em qualquer computador)

O arquivo `hw/output_files/nios_eth.sof` já contém o hardware **e** o software do Nios.
Só é preciso o **Quartus Prime Programmer** 17.1 ou mais novo (Lite ou Standalone Programmer).

1. Ligue o cabo Ethernet da placa numa porta LAN do roteador e ponha o PC na mesma rede
   (Wi-Fi ou cabo). Ligue a placa na USB.
2. Programe:

   ```bash
   quartus_pgm -m jtag -o "p;hw/output_files/nios_eth.sof"
   ```

3. Veja o IP obtido por DHCP com `nios2-terminal`. Ele é repetido a cada 10 s; os LEDs
   indicam: LED0 aceso = IP obtido. Também dá para olhar a lista de DHCP do roteador,
   onde a placa aparece como `nios-c10`.
4. Abra `pc/client.html` no navegador, informe o IP e envie a string.

## Mapa dos requisitos

| # | Requisito | Onde está |
|---|-----------|-----------|
| 1 | Web server no Nios | `sw/app/net.c` (TCP porta 80 + HTTP/1.1). `GET /` devolve a página `sw/app/page.h` |
| 2 | Cliente no PC que transmite e recebe | `pc/client.html` (usa `fetch` para `http://<ip>/api?h=<hex>`) |
| 3 | DHCP no Nios | `net.c`: cliente DHCP completo (DISCOVER → OFFER → REQUEST → ACK, renovação em T1) |
| 4 | PC e placa no mesmo servidor DHCP | Os dois ligados no mesmo roteador/switch da rede (ver "Execução") |
| 5 | Duas threads (RX e TX) | `sw/app/main.c`: `rx_task` (IRQ do MAC → recepção) e `tx_task` (fila `OSQ` → transmissão), sobre MicroC/OS-II |
| 6 | Página HTML com string de até 100 caracteres | `pc/client.html` (`maxlength=100`, abre direto do disco) |
| 7 | USER HW: +1 em cada caractere, 0xF7 → 0x00 | `hw/ip/user_hw/user_hw.v` (componente Qsys, 1 caractere por ciclo) |
| 8 | Placa devolve a string e o PC mostra | Resposta JSON `{"in","out",...}` exibida em `client.html` (texto + tabela hex) |
| 9 | IPs obrigatoriamente por DHCP | A placa só ganha IP via DHCP (não há IP fixo no código); o PC usa DHCP normal |
| 10 | Signal Tap | `hw/nios_eth.stp`: chegada de quadro, transmissão de quadro e processamento do USER HW |

## Arquitetura

```
 PC (navegador, client.html) ── switch/roteador com DHCP ── RJ45 ── PHY PEF7071
                                                                   │ RGMII 100 Mbit/s
 ┌────────────────────────────── FPGA 10CL025 ───────────────────────┴───────────┐
 │  PLL: 50 MHz → 50 MHz (sistema), 25 MHz/0° (TX), 25 MHz/90° (TXC p/ PHY)       │
 │                                                                                │
 │  Nios II/e ── Avalon ──┬─ RAM on-chip 44 KB (código + dados)                   │
 │  (MicroC/OS-II)        ├─ eth_rgmii_mac (próprio): RX 2×2 KB, TX 2 KB, CRC32, IRQ│
 │                        ├─ user_hw (próprio): string +1 / 0xF7→0                 │
 │                        ├─ PIO MDC/RESET + PIO MDIO (gerência do PHY)            │
 │                        ├─ PIO LEDs, PIO DIP, timer 1 ms, JTAG UART, sysid       │
 │  Signal Tap (1024 amostras × 71 sinais, clock de 50 MHz)                        │
 └────────────────────────────────────────────────────────────────────────────────┘
```

**Por que um MAC e uma pilha TCP/IP próprios, e não TSE + NicheStack do tutorial?**
O kit não tem SDRAM; a memória externa é uma HyperRAM que só funciona com o IP HBMC da
Synaptic Labs (não incluído no Quartus). Sobram ~66 KB de memória on-chip, e o exemplo
`web_server` com NicheStack precisa de centenas de KB. Por isso o projeto usa:

* **MAC RGMII 10/100 em Verilog** (`eth_rgmii_mac.v`): preâmbulo/SFD, filtro de MAC
  (unicast próprio + broadcast), CRC-32 em HW na TX e verificação na RX, padding
  automático, IFG e buffers dual-clock. O software configura o PHY por MDIO para anunciar
  **só 100BASE-TX**, então o link sempre sobe a 100 Mbit/s (RGMII a 25 MHz).
* **Pilha mínima em C** (`net.c`, ~10 KB): Ethernet II, ARP, IPv4, ICMP (ping), UDP,
  cliente DHCP, servidor TCP (4 conexões, retransmissão) e HTTP/1.1.
* **MicroC/OS-II** do Nios II EDS, com duas tasks:
  * `rx_task` (prioridade 5): bloqueia num semáforo liberado pela **IRQ do MAC**, copia os
    quadros e os processa (ARP, ICMP, DHCP, TCP/HTTP e chamada ao USER HW). As respostas
    vão para a fila de transmissão.
  * `tx_task` (prioridade 4): é a **única dona do transmissor**. Tira pacotes da fila
    `OSQ` e os escreve no MAC; a cada 100 ms também roda a temporização da pilha
    (envio de DHCP DISCOVER/REQUEST, renovação e retransmissões TCP).

### Mapas de registradores

`eth_mac` (base `0x24000`): janela RX `0x0000`, buffer TX `0x0800`, `STATUS 0x1000`,
`RX_LEN 0x1004`, `RX_POP 0x1008`, `TX_LEN 0x100C` (dispara), `MAC_LO/HI 0x1010/0x1014`,
`IRQ_EN 0x1018` e contadores em `0x101C–0x1028`.

`user_hw` (base `0x21200`): `CTRL 0x000` (W: bit0 = start; R: bit0 busy, bit1 done),
`LEN 0x004`, `COUNT 0x008`, entrada `0x080–0x0FF`, saída `0x100–0x17F`.

## Estrutura

```
nios_eth_web/
├── hw/
│   ├── ip/eth_rgmii_mac/   eth_rgmii_mac.v + _hw.tcl   (componente Qsys)
│   ├── ip/user_hw/         user_hw.v + _hw.tcl         (componente Qsys)
│   ├── soc_qsys.tcl        script que monta o soc.qsys no Platform Designer
│   ├── nios_eth_top.v      top-level (PLL + SoC + pinos)
│   ├── nios_eth.qpf/.qsf   projeto Quartus (pinos do kit)
│   ├── nios_eth_top.sdc    restrições de timing
│   ├── gen_stp.py → nios_eth.stp   configuração do Signal Tap
│   ├── sim/tb_eth.v        testbench ModelSim (MAC em loopback + USER HW)
│   └── build_hw.sh         gera Qsys + Signal Tap e compila
├── sw/
│   ├── app/                main.c, eth.c/h, net.c/h, user_hw.c, page.h
│   └── create_sw.sh        cria o BSP MicroC/OS-II e compila nios_eth.elf
├── pc/client.html          cliente do PC
└── run_board.sh            programa a FPGA, carrega o .elf e abre o terminal
```

## Build (já feito; repita se alterar algo)

O software do Nios fica **embutido no `.sof`** (RAM on-chip inicializada com
`sw/app/mem_init/soc_ram.hex`). Basta programar a FPGA, e o Nios começa a rodar
sozinho; num PC de laboratório só é preciso o Quartus Programmer.

Build completo (Qsys → software → hex da RAM → Signal Tap → Quartus), no **Git Bash** ou no
**Nios II Command Shell**:

```bash
cd /c/intelFPGA_lite/17.1/nios_eth_web/hw && ./build_hw.sh
```

Se mudar **só o código C** (sem mexer no Qsys), não é preciso recompilar o hardware:

```bash
cd /c/intelFPGA_lite/17.1/nios_eth_web/sw/app && make && make mem_init_generate
```

```bash
cd /c/intelFPGA_lite/17.1/nios_eth_web/hw && quartus_cdb nios_eth --update_mif && quartus_asm nios_eth
```

Resultado atual: ~7,5 mil LEs (31 %), 63/66 M9K, timing fechado em todos os clocks,
software com 41,5 KB de 44 KB.
Para abrir no GUI: `hw/nios_eth.qpf` no Quartus e `hw/soc.qsys` no Platform Designer.

Simulação (opcional):

```bash
cd /c/intelFPGA_lite/17.1/nios_eth_web/hw/sim && vsim -c -do run_tb.do
```

Deve terminar com `*** TODOS OS TESTES PASSARAM ***`: o FCS confere com o CRC-32 padrão,
o RX recebe com CRC OK, há padding, o filtro de MAC descarta quadros de outro destino e o
USER HW transforma `"ABC" 0xF7 0xFF "z"` → `"BCD" 0x00 0x00 "{"`.

### Teste da pilha de rede no Linux (sem a placa)

`sw/test_host/` compila o **mesmo `net.c` da placa** no Linux (WSL), com stubs do
MicroC/OS-II e duas threads POSIX no papel da `rx_task` e da `tx_task`. Ele é ligado a uma
interface TAP, com um servidor DHCP real (`dnsmasq`) e a pilha TCP do Linux do outro lado. O
filtro de MAC e o padding do hardware são emulados, e é possível simular perda de pacotes.
Requer `gcc`, `dnsmasq-base` e `tcpdump` no Ubuntu do WSL.

```bash
wsl -d Ubuntu -u root -- bash -c "bash /mnt/c/intelFPGA_lite/17.1/nios_eth_web/sw/test_host/run_test.sh 0 1"
```

```bash
wsl -d Ubuntu -u root -- bash -c "STRESS=200 bash /mnt/c/intelFPGA_lite/17.1/nios_eth_web/sw/test_host/run_test.sh 20"
```

O primeiro argumento é a perda em % (nos dois sentidos) e o segundo, `1`, espera a renovação do
lease. Resultados obtidos:
* **sem perda:** 15/15. Inclui DHCP, ping, página, API (com 0xF7 e o limite de 100
  caracteres), preflight CORS, 404, 20 requisições sequenciais, 30 em paralelo (10
  simultâneas), renovação do lease e **nenhum RST**. Compilado com AddressSanitizer/UBSan,
  sem erros de memória.
* **20 % de perda:** 200/200 requisições **sem retry do curl**: as retransmissões TCP
  recuperam tudo.

Esses testes revelaram e corrigiram 3 problemas antes de ir para a placa: o timeout de
ociosidade TCP era menor que o backoff de retransmissão do cliente; conexões ativas eram
recicladas com a tabela cheia (agora são 6 posições); e o REQUEST do DHCP perdido só era
refeito após 4 s.

## Execução na placa

1. **Rede:** ligue o cabo Ethernet da placa no **mesmo roteador/switch** em que o PC está
   (o servidor DHCP da rede, por ex. o roteador do laboratório). O PC também deve estar
   em DHCP ("obter IP automaticamente"). Não ligue a placa direto no PC, porque não há
   servidor DHCP nesse caso.
2. Ligue a placa pela USB (USB-Blaster II on-board). Deixe a chave **SW1.4 em OFF**
   (Virtual JTAG habilitado, padrão de fábrica). As chaves USER_DIP0..2 definem o último
   byte do MAC (`02:10:C1:0A:00:1x`): use valores diferentes se houver várias placas na
   mesma rede.
3. Programe e rode:

   ```bash
   cd /c/intelFPGA_lite/17.1/nios_eth_web && ./run_board.sh
   ```

   O script mostra os cabos JTAG, grava o `.sof` (que já contém o software) e abre o
   `nios2-terminal`. O Nios repete o IP a cada 10 s, então ele aparece mesmo que o
   terminal abra depois do boot; para ver o log completo, aperte **USER_PB0** (reset).
   No terminal deve aparecer algo como:

   ```
   === Nios II Web Server (Cyclone 10 LP) ===
   MAC 02:10:C1:0A:00:10
   PHY: endereco 0 ID D565A401 ...
   PHY: link 100 Mbit/s OK
   DHCP: DISCOVER enviado
   DHCP: OFFER 192.168.0.57 do servidor 192.168.0.1
   DHCP: REQUEST enviado
   DHCP: ACK  ->  IP 192.168.0.57  mascara 255.255.255.0 ...
   >>> Abra http://192.168.0.57/ no navegador <<<
   ```

   LEDs: **LED0** aceso = IP obtido por DHCP, **LED1** pisca a cada quadro recebido,
   **LED2** a cada quadro transmitido, **LED3** = heartbeat (sistema vivo).
4. No PC, teste com `ping <ip>` e depois abra **`pc/client.html`** com duplo clique.
   Informe o IP, clique em *Testar conexão*, digite a string e clique em *Enviar*.
   A string modificada aparece na página, com uma tabela hex caractere a caractere.
   O mesmo formulário também é servido pela placa em `http://<ip>/`.

> **Chrome/Edge recentes** podem pedir permissão de "acesso à rede local" quando uma página
> aberta do disco acessa um IP privado: clique em *Permitir*. O servidor já responde ao
> preflight (`Access-Control-Allow-Private-Network`). No Firefox a página local funciona
> sem nenhum aviso.

## Signal Tap

O arquivo `hw/nios_eth.stp` já está compilado no `.sof` (1024 amostras a 50 MHz ≈ 20 µs).

1. Com a FPGA programada e o Nios rodando, abra no Quartus *Tools → Signal Tap Logic
   Analyzer → File → Open* `hw/nios_eth.stp`. O hardware e o dispositivo vêm preenchidos;
   confira o `.sof` (`output_files/nios_eth.sof`).
2. Clique em **Run Analysis** (F5). O trigger padrão é **`rx_sof == 1`, isto é, chegada de
   um pacote Ethernet** (SFD detectado). Na rede há broadcasts o tempo todo, então dispara
   logo. Para pegar um pacote da aplicação, faça `ping` ou envie uma string.

Sinais e o que mostram:

| Grupo | Sinais | Evento |
|-------|--------|--------|
| Chegada de pacote | `rgmii_rx_ctl`, `rx_dv`, `rx_nib`, `rx_state`, `rx_sof`, `rx_byte`, `rx_cnt_b`, `rx_is_uc/bc`, `rx_commit`, `irq`, `rx_pop_p` | preâmbulo → SFD → bytes → filtro de MAC → quadro entregue (`rx_commit`) → IRQ → Nios libera o buffer (`rx_pop_p`) |
| Transmissão de pacote | `tx_start_p`, `tx_state`, `tx_en` (= TX_CTL), `rgmii_txd`, `tx_done_p` | Nios dispara → preâmbulo → dados → FCS → IFG |
| USER HW | `start_p`, `busy`, `done`, `idx`, `cur_in`, `cur_out` | cada caractere entrando e saindo (+1 / 0xF7→0x00) |

Outros triggers úteis (clique na coluna *Trigger Conditions* do sinal):
* **Transmissão:** `tx_start_p` = High (ex.: resposta a um ping).
* **USER HW:** `start_p` = High e envie uma string pela página. Use `0xF7` (caractere `÷`)
  para ver a regra especial.

Para mudar os sinais, edite `hw/gen_stp.py` e rode de novo `./build_hw.sh`, que
regenera o `.stp` e as atribuições do `.qsf` via `quartus_stp --enable`.

## Solução de problemas

| Sintoma | Causa provável |
|---------|----------------|
| `jtagconfig`: "No JTAG hardware available"; Windows mostra "Dispositivo USB Desconhecido (Falha na Solicitação de Descritor)" ou "USB-Blaster II (Unconfigured)" com código 10 | Ligação USB física: cabo mini-USB só de carga ou gasto, hub/adaptador, porta com pouca corrente. Troque o cabo, ligue direto no PC ou use outro computador |
| `PHY: nao encontrado no MDIO` | Placa sem alimentação do PHY ou `.sof` errado; reprograme |
| `PHY: sem link` | Cabo/porta do switch; o switch precisa suportar 100 Mbit/s (todos suportam) |
| Fica em `DHCP: DISCOVER enviado` | Placa ligada direto no PC, sem servidor DHCP, ou porta isolada. Use o roteador do laboratório |
| `ping` funciona mas a página não | Firewall/proxy no PC, ou permissão de rede local negada no Chrome. Teste `http://<ip>/` direto |
| Nada no terminal | Feche outros `nios2-terminal`/Eclipse; rode `jtagconfig` e confira a chave SW1.4 = OFF |

Se o PHY mostrar link mas nenhum quadro chegar (LED1 nunca pisca), o problema é o
alinhamento RGMII. O RX amostra na borda de descida do RXC e o TXC sai com 90°
(`clk1_phase_shift` em `nios_eth_top.v`). Confira com o Signal Tap (`rgmii_rx_ctl`,
`rx_nib`) e com o valor de `MIICTRL(0x17)` impresso no terminal, que mostra o atraso
interno do PHY.
