/* =============================================================================
 * harness.c - roda a pilha de rede do Nios (sw/app/net.c, sem alteracoes) no
 * Linux, ligada a uma interface TAP. Emula:
 *   - o MAC em HW: filtro (unicast proprio / broadcast) e padding para 60 bytes
 *   - o USER HW (+1 por caractere, 0xF7 -> 0x00)
 *   - as duas tasks do MicroC/OS-II (rx_task e tx_task) com pthreads
 *   - perda de pacotes opcional (LOSS=<percentual>) nos dois sentidos
 * Uso (root):  ./harness tap0
 * ========================================================================== */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include "includes.h"
#include "net.h"

/* ------------------------------------------------------------ "RTOS" */
static pthread_mutex_t crit = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
void os_crit_enter(void) { pthread_mutex_lock(&crit); }
void os_crit_exit(void)  { pthread_mutex_unlock(&crit); }

struct os_event { pthread_mutex_t m; pthread_cond_t c; int cnt; };

OS_EVENT *OSSemCreate(INT16U cnt)
{
    OS_EVENT *e = calloc(1, sizeof(*e));
    pthread_mutex_init(&e->m, 0);
    pthread_cond_init(&e->c, 0);
    e->cnt = cnt;
    return e;
}
void OSSemPend(OS_EVENT *e, INT32U timeout, INT8U *err)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout / 1000; ts.tv_nsec += (timeout % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&e->m);
    while (e->cnt == 0) {
        if (timeout == 0) pthread_cond_wait(&e->c, &e->m);
        else if (pthread_cond_timedwait(&e->c, &e->m, &ts) == ETIMEDOUT) break;
    }
    if (e->cnt) { e->cnt--; *err = 0; } else *err = 10;
    pthread_mutex_unlock(&e->m);
}
INT8U OSSemPost(OS_EVENT *e)
{
    pthread_mutex_lock(&e->m); e->cnt++; pthread_cond_signal(&e->c); pthread_mutex_unlock(&e->m);
    return 0;
}
INT16U OSSemAccept(OS_EVENT *e)
{
    INT16U r;
    pthread_mutex_lock(&e->m); r = e->cnt; if (r) e->cnt--; pthread_mutex_unlock(&e->m);
    return r;
}
INT32U OSTimeGet(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000u + ts.tv_nsec / 1000000u;
}
void  OSTimeDly(INT32U t) { usleep(t * 1000); }
INT8U OSTimeDlyHMSM(INT8U h, INT8U m, INT8U s, INT16U ms)
{ OSTimeDly(((h * 60 + m) * 60 + s) * 1000 + ms); return 0; }

/* ------------------------------------------------------------ eth.h (log/LED) */
void log_str(const char *s) { fputs(s, stdout); fflush(stdout); }
void log_dec(uint32_t v)    { printf("%u", v); }
void log_hex(uint32_t v)    { printf("%08X", v); }
void log_ip(uint32_t ip)    { printf("%u.%u.%u.%u", ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255); }
void led_set(int n, int on) { if (n == 0) printf("[LED0 DHCP=%d]\n", on); }
void led_toggle(int n)      { (void)n; }

/* ------------------------------------------------------------ USER HW */
static uint32_t uhw_count;
int user_hw_process(const uint8_t *in, int n, uint8_t *out)
{
    int i;
    for (i = 0; i < n; i++) out[i] = (in[i] == 0xF7) ? 0 : (uint8_t)(in[i] + 1);
    uhw_count++;
    return n;
}
uint32_t user_hw_count(void) { return uhw_count; }

/* ------------------------------------------------------------ fila TX */
#define TXQ_LEN 8
static pkt_t          *txq[TXQ_LEN];
static int             txq_h, txq_t, txq_n;
static pthread_mutex_t txq_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  txq_c = PTHREAD_COND_INITIALIZER;
static __thread int    is_tx_thread;
static int             tapfd, loss;
static FILE           *pcap;
static pthread_mutex_t pcap_m = PTHREAD_MUTEX_INITIALIZER;

/* PCAP=arquivo: grava os quadros entregues; os "perdidos" vao para arquivo.drop */
static FILE *pcap_drop;
static void pcap_write(FILE *f, const uint8_t *d, int len)
{
    struct timespec ts;
    uint32_t h[4];
    if (!f) return;
    clock_gettime(CLOCK_REALTIME, &ts);
    h[0] = ts.tv_sec; h[1] = ts.tv_nsec / 1000; h[2] = len; h[3] = len;
    pthread_mutex_lock(&pcap_m);
    fwrite(h, 4, 4, f); fwrite(d, 1, len, f); fflush(f);
    pthread_mutex_unlock(&pcap_m);
}
static FILE *pcap_open(const char *name)
{
    uint32_t gh[6] = { 0xa1b2c3d4, 0x00040002, 0, 0, 65535, 1 };
    FILE *f = fopen(name, "wb");
    if (f) fwrite(gh, 4, 6, f);
    return f;
}
static unsigned long   n_rx, n_tx, n_drop_rx, n_drop_tx, n_qfull;

void net_tx_enqueue(pkt_t *p)
{
    pthread_mutex_lock(&txq_m);
    if (txq_n == TXQ_LEN) { pthread_mutex_unlock(&txq_m); n_qfull++; pkt_free(p); return; }
    txq[txq_t] = p; txq_t = (txq_t + 1) % TXQ_LEN; txq_n++;
    pthread_cond_signal(&txq_c);
    pthread_mutex_unlock(&txq_m);
}

static pkt_t *txq_pop(int wait_ms)
{
    pkt_t *p = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += wait_ms * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&txq_m);
    while (txq_n == 0 && wait_ms > 0)
        if (pthread_cond_timedwait(&txq_c, &txq_m, &ts) == ETIMEDOUT) break;
    if (txq_n) { p = txq[txq_h]; txq_h = (txq_h + 1) % TXQ_LEN; txq_n--; }
    pthread_mutex_unlock(&txq_m);
    return p;
}

static void tx_one(pkt_t *p)
{
    uint8_t buf[ETH_MAX_FRAME];
    int len = p->len;
    memcpy(buf, p->data, len);
    if (len < 60) { memset(buf + len, 0, 60 - len); len = 60; }   /* padding do MAC */
    pkt_free(p);
    if (loss && rand() % 100 < loss) { n_drop_tx++; pcap_write(pcap_drop, buf, len); return; }
    pcap_write(pcap, buf, len);
    if (write(tapfd, buf, len) != len) perror("write tap");
    n_tx++;
}

void net_tx_poll(void)
{
    pkt_t *p;
    if (!is_tx_thread) return;
    while ((p = txq_pop(0)) != 0) tx_one(p);
}

static void *tx_task(void *a)
{
    INT32U last = 0;
    (void)a;
    is_tx_thread = 1;
    for (;;) {
        pkt_t *p = txq_pop(50);
        if (p) tx_one(p);
        if (OSTimeGet() - last >= 100) { last = OSTimeGet(); net_tick_100ms(); }
    }
    return 0;
}

static void *rx_task(void *a)
{
    static const uint8_t bc[6] = { 255, 255, 255, 255, 255, 255 };
    uint8_t f[ETH_MAX_FRAME + 64];
    (void)a;
    for (;;) {
        int len = read(tapfd, f, sizeof(f));
        if (len <= 0) continue;
        /* filtro de endereco do MAC em HW */
        if (memcmp(f, my_mac, 6) && memcmp(f, bc, 6)) continue;
        if (len < 60) { memset(f + len, 0, 60 - len); len = 60; }
        if (len > 1518) continue;
        if (loss && rand() % 100 < loss) { n_drop_rx++; pcap_write(pcap_drop, f, len); continue; }
        pcap_write(pcap, f, len);
        n_rx++;
        net_input(f, len);
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct ifreq ifr;
    pthread_t rt, tt;
    const char *dev = argc > 1 ? argv[1] : "tap0";

    if (getenv("LOSS")) loss = atoi(getenv("LOSS"));
    if (getenv("PCAP")) {
        char n[256];
        pcap = pcap_open(getenv("PCAP"));
        snprintf(n, sizeof(n), "%s.drop", getenv("PCAP"));
        pcap_drop = pcap_open(n);
    }
    srand(time(0));
    tapfd = open("/dev/net/tun", O_RDWR);
    if (tapfd < 0) { perror("/dev/net/tun"); return 1; }
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, dev, IFNAMSIZ - 1);
    if (ioctl(tapfd, TUNSETIFF, &ifr) < 0) { perror("TUNSETIFF"); return 1; }

    my_mac[0] = 0x02; my_mac[1] = 0x10; my_mac[2] = 0xC1;
    my_mac[3] = 0x0A; my_mac[4] = 0x00; my_mac[5] = 0x10;
    net_init();
    printf("harness: %s, perda=%d%%\n", dev, loss);

    pthread_create(&rt, 0, rx_task, 0);
    pthread_create(&tt, 0, tx_task, 0);
    for (;;) {
        sleep(5);
        printf("[stats] rx=%lu tx=%lu drop_rx=%lu drop_tx=%lu txq_full=%lu\n",
               n_rx, n_tx, n_drop_rx, n_drop_tx, n_qfull);
    }
}
