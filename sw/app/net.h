/* net.h - pilha TCP/IP minima: Ethernet II, ARP, IPv4, ICMP, UDP/DHCP, TCP/HTTP */
#ifndef NET_H
#define NET_H

#include <stdint.h>
#include "eth.h"

/* buffer de pacote (pool compartilhado entre as threads) */
typedef struct pkt {
    uint16_t len;
    uint8_t  data[ETH_MAX_FRAME + 4];
} pkt_t;

extern uint8_t  my_mac[6];
extern uint32_t my_ip, my_mask, my_gw;

void   net_init(void);
pkt_t *pkt_alloc(void);           /* bloqueia ate 0,5 s; NULL se nao houver */
void   pkt_free(pkt_t *p);

/* RX thread: processa um quadro recebido */
void   net_input(uint8_t *frame, int len);
/* TX thread: temporizacao (DHCP, retransmissoes TCP) - chamar a cada 100 ms */
void   net_tick_100ms(void);

/* entrega o pacote a fila da thread de transmissao (implementado em main.c) */
void   net_tx_enqueue(pkt_t *p);
/* chamado por pkt_alloc quando o pool esta vazio (transmite se for a thread TX) */
void   net_tx_poll(void);

/* USER HW (user_hw.c) */
int    user_hw_process(const uint8_t *in, int n, uint8_t *out);
uint32_t user_hw_count(void);

#endif
