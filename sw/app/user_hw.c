/* user_hw.c - acesso ao periferico USER HW (string + 1, 0xF7 -> 0x00) */
#include "system.h"
#include "io.h"
#include "net.h"

#define UHW_CTRL   0x000
#define UHW_LEN    0x004
#define UHW_COUNT  0x008
#define UHW_IN     0x080
#define UHW_OUT    0x100

#define UHW_BUSY   0x1
#define UHW_DONE   0x2

/* Envia n bytes ao HW, espera o processamento e le o resultado.
 * Retorna n, ou -1 em caso de timeout. */
int user_hw_process(const uint8_t *in, int n, uint8_t *out)
{
    int i, guard = 100000;

    if (n > 128) n = 128;
    for (i = 0; i < n; i += 4) {
        uint32_t w = 0;
        int k;
        for (k = 0; k < 4 && i + k < n; k++) w |= (uint32_t)in[i + k] << (8 * k);
        IOWR_32DIRECT(USER_HW_BASE, UHW_IN + i, w);
    }
    IOWR_32DIRECT(USER_HW_BASE, UHW_LEN, n);
    IOWR_32DIRECT(USER_HW_BASE, UHW_CTRL, 1);           /* start */

    while (!(IORD_32DIRECT(USER_HW_BASE, UHW_CTRL) & UHW_DONE))
        if (--guard == 0) return -1;

    for (i = 0; i < n; i += 4) {
        uint32_t w = IORD_32DIRECT(USER_HW_BASE, UHW_OUT + i);
        int k;
        for (k = 0; k < 4 && i + k < n; k++) out[i + k] = w >> (8 * k);
    }
    return n;
}

uint32_t user_hw_count(void)
{
    return IORD_32DIRECT(USER_HW_BASE, UHW_COUNT);
}
