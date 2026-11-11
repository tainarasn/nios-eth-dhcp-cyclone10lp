# Componente Platform Designer (Qsys): USER HW (string + 1)
package require -exact qsys 16.1

set_module_property NAME user_hw
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "USER HW - string +1"
set_module_property DESCRIPTION "Soma 1 a cada caractere; 0xF7 vira 0x00"
set_module_property GROUP "UTFPR"
set_module_property AUTHOR "UTFPR"
set_module_property EDITABLE true
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL user_hw
add_fileset_file user_hw.v VERILOG PATH user_hw.v TOP_LEVEL_FILE

add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset reset Input 1

add_interface s0 avalon end
set_interface_property s0 addressUnits WORDS
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 bitsPerSymbol 8
set_interface_property s0 maximumPendingReadTransactions 0
set_interface_property s0 readLatency 0
set_interface_property s0 readWaitTime 1
set_interface_property s0 setupTime 0
set_interface_property s0 holdTime 0
set_interface_property s0 timingUnits Cycles
set_interface_property s0 writeWaitTime 0
add_interface_port s0 avs_address address Input 7
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_byteenable byteenable Input 4
add_interface_port s0 avs_readdata readdata Output 32
set_interface_assignment s0 embeddedsw.configuration.isFlash 0
set_interface_assignment s0 embeddedsw.configuration.isMemoryDevice 0
set_interface_assignment s0 embeddedsw.configuration.isNonVolatileStorage 0
set_interface_assignment s0 embeddedsw.configuration.isPrintableDevice 0
