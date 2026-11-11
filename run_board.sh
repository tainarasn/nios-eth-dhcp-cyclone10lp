#!/bin/bash
# Programa a FPGA e abre o terminal JTAG UART.
# O software do Nios ja esta embutido no .sof (RAM on-chip inicializada), entao
# o Nios comeca a rodar assim que a FPGA e' programada.
# Placa ligada via USB-Blaster II (on-board) e cabo Ethernet no switch/roteador
# que tem o servidor DHCP (o mesmo em que o PC esta conectado).
#   ./run_board.sh            programa e abre o terminal
#   ./run_board.sh --elf      tambem recarrega sw/app/nios_eth.elf via JTAG
set -e
cd "$(dirname "$0")"
Q=${QUARTUS_ROOTDIR:-/c/intelFPGA_lite/17.1/quartus}
EDS=${SOPC_KIT_NIOS2:-$Q/../nios2eds}
export PATH="$Q/bin64:$EDS/bin:$EDS/bin/gnu/H-x86_64-mingw32/bin:$PATH"

echo "== Cabos JTAG:"
jtagconfig

echo "== Programando a FPGA (hw/output_files/nios_eth.sof)"
quartus_pgm -m jtag -o "p;hw/output_files/nios_eth.sof"

if [ "$1" = "--elf" ]; then
    echo "== Recarregando sw/app/nios_eth.elf no Nios II"
    nios2-download -g sw/app/nios_eth.elf
fi

echo "== Terminal JTAG UART (Ctrl+C para sair) - o IP obtido por DHCP aparece aqui"
echo "   (se o Nios ja imprimiu antes de abrir, aperte USER_PB0 para reiniciar)"
nios2-terminal
