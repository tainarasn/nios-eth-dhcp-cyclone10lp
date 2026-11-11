# Componente Platform Designer (Qsys): MAC Ethernet RGMII 10/100
package require -exact qsys 16.1

set_module_property NAME eth_rgmii_mac
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "RGMII 10/100 Ethernet MAC (simples)"
set_module_property DESCRIPTION "MAC Ethernet 100 Mbit/s RGMII com buffers RX/TX e CRC em HW"
set_module_property GROUP "UTFPR"
set_module_property AUTHOR "UTFPR"
set_module_property EDITABLE true
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL eth_rgmii_mac
add_fileset_file eth_rgmii_mac.v VERILOG PATH eth_rgmii_mac.v TOP_LEVEL_FILE

# clock / reset
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset reset Input 1

# Avalon-MM slave (latencia fixa de 2)
add_interface s0 avalon end
set_interface_property s0 addressUnits WORDS
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 bitsPerSymbol 8
set_interface_property s0 burstOnBurstBoundariesOnly false
set_interface_property s0 explicitAddressSpan 0
set_interface_property s0 holdTime 0
set_interface_property s0 linewrapBursts false
set_interface_property s0 maximumPendingReadTransactions 0
set_interface_property s0 readLatency 2
set_interface_property s0 readWaitTime 0
set_interface_property s0 setupTime 0
set_interface_property s0 timingUnits Cycles
set_interface_property s0 writeWaitTime 0
add_interface_port s0 avs_address address Input 11
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_byteenable byteenable Input 4
add_interface_port s0 avs_readdata readdata Output 32
set_interface_assignment s0 embeddedsw.configuration.isFlash 0
set_interface_assignment s0 embeddedsw.configuration.isMemoryDevice 0
set_interface_assignment s0 embeddedsw.configuration.isNonVolatileStorage 0
set_interface_assignment s0 embeddedsw.configuration.isPrintableDevice 0

# IRQ
add_interface irq interrupt end
set_interface_property irq associatedAddressablePoint s0
set_interface_property irq associatedClock clock
set_interface_property irq associatedReset reset
add_interface_port irq irq irq Output 1

# Conduit RGMII + clocks de TX (vindos da PLL do top-level)
add_interface rgmii conduit end
add_interface_port rgmii tx_clk      tx_clk    Input  1
add_interface_port rgmii tx_clk_90   tx_clk_90 Input  1
add_interface_port rgmii rgmii_txc   txc       Output 1
add_interface_port rgmii rgmii_txd   txd       Output 4
add_interface_port rgmii rgmii_tx_ctl tx_ctl   Output 1
add_interface_port rgmii rgmii_rxc   rxc       Input  1
add_interface_port rgmii rgmii_rxd   rxd       Input  4
add_interface_port rgmii rgmii_rx_ctl rx_ctl   Input  1
