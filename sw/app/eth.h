/* eth.h - driver do MAC RGMII (eth_rgmii_mac) e do PHY PEF7071 (MDIO) */
#ifndef ETH_H
#define ETH_H

#include <stdint.h>

/* offsets (bytes) dentro de ETH_MAC_BASE - ver eth_rgmii_mac.v */
#define ETH_RX_WIN   0x0000
#define ETH_TX_BUF   0x0800
#define ETH_STATUS   0x1000
#define ETH_RX_LEN   0x1004
#define ETH_RX_POP   0x1008
#define ETH_TX_LEN   0x100C
#define ETH_MAC_LO   0x1010
#define ETH_MAC_HI   0x1014
#define ETH_IRQ_EN   0x1018
#define ETH_RX_CNT   0x101C
#define ETH_TX_CNT   0x1020
#define ETH_DROP     0x1024
#define ETH_CRCERR   0x1028

#define ETH_ST_RX_AVAIL 0x1
#define ETH_ST_TX_BUSY  0x2
#define ETH_ST_CRC_OK   0x4

#define ETH_MAX_FRAME   1536

int  phy_init(void);                          /* reset + autoneg 100 Mbit/s */
int  phy_link_up(void);
void eth_init(const uint8_t mac[6]);
int  eth_rx_avail(void);
int  eth_rx_read(uint8_t *buf);               /* tam. sem FCS, ou -1 (CRC) */
void eth_tx_send(const uint8_t *buf, int len);
void eth_irq_enable(int en);
uint32_t eth_reg(uint32_t off);

/* LEDs (USER_LED0..3, ativos em nivel baixo na placa) */
#define LED_DHCP  0
#define LED_RX    1
#define LED_TX    2
#define LED_ALIVE 3
void led_set(int n, int on);
void led_toggle(int n);

/* log simples na JTAG UART (descarta caracteres se nao houver terminal) */
void log_str(const char *s);
void log_dec(uint32_t v);
void log_hex(uint32_t v);
void log_ip(uint32_t ip);

#endif
