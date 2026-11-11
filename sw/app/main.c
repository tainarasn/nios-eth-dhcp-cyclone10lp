/* =============================================================================
 * main.c - Nios II + MicroC/OS-II: web server com DHCP no Cyclone 10 LP
 *
 * Duas threads (tasks) obrigatorias:
 *   rx_task : espera a IRQ do MAC (semaforo), le os quadros recebidos e os
 *             entrega a pilha (ARP/IP/ICMP/DHCP/TCP/HTTP + USER HW).
 *   tx_task : unica dona do transmissor; tira pacotes da fila (OSQ) e os
 *             escreve no MAC. Tambem gera a base de tempo de 100 ms da pilha
 *             (DHCP DISCOVER/REQUEST/renovacao e retransmissoes TCP).
 * ========================================================================== */
#include "includes.h"
#include "system.h"
#include "io.h"
#include "sys/alt_irq.h"
#include "net.h"

#define TX_TASK_PRIO   4
#define RX_TASK_PRIO   5
#define TX_STK_WORDS   640
#define RX_STK_WORDS   640
#define TXQ_LEN        8

static OS_STK    tx_stk[TX_STK_WORDS];
static OS_STK    rx_stk[RX_STK_WORDS];
static OS_EVENT *rx_sem;                  /* sinalizado pela IRQ do MAC */
static OS_EVENT *tx_q;                    /* fila de pacotes a transmitir */
static void     *tx_q_storage[TXQ_LEN];
static volatile int net_ready;

static uint8_t rx_frame[ETH_MAX_FRAME + 4];

/* ------------------------------------------------------------ IRQ do MAC */
static void eth_isr(void *ctx)
{
    (void)ctx;
    eth_irq_enable(0);                    /* reabilitada pela rx_task */
    OSSemPost(rx_sem);
}

/* ------------------------------------------------------------ fila TX */
void net_tx_enqueue(pkt_t *p)
{
    if (OSQPost(tx_q, p) != OS_NO_ERR) pkt_free(p);
}

static void tx_one(pkt_t *p)
{
    eth_tx_send(p->data, p->len);
    pkt_free(p);
    led_toggle(LED_TX);
}

void net_tx_poll(void)
{
    INT8U  err;
    pkt_t *p;
    if (OSTCBCur->OSTCBPrio != TX_TASK_PRIO) return;
    while ((p = (pkt_t *)OSQAccept(tx_q, &err)) != 0) tx_one(p);
}

/* ------------------------------------------------------------ thread TX */
static void tx_task(void *pdata)
{
    INT8U  err;
    INT32U last = 0, beat = 0;
    pkt_t *p;
    (void)pdata;

    log_str("\n=== Nios II Web Server (Cyclone 10 LP) ===\n");
    log_str("MAC ");
    {
        int i;
        static const char h[] = "0123456789ABCDEF";
        char b[4];
        for (i = 0; i < 6; i++) {
            b[0] = h[my_mac[i] >> 4]; b[1] = h[my_mac[i] & 15]; b[2] = (i < 5) ? ':' : '\n'; b[3] = 0;
            log_str(b);
        }
    }
    phy_init();
    eth_init(my_mac);
    net_ready = 1;
    eth_irq_enable(1);
    log_str("Aguardando DHCP...\n");

    for (;;) {
        p = (pkt_t *)OSQPend(tx_q, OS_TICKS_PER_SEC / 20, &err);  /* 50 ms */
        if (p) tx_one(p);

        if (OSTimeGet() - last >= OS_TICKS_PER_SEC / 10) {         /* 100 ms */
            last = OSTimeGet();
            net_tick_100ms();
            if (++beat % 5 == 0) led_toggle(LED_ALIVE);
            /* acompanha o link do PHY a cada 1 s e avisa quando muda */
            if (beat % 10 == 0) {
                static int link_prev = -1;
                int link = phy_link_up();
                if (link != link_prev) {
                    log_str(link ? "PHY: link UP (100 Mbit/s)\n" : "PHY: link DOWN - confira o cabo Ethernet\n");
                    link_prev = link;
                }
            }
            /* repete o IP a cada 10 s: o software inicia junto com a FPGA,
             * antes de o nios2-terminal ser aberto */
            if (beat >= 100) {
                beat = 0;
                if (my_ip) { log_str("IP atual (DHCP): "); log_ip(my_ip); log_str("\n"); }
                else log_str("Aguardando DHCP...\n");
            }
        }
    }
}

/* ------------------------------------------------------------ thread RX */
static void rx_task(void *pdata)
{
    INT8U err;
    int   len;
    (void)pdata;

    for (;;) {
        OSSemPend(rx_sem, OS_TICKS_PER_SEC / 10, &err);  /* timeout = seguranca */
        if (!net_ready) continue;
        while (eth_rx_avail()) {
            len = eth_rx_read(rx_frame);
            if (len > 0) {
                led_toggle(LED_RX);
                net_input(rx_frame, len);
            }
        }
        eth_irq_enable(1);
    }
}

/* ------------------------------------------------------------ main */
int main(void)
{
    uint32_t dip = IORD_32DIRECT(DIP_BASE, 0) & 7;

    /* MAC localmente administrado; ultimo byte = chaves DIP (evita conflito
     * quando ha varias placas na mesma rede) */
    my_mac[0] = 0x02; my_mac[1] = 0x10; my_mac[2] = 0xC1;
    my_mac[3] = 0x0A; my_mac[4] = 0x00; my_mac[5] = 0x10 + dip;

    led_set(LED_DHCP, 0);
    rx_sem = OSSemCreate(0);
    tx_q   = OSQCreate(tx_q_storage, TXQ_LEN);
    net_init();

    alt_ic_isr_register(ETH_MAC_IRQ_INTERRUPT_CONTROLLER_ID, ETH_MAC_IRQ,
                        eth_isr, 0, 0);

    OSTaskCreateExt(tx_task, 0, &tx_stk[TX_STK_WORDS - 1], TX_TASK_PRIO,
                    TX_TASK_PRIO, tx_stk, TX_STK_WORDS, 0, OS_TASK_OPT_STK_CHK);
    OSTaskCreateExt(rx_task, 0, &rx_stk[RX_STK_WORDS - 1], RX_TASK_PRIO,
                    RX_TASK_PRIO, rx_stk, RX_STK_WORDS, 0, OS_TASK_OPT_STK_CHK);
    OSStart();
    return 0;
}
