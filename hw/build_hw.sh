#!/bin/bash
# Build completo: Qsys -> software do Nios -> hex da RAM on-chip -> Signal Tap
# -> compilacao Quartus. O .sof final ja contem o software (o Nios inicia sozinho).
# Rodar dentro de hw/ (Git Bash ou Nios II Command Shell):   ./build_hw.sh
set -e
cd "$(dirname "$0")"
Q=${QUARTUS_ROOTDIR:-/c/intelFPGA_lite/17.1/quartus}
EDS=${SOPC_KIT_NIOS2:-$Q/../nios2eds}

echo "== 1/5 Platform Designer: criando soc.qsys"
rm -rf soc soc.qsys soc.sopcinfo
"$Q/sopc_builder/bin/qsys-script" --script=soc_qsys.tcl --search-path="ip/**/*,\$"

echo "== 2/5 Platform Designer: gerando HDL"
"$Q/sopc_builder/bin/qsys-generate" soc.qsys --synthesis=VERILOG --output-directory=soc \
    --search-path="ip/**/*,\$" --family="Cyclone 10 LP" --part=10CL025YU256I7G

echo "== 3/5 Software: BSP + nios_eth.elf + hex da RAM (sysid novo)"
../sw/create_sw.sh
( export PATH="$EDS/sdk2/bin:$EDS/bin:$EDS/bin/gnu/H-x86_64-mingw32/bin:$PATH"
  make -C ../sw/app mem_init_generate )

echo "== 4/5 Signal Tap: nios_eth.stp -> atribuicoes no .qsf"
python gen_stp.py
"$Q/bin64/quartus_stp" nios_eth --stp_file nios_eth.stp --enable

echo "== 5/5 Quartus: compilacao completa"
"$Q/bin64/quartus_sh" --flow compile nios_eth
ls -la output_files/nios_eth.sof
