# =============================================================================
# soc_qsys.tcl - cria o sistema Platform Designer "soc.qsys"
# Uso:  qsys-script --script=soc_qsys.tcl --search-path="ip/**/*,$"
# =============================================================================
package require -exact qsys 16.1

create_system soc
set_project_property DEVICE_FAMILY {Cyclone 10 LP}
set_project_property DEVICE {10CL025YU256I7G}
set_project_property HIDE_FROM_IP_CATALOG {false}

# Tamanho da memoria on-chip do Nios (codigo + dados)
set RAM_BYTES 45056

# ---------------------------------------------------------------- clock
add_instance clk_0 clock_source
set_instance_parameter_value clk_0 clockFrequency {50000000.0}
set_instance_parameter_value clk_0 clockFrequencyKnown {1}
set_instance_parameter_value clk_0 resetSynchronousEdges {DEASSERT}

# ---------------------------------------------------------------- Nios II/e
add_instance cpu altera_nios2_gen2
set_instance_parameter_value cpu impl {Tiny}
set_instance_parameter_value cpu resetSlave {ram.s1}
set_instance_parameter_value cpu resetOffset {0}
set_instance_parameter_value cpu exceptionSlave {ram.s1}
set_instance_parameter_value cpu exceptionOffset {32}
set_instance_parameter_value cpu debug_enabled {1}

# ---------------------------------------------------------------- memoria
add_instance ram altera_avalon_onchip_memory2
set_instance_parameter_value ram memorySize $RAM_BYTES
set_instance_parameter_value ram dataWidth {32}
set_instance_parameter_value ram initMemContent {1}

# ---------------------------------------------------------------- perifericos
add_instance jtag_uart altera_avalon_jtag_uart
set_instance_parameter_value jtag_uart readBufferDepth {64}
set_instance_parameter_value jtag_uart writeBufferDepth {64}

add_instance sysid altera_avalon_sysid_qsys
set_instance_parameter_value sysid id {281673729}

add_instance sys_clk_timer altera_avalon_timer
set_instance_parameter_value sys_clk_timer period {1}
set_instance_parameter_value sys_clk_timer periodUnits {MSEC}

# LEDs (4, ativos em nivel baixo na placa)
add_instance led altera_avalon_pio
set_instance_parameter_value led width {4}
set_instance_parameter_value led direction {Output}
set_instance_parameter_value led resetValue {15}

# Chaves DIP (3) - usadas no ultimo byte do MAC
add_instance dip altera_avalon_pio
set_instance_parameter_value dip width {3}
set_instance_parameter_value dip direction {Input}

# Controle do PHY: [0] MDC, [1] ENET_RSTn
add_instance phy_ctrl altera_avalon_pio
set_instance_parameter_value phy_ctrl width {2}
set_instance_parameter_value phy_ctrl direction {Output}
set_instance_parameter_value phy_ctrl resetValue {0}

# MDIO (bidirecional)
add_instance mdio altera_avalon_pio
set_instance_parameter_value mdio width {1}
set_instance_parameter_value mdio direction {Bidir}

# Componentes proprios
add_instance eth_mac eth_rgmii_mac
add_instance user_hw user_hw

# ---------------------------------------------------------------- clocks/resets
foreach inst {cpu ram jtag_uart sysid sys_clk_timer led dip phy_ctrl mdio eth_mac user_hw} {
    if {$inst == "ram"} { set c clk1; set r reset1 } \
    elseif {$inst == "eth_mac" || $inst == "user_hw"} { set c clock; set r reset } \
    else { set c clk; set r reset }
    add_connection clk_0.clk $inst.$c
    add_connection clk_0.clk_reset $inst.$r
    add_connection cpu.debug_reset_request $inst.$r
}

# ---------------------------------------------------------------- barramento
add_connection cpu.instruction_master ram.s1
add_connection cpu.instruction_master cpu.debug_mem_slave
add_connection cpu.data_master ram.s1
add_connection cpu.data_master cpu.debug_mem_slave

set slaves {
    {jtag_uart.avalon_jtag_slave 0x00021000}
    {sysid.control_slave         0x00021008}
    {sys_clk_timer.s1            0x00021020}
    {led.s1                      0x00021040}
    {dip.s1                      0x00021050}
    {phy_ctrl.s1                 0x00021060}
    {mdio.s1                     0x00021070}
    {user_hw.s0                  0x00021200}
    {eth_mac.s0                  0x00024000}
}
foreach s $slaves {
    add_connection cpu.data_master [lindex $s 0]
    set_connection_parameter_value cpu.data_master/[lindex $s 0] baseAddress [lindex $s 1]
}
set_connection_parameter_value cpu.data_master/ram.s1 baseAddress {0x00010000}
set_connection_parameter_value cpu.instruction_master/ram.s1 baseAddress {0x00010000}
set_connection_parameter_value cpu.data_master/cpu.debug_mem_slave baseAddress {0x00020800}
set_connection_parameter_value cpu.instruction_master/cpu.debug_mem_slave baseAddress {0x00020800}

# ---------------------------------------------------------------- interrupcoes
add_connection cpu.irq jtag_uart.irq
set_connection_parameter_value cpu.irq/jtag_uart.irq irqNumber {0}
add_connection cpu.irq sys_clk_timer.irq
set_connection_parameter_value cpu.irq/sys_clk_timer.irq irqNumber {1}
add_connection cpu.irq eth_mac.irq
set_connection_parameter_value cpu.irq/eth_mac.irq irqNumber {2}

# ---------------------------------------------------------------- exportados
set_interface_property clk EXPORT_OF clk_0.clk_in
set_interface_property reset EXPORT_OF clk_0.clk_in_reset
set_interface_property led EXPORT_OF led.external_connection
set_interface_property dip EXPORT_OF dip.external_connection
set_interface_property phy_ctrl EXPORT_OF phy_ctrl.external_connection
set_interface_property mdio EXPORT_OF mdio.external_connection
set_interface_property eth EXPORT_OF eth_mac.rgmii

save_system soc.qsys
