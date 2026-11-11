/* includes.h (stub para teste no PC/Linux) - substitui o MicroC/OS-II */
#ifndef INCLUDES_H
#define INCLUDES_H
#include <stdint.h>

typedef uint8_t  INT8U;
typedef uint16_t INT16U;
typedef uint32_t INT32U;
typedef unsigned int OS_CPU_SR;
typedef struct os_event OS_EVENT;

#define OS_CRITICAL_METHOD 3
#define OS_TICKS_PER_SEC   1000
#define OS_NO_ERR          0

void os_crit_enter(void);
void os_crit_exit(void);
#define OS_ENTER_CRITICAL() do { (void)cpu_sr; os_crit_enter(); } while (0)
#define OS_EXIT_CRITICAL()  os_crit_exit()

OS_EVENT *OSSemCreate(INT16U cnt);
void      OSSemPend(OS_EVENT *e, INT32U timeout, INT8U *err);
INT8U     OSSemPost(OS_EVENT *e);
INT16U    OSSemAccept(OS_EVENT *e);
INT32U    OSTimeGet(void);
void      OSTimeDly(INT32U ticks);
INT8U     OSTimeDlyHMSM(INT8U h, INT8U m, INT8U s, INT16U ms);

#endif
