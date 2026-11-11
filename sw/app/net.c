/* =============================================================================
 * net.c - pilha TCP/IP minima para o Nios II (sem alocacao dinamica)
 *   Ethernet II, ARP (responde), IPv4, ICMP echo (ping), UDP, cliente DHCP,
 *   TCP (servidor, porta 80) e HTTP/1.1 (GET / e GET /api?h=<hex>).
 * Todo acesso ao estado da pilha e' protegido pelo semaforo net_lock, pois e'
 * usado pela thread de recepcao (net_input) e pela de transmissao (tick).
 * Os campos sao lidos/escritos byte a byte (o Nios II/e nao faz acesso
 * desalinhado e o cabecalho IP fica no offset 14 do quadro).
 * ========================================================================== */
#include <string.h>
#include "includes.h"
#include "net.h"
#include "page.h"

uint8_t  my_mac[6];
uint32_t my_ip, my_mask, my_gw;

static OS_EVENT *net_lock;
#define LOCK()   do { INT8U e_; OSSemPend(net_lock, 0, &e_); } while (0)
#define UNLOCK() OSSemPost(net_lock)

/* ------------------------------------------------------------ pool de pacotes */
#define NPKT 3
static pkt_t    pool[NPKT];
static uint8_t  pool_used[NPKT];

pkt_t *pkt_alloc(void)
{
    int tries, i;
#if OS_CRITICAL_METHOD == 3
    OS_CPU_SR cpu_sr;
#endif
    for (tries = 0; tries < 500; tries++) {
        OS_ENTER_CRITICAL();
        for (i = 0; i < NPKT; i++) {
            if (!pool_used[i]) {
                pool_used[i] = 1;
                OS_EXIT_CRITICAL();
                return &pool[i];
            }
        }
        OS_EXIT_CRITICAL();
        net_tx_poll();          /* se for a thread TX, transmite a fila */
        OSTimeDly(1);
    }
    log_str("net: pool de pacotes esgotado\n");
    return 0;
}

void pkt_free(pkt_t *p)
{
    int i = p - pool;
    if (i >= 0 && i < NPKT) pool_used[i] = 0;
}

/* ------------------------------------------------------------ utilitarios */
static uint16_t rd16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static uint32_t rd32(const uint8_t *p)
{ return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | (p[2] << 8) | p[3]; }
static void wr16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void wr32(uint8_t *p, uint32_t v)
{ p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static uint32_t csum_add(uint32_t s, const uint8_t *p, int n)
{
    while (n > 1) { s += (p[0] << 8) | p[1]; p += 2; n -= 2; }
    if (n) s += p[0] << 8;
    return s;
}
static uint16_t csum_fold(uint32_t s)
{
    while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
    return ~s;
}

static uint32_t rnd_state = 0x1234567;
static uint32_t rnd(void)
{
    rnd_state ^= OSTimeGet();
    rnd_state = rnd_state * 1103515245u + 12345u;
    return rnd_state;
}

static const uint8_t bcast_mac[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

#define ETH_HLEN 14
#define IP_HLEN  20
#define OFS_IP   ETH_HLEN
#define OFS_L4   (ETH_HLEN + IP_HLEN)

static void build_eth(uint8_t *f, const uint8_t *dst, uint16_t type)
{
    memcpy(f, dst, 6);
    memcpy(f + 6, my_mac, 6);
    wr16(f + 12, type);
}

static uint16_t ip_id;
static void build_ip(uint8_t *f, uint8_t proto, uint32_t src, uint32_t dst, int l4len)
{
    uint8_t *ip = f + OFS_IP;
    ip[0] = 0x45; ip[1] = 0;
    wr16(ip + 2, IP_HLEN + l4len);
    wr16(ip + 4, ip_id++);
    wr16(ip + 6, 0x4000);              /* DF */
    ip[8] = 64; ip[9] = proto;
    wr16(ip + 10, 0);
    wr32(ip + 12, src);
    wr32(ip + 16, dst);
    wr16(ip + 10, csum_fold(csum_add(0, ip, IP_HLEN)));
}

static void send_pkt(pkt_t *p, int len)
{
    p->len = len;
    net_tx_enqueue(p);
}

/* =================================================================== ARP */
static void arp_send(uint16_t op, const uint8_t *tha, uint32_t tpa, const uint8_t *eth_dst)
{
    pkt_t *p = pkt_alloc();
    uint8_t *f, *a;
    if (!p) return;
    f = p->data;
    a = f + ETH_HLEN;
    build_eth(f, eth_dst, 0x0806);
    wr16(a, 1); wr16(a + 2, 0x0800); a[4] = 6; a[5] = 4; wr16(a + 6, op);
    memcpy(a + 8, my_mac, 6);  wr32(a + 14, my_ip);
    memcpy(a + 18, tha, 6);    wr32(a + 24, tpa);
    send_pkt(p, ETH_HLEN + 28);
}

static void arp_input(uint8_t *f, int len)
{
    uint8_t *a = f + ETH_HLEN;
    if (len < ETH_HLEN + 28) return;
    if (rd16(a) != 1 || rd16(a + 2) != 0x0800 || rd16(a + 6) != 1) return;
    if (my_ip == 0 || rd32(a + 24) != my_ip) return;
    arp_send(2, a + 8, rd32(a + 14), a + 8);        /* ARP reply */
}

/* ================================================================== ICMP */
static void icmp_input(uint8_t *f, uint8_t *ip, int ihl, int iplen)
{
    uint8_t *ic = ip + ihl;
    int      n  = iplen - ihl;
    pkt_t   *p;
    uint8_t *o;
    if (n < 8 || ic[0] != 8 || n > ETH_MAX_FRAME - OFS_L4) return;   /* so echo request */
    p = pkt_alloc();
    if (!p) return;
    o = p->data;
    build_eth(o, f + 6, 0x0800);
    memcpy(o + OFS_L4, ic, n);
    o[OFS_L4] = 0;                                   /* echo reply */
    wr16(o + OFS_L4 + 2, 0);
    wr16(o + OFS_L4 + 2, csum_fold(csum_add(0, o + OFS_L4, n)));
    build_ip(o, 1, my_ip, rd32(ip + 12), n);
    send_pkt(p, OFS_L4 + n);
}

/* ================================================================== DHCP */
enum { D_INIT, D_SELECTING, D_REQUESTING, D_BOUND, D_RENEWING };
static uint8_t  dhcp_state = D_INIT;
static uint32_t dhcp_xid, dhcp_offer_ip, dhcp_server;
static uint32_t dhcp_lease_s, dhcp_bound_s;   /* lease (s) e tempo desde o ACK */
static uint16_t dhcp_timer;                   /* em ticks de 100 ms */
static uint8_t  dhcp_tries;
static uint8_t  sec_div;

#define DHCP_DISCOVER 1
#define DHCP_OFFER    2
#define DHCP_REQUEST  3
#define DHCP_ACK      5
#define DHCP_NAK      6

static void dhcp_send(uint8_t type)
{
    pkt_t   *p = pkt_alloc();
    uint8_t *f, *u, *d, *o;
    int      blen, renew = (dhcp_state == D_RENEWING);
    if (!p) return;
    f = p->data;
    u = f + OFS_L4;
    d = u + 8;
    memset(d, 0, 300);
    d[0] = 1; d[1] = 1; d[2] = 6;                    /* BOOTREQUEST, Ethernet */
    wr32(d + 4, dhcp_xid);
    wr16(d + 10, 0x8000);                            /* resposta em broadcast */
    if (renew) wr32(d + 12, my_ip);                  /* ciaddr */
    memcpy(d + 28, my_mac, 6);                       /* chaddr */
    wr32(d + 236, 0x63825363);                       /* magic cookie */
    o = d + 240;
    *o++ = 53; *o++ = 1; *o++ = type;
    *o++ = 61; *o++ = 7; *o++ = 1; memcpy(o, my_mac, 6); o += 6;
    if (type == DHCP_REQUEST && !renew) {
        *o++ = 50; *o++ = 4; wr32(o, dhcp_offer_ip); o += 4;
        *o++ = 54; *o++ = 4; wr32(o, dhcp_server);   o += 4;
    }
    *o++ = 12; *o++ = 8; memcpy(o, "nios-c10", 8); o += 8;
    *o++ = 55; *o++ = 4; *o++ = 1; *o++ = 3; *o++ = 6; *o++ = 51;
    *o++ = 255;
    blen = o - d;
    if (blen < 300) blen = 300;                      /* tamanho minimo BOOTP */

    wr16(u, 68); wr16(u + 2, 67); wr16(u + 4, 8 + blen); wr16(u + 6, 0);
    build_eth(f, bcast_mac, 0x0800);
    build_ip(f, 17, renew ? my_ip : 0, 0xFFFFFFFF, 8 + blen);
    send_pkt(p, OFS_L4 + 8 + blen);

    log_str(type == DHCP_DISCOVER ? "DHCP: DISCOVER enviado\n" : "DHCP: REQUEST enviado\n");
}

static void dhcp_input(uint8_t *d, int n)
{
    uint8_t *o, *end;
    uint8_t  type = 0;
    uint32_t server = 0, mask = 0, gw = 0, lease = 3600;

    if (n < 240 || d[0] != 2 || rd32(d + 4) != dhcp_xid) return;
    if (memcmp(d + 28, my_mac, 6) != 0 || rd32(d + 236) != 0x63825363) return;

    o = d + 240; end = d + n;
    while (o < end && *o != 255) {
        uint8_t code = o[0], len;
        if (code == 0) { o++; continue; }
        if (o + 2 > end) break;
        len = o[1];
        if (o + 2 + len > end) break;
        switch (code) {
        case 53: type = o[2]; break;
        case 54: if (len >= 4) server = rd32(o + 2); break;
        case 1:  if (len >= 4) mask   = rd32(o + 2); break;
        case 3:  if (len >= 4) gw     = rd32(o + 2); break;
        case 51: if (len >= 4) lease  = rd32(o + 2); break;
        }
        o += 2 + len;
    }

    if (type == DHCP_OFFER && dhcp_state == D_SELECTING) {
        dhcp_offer_ip = rd32(d + 16);                /* yiaddr */
        dhcp_server   = server;
        log_str("DHCP: OFFER "); log_ip(dhcp_offer_ip);
        log_str(" do servidor "); log_ip(server); log_str("\n");
        dhcp_state = D_REQUESTING;
        dhcp_timer = 0;
        dhcp_send(DHCP_REQUEST);
    } else if (type == DHCP_ACK &&
               (dhcp_state == D_REQUESTING || dhcp_state == D_RENEWING)) {
        my_ip   = rd32(d + 16);
        my_mask = mask;
        my_gw   = gw;
        if (server) dhcp_server = server;
        dhcp_lease_s = lease ? lease : 3600;
        dhcp_bound_s = 0;
        dhcp_state   = D_BOUND;
        dhcp_tries   = 0;
        led_set(LED_DHCP, 1);
        log_str("DHCP: ACK  ->  IP "); log_ip(my_ip);
        log_str("  mascara "); log_ip(my_mask);
        log_str("  gateway "); log_ip(my_gw);
        log_str("  lease "); log_dec(dhcp_lease_s); log_str(" s\n");
        log_str(">>> Abra http://"); log_ip(my_ip); log_str("/ no navegador <<<\n");
        arp_send(1, bcast_mac, my_ip, bcast_mac);    /* ARP gratuito */
    } else if (type == DHCP_NAK) {
        log_str("DHCP: NAK - reiniciando\n");
        my_ip = 0;
        led_set(LED_DHCP, 0);
        dhcp_state = D_INIT;
    }
}

static void dhcp_tick(void)
{
    dhcp_timer++;
    if (++sec_div >= 10) { sec_div = 0; if (dhcp_state == D_BOUND) dhcp_bound_s++; }

    switch (dhcp_state) {
    case D_INIT:
        dhcp_xid   = rnd() ^ ((uint32_t)my_mac[5] << 24);
        dhcp_state = D_SELECTING;
        dhcp_timer = 0;
        dhcp_send(DHCP_DISCOVER);
        break;
    case D_SELECTING:
        if (dhcp_timer >= 40) dhcp_state = D_INIT;   /* 4 s sem OFFER */
        break;
    case D_REQUESTING:
        if (dhcp_timer % 10 == 0 && dhcp_timer < 40)  /* reenvia REQUEST a cada 1 s */
            dhcp_send(DHCP_REQUEST);
        else if (dhcp_timer >= 40) dhcp_state = D_INIT;
        break;
    case D_BOUND:
        if (dhcp_bound_s >= dhcp_lease_s / 2) {      /* T1: renovar */
            dhcp_state = D_RENEWING;
            dhcp_timer = 0;
            dhcp_tries = 0;
            dhcp_send(DHCP_REQUEST);
        }
        break;
    case D_RENEWING:
        if (dhcp_timer >= 40) {
            dhcp_timer = 0;
            if (++dhcp_tries > 5) {
                my_ip = 0;
                led_set(LED_DHCP, 0);
                dhcp_state = D_INIT;
            } else dhcp_send(DHCP_REQUEST);
        }
        break;
    }
}

/* =================================================================== TCP */
#define TCP_FIN 0x01
#define TCP_SYN 0x02
#define TCP_RST 0x04
#define TCP_PSH 0x08
#define TCP_ACK 0x10

enum { C_FREE, C_SYNRCVD, C_ESTAB, C_LASTACK };

#define NCONN    6
#define LINE_MAX 240

typedef struct {
    uint8_t  state;
    uint8_t  mac[6];
    uint32_t ip;
    uint16_t port;
    uint32_t iss, snd_nxt, rcv_nxt, resp_seq;
    uint8_t  req_done, responded, fin_rcvd, fin_acked, fin_only;
    uint8_t  hdr_match, line_done, retries;
    uint16_t timer, idle, line_len;
    char     line[LINE_MAX];
} tcp_conn_t;

static tcp_conn_t conns[NCONN];

static int seq_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }

static void tcp_send(tcp_conn_t *c, pkt_t *p, uint32_t seq, uint8_t flags, int dlen)
{
    uint8_t *f = p->data, *t = f + OFS_L4;
    int      hl = (flags & TCP_SYN) ? 24 : 20;
    uint32_t s;

    build_eth(f, c->mac, 0x0800);
    wr16(t, 80);
    wr16(t + 2, c->port);
    wr32(t + 4, seq);
    wr32(t + 8, c->rcv_nxt);
    t[12] = (hl / 4) << 4;
    t[13] = flags;
    wr16(t + 14, 2048);                              /* janela */
    wr16(t + 16, 0);
    wr16(t + 18, 0);
    if (hl == 24) { t[20] = 2; t[21] = 4; wr16(t + 22, 1460); }  /* MSS */

    s = csum_add(0, t, hl + dlen);
    s += (my_ip >> 16) + (my_ip & 0xFFFF) + (c->ip >> 16) + (c->ip & 0xFFFF);
    s += 6 + hl + dlen;
    wr16(t + 16, csum_fold(s));
    build_ip(f, 6, my_ip, c->ip, hl + dlen);
    send_pkt(p, OFS_L4 + hl + dlen);
}

static void tcp_ctl(tcp_conn_t *c, uint32_t seq, uint8_t flags)
{
    pkt_t *p = pkt_alloc();
    if (p) tcp_send(c, p, seq, flags, 0);
}

static void tcp_rst_reply(uint8_t *f, uint8_t *ip, uint8_t *t, int plen)
{
    tcp_conn_t tmp;
    uint8_t    fl = t[13];
    uint32_t   seq = rd32(t + 4);
    if (fl & TCP_RST) return;
    memcpy(tmp.mac, f + 6, 6);
    tmp.ip   = rd32(ip + 12);
    tmp.port = rd16(t);
    if (fl & TCP_ACK) {
        tmp.rcv_nxt = 0;
        tcp_ctl(&tmp, rd32(t + 8), TCP_RST);
    } else {
        tmp.rcv_nxt = seq + plen + ((fl & TCP_SYN) ? 1 : 0) + ((fl & TCP_FIN) ? 1 : 0);
        tcp_ctl(&tmp, 0, TCP_RST | TCP_ACK);
    }
}

/* ------------------------------------------------------------ HTTP */
static char *put_str(char *o, const char *s) { while (*s) *o++ = *s++; return o; }
static char *put_dec(char *o, uint32_t v)
{
    char b[10]; int i = 0;
    do { b[i++] = '0' + v % 10; v /= 10; } while (v);
    while (i) *o++ = b[--i];
    return o;
}
static const char hexd[] = "0123456789abcdef";
static char *put_hex(char *o, const uint8_t *d, int n)
{
    while (n--) { *o++ = hexd[*d >> 4]; *o++ = hexd[*d & 15]; d++; }
    return o;
}
static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static char *put_ip(char *o, uint32_t ip)
{
    o = put_dec(o, ip >> 24); *o++ = '.';
    o = put_dec(o, (ip >> 16) & 255); *o++ = '.';
    o = put_dec(o, (ip >> 8) & 255); *o++ = '.';
    return put_dec(o, ip & 255);
}

#define MAX_STR 100

/* gera a resposta HTTP completa em 'out'; retorna o tamanho */
static int http_build(tcp_conn_t *c, char *out)
{
    static char body[2 * MAX_STR * 2 + 120];
    const char *ctype = "application/json";
    const char *status = "200 OK";
    const char *bptr = body;
    int         blen = 0;
    char       *o, *l = c->line;

    if (!strncmp(l, "OPTIONS ", 8)) {
        status = "204 No Content";
    } else if (!strncmp(l, "GET /api?h=", 11)) {
        uint8_t in[MAX_STR], res[MAX_STR];
        int     n = 0, hi, lo;
        char   *h = l + 11;
        while (n < MAX_STR && (hi = hexval(h[0])) >= 0 && (lo = hexval(h[1])) >= 0) {
            in[n++] = (hi << 4) | lo;
            h += 2;
        }
        user_hw_process(in, n, res);
        o = body;
        o = put_str(o, "{\"in\":\"");    o = put_hex(o, in, n);
        o = put_str(o, "\",\"out\":\""); o = put_hex(o, res, n);
        o = put_str(o, "\",\"len\":");   o = put_dec(o, n);
        o = put_str(o, ",\"count\":");   o = put_dec(o, user_hw_count());
        o = put_str(o, ",\"ip\":\"");    o = put_ip(o, my_ip);
        o = put_str(o, "\"}");
        blen = o - body;
        log_str("HTTP: string de "); log_dec(n); log_str(" bytes processada pelo USER HW\n");
    } else if (!strncmp(l, "GET / ", 6) || !strncmp(l, "GET /index.html ", 16)) {
        ctype = "text/html; charset=utf-8";
        bptr  = page_html;
        blen  = sizeof(page_html) - 1;
    } else {
        status = "404 Not Found";
        ctype  = "text/plain";
        bptr   = "404";
        blen   = 3;
    }

    o = out;
    o = put_str(o, "HTTP/1.1 "); o = put_str(o, status);
    o = put_str(o, "\r\nContent-Type: "); o = put_str(o, ctype);
    o = put_str(o, "\r\nContent-Length: "); o = put_dec(o, blen);
    o = put_str(o, "\r\nAccess-Control-Allow-Origin: *"
                   "\r\nAccess-Control-Allow-Methods: GET, OPTIONS"
                   "\r\nAccess-Control-Allow-Headers: *"
                   "\r\nAccess-Control-Allow-Private-Network: true"
                   "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
    memcpy(o, bptr, blen);
    return (o - out) + blen;
}

/* envia (ou reenvia) a resposta + FIN a partir de resp_seq */
static void tcp_respond(tcp_conn_t *c)
{
    pkt_t *p = pkt_alloc();
    int    n;
    if (!p) return;
    if (c->fin_only) {
        tcp_send(c, p, c->resp_seq, TCP_FIN | TCP_ACK, 0);
        c->snd_nxt = c->resp_seq + 1;
    } else {
        n = http_build(c, (char *)p->data + OFS_L4 + 20);
        tcp_send(c, p, c->resp_seq, TCP_ACK | TCP_PSH | TCP_FIN, n);
        c->snd_nxt = c->resp_seq + n + 1;
    }
    c->responded = 1;
    c->state     = C_LASTACK;
    c->timer     = 0;
}

static void http_feed(tcp_conn_t *c, const uint8_t *d, int n)
{
    while (n-- && !c->req_done) {
        char b = *d++;
        if (!c->line_done) {
            if (b == '\r' || b == '\n') { c->line_done = 1; c->line[c->line_len] = 0; }
            else if (c->line_len < LINE_MAX - 1) c->line[c->line_len++] = b;
        }
        /* detecta fim dos cabecalhos "\r\n\r\n" */
        if (b == '\r')      c->hdr_match = (c->hdr_match == 2) ? 3 : 1;
        else if (b == '\n') c->hdr_match = (c->hdr_match == 1 || c->hdr_match == 3) ? c->hdr_match + 1 : 0;
        else                c->hdr_match = 0;
        if (c->hdr_match == 4) c->req_done = 1;
    }
}

static tcp_conn_t *conn_find(uint32_t ip, uint16_t port)
{
    int i;
    for (i = 0; i < NCONN; i++)
        if (conns[i].state != C_FREE && conns[i].ip == ip && conns[i].port == port)
            return &conns[i];
    return 0;
}

static tcp_conn_t *conn_alloc(void)
{
    int i;
    tcp_conn_t *best = 0;
    for (i = 0; i < NCONN; i++) {
        tcp_conn_t *c = &conns[i];
        if (c->state == C_FREE) return c;
        if (c->state == C_LASTACK && c->fin_acked) return c;     /* ja respondida */
        if (c->idle >= 20 && (!best || c->idle > best->idle)) best = c;  /* >= 2 s ociosa */
    }
    /* NULL: todas as conexoes estao ativas -> ignora o SYN; o cliente o
     * retransmite em ~1 s, quando uma posicao ja tera sido liberada */
    return best;
}

static void tcp_input(uint8_t *f, uint8_t *ip, int ihl, int iplen)
{
    uint8_t     *t = ip + ihl;
    int          thl, plen;
    uint8_t      fl;
    uint32_t     seq, ack, src;
    uint16_t     sport;
    tcp_conn_t  *c;

    if (iplen - ihl < 20) return;
    thl  = (t[12] >> 4) * 4;
    plen = iplen - ihl - thl;
    if (thl < 20 || plen < 0) return;
    fl    = t[13];
    seq   = rd32(t + 4);
    ack   = rd32(t + 8);
    src   = rd32(ip + 12);
    sport = rd16(t);

    if (rd16(t + 2) != 80) { tcp_rst_reply(f, ip, t, plen); return; }

    c = conn_find(src, sport);
    if (fl & TCP_RST) { if (c) c->state = C_FREE; return; }

    if (fl & TCP_SYN) {
        if (!c) {
            c = conn_alloc();
            if (!c) return;
        } else if (c->state == C_SYNRCVD && c->rcv_nxt == seq + 1) {
            tcp_ctl(c, c->iss, TCP_SYN | TCP_ACK);   /* SYN duplicado */
            return;
        }
        memset(c, 0, sizeof(*c));
        memcpy(c->mac, f + 6, 6);
        c->ip      = src;
        c->port    = sport;
        c->iss     = rnd();
        c->snd_nxt = c->iss + 1;
        c->resp_seq= c->iss + 1;
        c->rcv_nxt = seq + 1;
        c->state   = C_SYNRCVD;
        tcp_ctl(c, c->iss, TCP_SYN | TCP_ACK);
        return;
    }
    if (!c) {
        if ((fl & TCP_FIN) && (fl & TCP_ACK) && plen == 0) {
            /* FIN retransmitido de uma conexao ja encerrada (o nosso ACK se
             * perdeu): confirma com ACK em vez de RST */
            tcp_conn_t tmp;
            memcpy(tmp.mac, f + 6, 6);
            tmp.ip = src; tmp.port = sport; tmp.rcv_nxt = seq + 1;
            tcp_ctl(&tmp, ack, TCP_ACK);
        } else tcp_rst_reply(f, ip, t, plen);
        return;
    }

    c->idle = 0;
    if (fl & TCP_ACK) {
        if (c->state == C_SYNRCVD && ack == c->iss + 1) c->state = C_ESTAB;
        if (c->state == C_LASTACK && ack == c->snd_nxt) c->fin_acked = 1;
    }

    if (plen > 0) {
        if (seq == c->rcv_nxt && !c->req_done) {
            http_feed(c, t + thl, plen);
            c->rcv_nxt += plen;
            if (c->req_done && !c->responded) { tcp_respond(c); }
            else tcp_ctl(c, c->snd_nxt, TCP_ACK);
        } else if (seq_lt(seq, c->rcv_nxt)) {
            /* retransmissao do cliente: a resposta deve ter se perdido */
            if (c->responded && !c->fin_acked) tcp_respond(c);
            else tcp_ctl(c, c->snd_nxt, TCP_ACK);
        } else {
            if (c->req_done) c->rcv_nxt = seq + plen;  /* dados extras: ignora */
            tcp_ctl(c, c->snd_nxt, TCP_ACK);
        }
    }

    if (fl & TCP_FIN) {
        if (seq + plen == c->rcv_nxt && !c->fin_rcvd) {
            c->rcv_nxt++;
            c->fin_rcvd = 1;
        }
        if (!c->responded) {
            c->fin_only = 1;
            tcp_respond(c);                          /* FIN|ACK */
        } else {
            tcp_ctl(c, c->snd_nxt, TCP_ACK);
        }
    }

    if (c->fin_rcvd && c->fin_acked) c->state = C_FREE;
}

static void tcp_tick(void)
{
    int i;
    for (i = 0; i < NCONN; i++) {
        tcp_conn_t *c = &conns[i];
        if (c->state == C_FREE) continue;
        /* 120 s sem atividade: maior que o backoff exponencial de retransmissao
         * do cliente (3+6+12+24+48 s). Com a tabela cheia, conn_alloc ja
         * recicla a conexao mais ociosa, entao um timeout longo e' seguro. */
        if (++c->idle > 1200) { c->state = C_FREE; continue; }
        if (c->state == C_SYNRCVD || (c->state == C_LASTACK && !c->fin_acked)) {
            if (++c->timer >= 10) {                              /* 1 s */
                c->timer = 0;
                if (++c->retries > 5) { c->state = C_FREE; continue; }
                if (c->state == C_SYNRCVD) tcp_ctl(c, c->iss, TCP_SYN | TCP_ACK);
                else tcp_respond(c);
            }
        }
    }
}

/* ============================================================ entrada IP */
static void ip_input(uint8_t *f, int len)
{
    uint8_t *ip = f + OFS_IP;
    int      ihl, iplen;
    uint32_t dst;

    if (len < OFS_L4 || (ip[0] >> 4) != 4) return;
    ihl   = (ip[0] & 15) * 4;
    iplen = rd16(ip + 2);
    if (ihl < 20 || iplen < ihl || iplen > len - ETH_HLEN) return;
    if (rd16(ip + 6) & 0x3FFF) return;               /* fragmentos: ignora */
    if (csum_fold(csum_add(0, ip, ihl)) != 0) return;
    dst = rd32(ip + 16);

    if (ip[9] == 17) {                               /* UDP */
        uint8_t *u = ip + ihl;
        if (iplen - ihl >= 8 && rd16(u + 2) == 68)
            dhcp_input(u + 8, iplen - ihl - 8);
        return;
    }
    if (my_ip == 0 || dst != my_ip) return;
    if (ip[9] == 1)      icmp_input(f, ip, ihl, iplen);
    else if (ip[9] == 6) tcp_input(f, ip, ihl, iplen);
}

/* ============================================================ API publica */
void net_init(void)
{
    net_lock = OSSemCreate(1);
    memset(conns, 0, sizeof(conns));
    rnd_state ^= (my_mac[4] << 8) | my_mac[5];
}

void net_input(uint8_t *f, int len)
{
    uint16_t type;
    if (len < ETH_HLEN) return;
    type = rd16(f + 12);
    LOCK();
    if (type == 0x0806)      arp_input(f, len);
    else if (type == 0x0800) ip_input(f, len);
    UNLOCK();
}

void net_tick_100ms(void)
{
    /* nao bloqueia: se a RX estiver usando a pilha, tenta no proximo tick */
    if (OSSemAccept(net_lock) == 0) return;
    dhcp_tick();
    tcp_tick();
    UNLOCK();
}
