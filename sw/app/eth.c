/* eth.c - driver do MAC RGMII + PHY (MDIO bit-bang) + LEDs + log */
#include "eth.h"
#include "system.h"
#include "io.h"
#include "includes.h"     /* uC/OS-II */

/* ------------------------------------------------------------------ log */
#define JUART_DATA 0
#define JUART_CTRL 4

static void log_putc(char c)
{
    /* so escreve se houver espaco na FIFO (nao trava sem terminal) */
    if ((IORD_32DIRECT(JTAG_UART_BASE, JUART_CTRL) >> 16) != 0)
        IOWR_32DIRECT(JTAG_UART_BASE, JUART_DATA, (uint8_t)c);
}

void log_str(const char *s)
{
    while (*s) {
        if (*s == '\n') log_putc('\r');
        log_putc(*s++);
    }
}

void log_dec(uint32_t v)
{
    char b[11];
    int i = 10;
    b[i] = 0;
    do { b[--i] = '0' + (v % 10); v /= 10; } while (v);
    log_str(&b[i]);
}

void log_hex(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    char b[9];
    int i;
    for (i = 7; i >= 0; i--) { b[i] = h[v & 15]; v >>= 4; }
    b[8] = 0;
    log_str(b);
}

void log_ip(uint32_t ip)
{
    log_dec(ip >> 24);         log_str(".");
    log_dec((ip >> 16) & 255); log_str(".");
    log_dec((ip >> 8) & 255);  log_str(".");
    log_dec(ip & 255);
}

/* ------------------------------------------------------------------ LEDs */
static uint8_t led_state;

static void led_apply(void) { IOWR_32DIRECT(LED_BASE, 0, (~led_state) & 0xF); }

void led_set(int n, int on)
{
#if OS_CRITICAL_METHOD == 3
    OS_CPU_SR cpu_sr;
#endif
    OS_ENTER_CRITICAL();
    if (on) led_state |= (1 << n); else led_state &= ~(1 << n);
    led_apply();
    OS_EXIT_CRITICAL();
}

void led_toggle(int n)
{
#if OS_CRITICAL_METHOD == 3
    OS_CPU_SR cpu_sr;
#endif
    OS_ENTER_CRITICAL();
    led_state ^= (1 << n);
    led_apply();
    OS_EXIT_CRITICAL();
}

/* ------------------------------------------------------------------ MDIO */
/* phy_ctrl PIO: [0] MDC, [1] ENET_RSTn ; mdio PIO bidirecional */
#define PIO_DATA 0
#define PIO_DIR  4

static uint32_t phy_ctrl_sh;
static int      phy_addr = -1;

static void mdio_delay(void) { volatile int i; for (i = 0; i < 4; i++) ; }

static void set_mdc(int v)
{
    phy_ctrl_sh = v ? (phy_ctrl_sh | 1) : (phy_ctrl_sh & ~1u);
    IOWR_32DIRECT(PHY_CTRL_BASE, PIO_DATA, phy_ctrl_sh);
}

static void set_phy_reset_n(int v)
{
    phy_ctrl_sh = v ? (phy_ctrl_sh | 2) : (phy_ctrl_sh & ~2u);
    IOWR_32DIRECT(PHY_CTRL_BASE, PIO_DATA, phy_ctrl_sh);
}

static void mdio_dir_out(int out) { IOWR_32DIRECT(MDIO_BASE, PIO_DIR, out ? 1 : 0); }

static void mdio_put_bit(int b)
{
    IOWR_32DIRECT(MDIO_BASE, PIO_DATA, b ? 1 : 0);
    mdio_delay();
    set_mdc(1);
    mdio_delay();
    set_mdc(0);
}

static int mdio_get_bit(void)
{
    mdio_delay();
    set_mdc(1);
    mdio_delay();
    set_mdc(0);
    return IORD_32DIRECT(MDIO_BASE, PIO_DATA) & 1;
}

static void mdio_put_bits(uint32_t v, int n)
{
    while (n--) mdio_put_bit((v >> n) & 1);
}

static void mdio_start(int op, int pa, int reg)
{
    int i;
    mdio_dir_out(1);
    for (i = 0; i < 32; i++) mdio_put_bit(1);       /* preambulo */
    mdio_put_bits(1, 2);                             /* start 01 */
    mdio_put_bits(op, 2);                            /* 01=write 10=read */
    mdio_put_bits(pa, 5);
    mdio_put_bits(reg, 5);
}

static uint16_t mdio_read(int pa, int reg)
{
    int i;
    uint16_t v = 0;
    mdio_start(2, pa, reg);
    mdio_dir_out(0);
    mdio_get_bit();                                  /* turnaround */
    for (i = 0; i < 16; i++) v = (v << 1) | mdio_get_bit();
    mdio_get_bit();
    return v;
}

static void mdio_write(int pa, int reg, uint16_t val)
{
    mdio_start(1, pa, reg);
    mdio_put_bits(2, 2);                             /* turnaround 10 */
    mdio_put_bits(val, 16);
    mdio_dir_out(0);
    mdio_get_bit();
}

int phy_link_up(void)
{
    if (phy_addr < 0) return 0;
    mdio_read(phy_addr, 1);                          /* status e' latch-low */
    return (mdio_read(phy_addr, 1) & 0x0004) != 0;
}

int phy_init(void)
{
    int a, t;
    uint16_t id1, id2;

    set_mdc(0);
    set_phy_reset_n(0);
    OSTimeDlyHMSM(0, 0, 0, 20);
    set_phy_reset_n(1);
    OSTimeDlyHMSM(0, 0, 0, 100);

    for (a = 0; a < 32; a++) {
        id1 = mdio_read(a, 2);
        if (id1 != 0xFFFF && id1 != 0x0000) { phy_addr = a; break; }
    }
    if (phy_addr < 0) {
        log_str("PHY: nao encontrado no MDIO\n");
        return -1;
    }
    id2 = mdio_read(phy_addr, 3);
    log_str("PHY: endereco "); log_dec(phy_addr);
    log_str(" ID "); log_hex(((uint32_t)id1 << 16) | id2);
    log_str(" MIICTRL(0x17) "); log_hex(mdio_read(phy_addr, 0x17));
    log_str("\n");

    /* o MAC funciona so a 100 Mbit/s: anuncia apenas 100BASE-TX FD/HD */
    mdio_write(phy_addr, 9, 0x0000);                 /* sem 1000BASE-T */
    mdio_write(phy_addr, 4, 0x0181);                 /* 100FD|100HD|802.3 */
    mdio_write(phy_addr, 0, 0x1200);                 /* AN enable + restart */

    for (t = 0; t < 50; t++) {                       /* ate 5 s */
        OSTimeDlyHMSM(0, 0, 0, 100);
        if (phy_link_up()) break;
    }
    log_str(phy_link_up() ? "PHY: link 100 Mbit/s OK\n" : "PHY: sem link (cabo?)\n");
    return 0;
}

/* ------------------------------------------------------------------ MAC */
uint32_t eth_reg(uint32_t off) { return IORD_32DIRECT(ETH_MAC_BASE, off); }

void eth_init(const uint8_t mac[6])
{
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_IRQ_EN, 0);
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_MAC_LO,
                  mac[0] | (mac[1] << 8) | (mac[2] << 16) | ((uint32_t)mac[3] << 24));
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_MAC_HI, mac[4] | (mac[5] << 8));
    /* descarta quadros pendentes */
    while (eth_rx_avail()) IOWR_32DIRECT(ETH_MAC_BASE, ETH_RX_POP, 1);
}

int eth_rx_avail(void)
{
    return (IORD_32DIRECT(ETH_MAC_BASE, ETH_STATUS) & ETH_ST_RX_AVAIL) != 0;
}

int eth_rx_read(uint8_t *buf)
{
    uint32_t st  = IORD_32DIRECT(ETH_MAC_BASE, ETH_STATUS);
    int      len = IORD_32DIRECT(ETH_MAC_BASE, ETH_RX_LEN) & 0x7FF;
    int      i, nw = (len + 3) >> 2;

    if (!(st & ETH_ST_CRC_OK) || len < 18 || len > ETH_MAX_FRAME) {
        IOWR_32DIRECT(ETH_MAC_BASE, ETH_RX_POP, 1);
        return -1;
    }
    for (i = 0; i < nw; i++) {
        uint32_t w = IORD_32DIRECT(ETH_MAC_BASE, ETH_RX_WIN + (i << 2));
        buf[0] = w; buf[1] = w >> 8; buf[2] = w >> 16; buf[3] = w >> 24;
        buf += 4;
    }
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_RX_POP, 1);
    return len - 4;                                  /* remove FCS */
}

void eth_tx_send(const uint8_t *buf, int len)
{
    int i, nw = (len + 3) >> 2;
    int guard = 100000;
    while ((IORD_32DIRECT(ETH_MAC_BASE, ETH_STATUS) & ETH_ST_TX_BUSY) && --guard) ;
    for (i = 0; i < nw; i++) {
        uint32_t w = buf[0] | (buf[1] << 8) | (buf[2] << 16) | ((uint32_t)buf[3] << 24);
        IOWR_32DIRECT(ETH_MAC_BASE, ETH_TX_BUF + (i << 2), w);
        buf += 4;
    }
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_TX_LEN, len);
}

void eth_irq_enable(int en)
{
    IOWR_32DIRECT(ETH_MAC_BASE, ETH_IRQ_EN, en ? 1 : 0);
}
