#!/bin/bash
# Cria o BSP (MicroC/OS-II) e o Makefile da aplicacao a partir de hw/soc.sopcinfo
# e compila.  Rodar no "Nios II Command Shell" (ou Git Bash) dentro de sw/:
#     ./create_sw.sh
set -e
cd "$(dirname "$0")"

QROOT=${QUARTUS_ROOTDIR:-/c/intelFPGA_lite/17.1/quartus}
EDS=${SOPC_KIT_NIOS2:-$QROOT/../nios2eds}
export PATH="$EDS/sdk2/bin:$EDS/bin:$EDS/bin/gnu/H-x86_64-mingw32/bin:$PATH"

rm -rf bsp
mkdir -p bsp
nios2-bsp-create-settings.exe --type UCOSII --sopc ../hw/soc.sopcinfo \
  --settings bsp/settings.bsp --bsp-dir bsp \
  --script "$(cygpath -m "$EDS/sdk2/bin/bsp-set-defaults.tcl" 2>/dev/null || echo "$EDS/sdk2/bin/bsp-set-defaults.tcl")" \
  --set hal.enable_small_c_library true \
  --set hal.enable_reduced_device_drivers true \
  --set hal.make.bsp_cflags_optimization -Os \
  --set hal.enable_c_plus_plus false \
  --set hal.enable_clean_exit false \
  --set hal.enable_exit false \
  --set hal.enable_sim_optimize false \
  --set hal.stdin jtag_uart --set hal.stdout jtag_uart --set hal.stderr jtag_uart \
  --set hal.sys_clk_timer sys_clk_timer --set hal.timestamp_timer none \
  --set ucosii.os_max_tasks 4 \
  --set ucosii.os_lowest_prio 12 \
  --set ucosii.os_thread_safe_newlib 0 \
  --set ucosii.miscellaneous.os_debug_en 0 \
  --set ucosii.miscellaneous.os_task_stat_en 0 \
  --set ucosii.miscellaneous.os_task_stat_stk_chk_en 0 \
  --set ucosii.miscellaneous.os_event_name_size 0 \
  --set ucosii.miscellaneous.os_max_events 8 \
  --set ucosii.miscellaneous.os_task_idle_stk_size 256 \
  --set ucosii.miscellaneous.os_task_stat_stk_size 128 \
  --set ucosii.task.os_task_name_size 0 \
  --set ucosii.task.os_task_profile_en 0 \
  --set ucosii.task.os_task_query_en 0 \
  --set ucosii.task.os_task_change_prio_en 0 \
  --set ucosii.task.os_task_del_en 0 \
  --set ucosii.task.os_task_suspend_en 0 \
  --set ucosii.os_flag_en 1 \
  --set ucosii.event_flag.os_max_flags 2 \
  --set ucosii.event_flag.os_flag_query_en 0 \
  --set ucosii.event_flag.os_flag_del_en 0 \
  --set ucosii.event_flag.os_flag_name_size 0 \
  --set ucosii.os_mutex_en 0 \
  --set ucosii.os_mbox_en 0 \
  --set ucosii.os_mem_en 0 \
  --set ucosii.queue.os_max_qs 2 \
  --set ucosii.queue.os_q_del_en 0 \
  --set ucosii.queue.os_q_flush_en 0 \
  --set ucosii.queue.os_q_post_front_en 0 \
  --set ucosii.queue.os_q_post_opt_en 0 \
  --set ucosii.queue.os_q_query_en 0 \
  --set ucosii.semaphore.os_sem_del_en 0 \
  --set ucosii.semaphore.os_sem_query_en 0 \
  --set ucosii.semaphore.os_sem_set_en 0 \
  --set ucosii.time.os_time_dly_resume_en 0 \
  --set ucosii.time.os_time_get_set_en 1

cd app
nios2-app-generate-makefile.exe --bsp-dir ../bsp --elf-name nios_eth.elf   --src-files main.c eth.c net.c user_hw.c   --set APP_CFLAGS_OPTIMIZATION -Os

make
nios2-elf-size nios_eth.elf
