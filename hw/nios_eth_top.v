// =============================================================================
// nios_eth_top.v - top-level para o Intel Cyclone 10 LP FPGA Evaluation Kit
// Nios II + MAC RGMII 10/100 + USER HW (string +1)
// =============================================================================
module nios_eth_top (
    input  wire       clk_50,        // C10_CLK50M  (PIN_E1)
    input  wire       user_pb0,      // USER_PB0 = reset (ativo baixo)
    input  wire [2:0] user_dip,      // USER_DIP0..2
    output wire [3:0] user_led,      // USER_LED0..3 (ativos baixo)

    // PHY Ethernet PEF7071 (RGMII)
    output wire       enet_txc,
    output wire [3:0] enet_txd,
    output wire       enet_tx_ctl,
    input  wire       enet_rxc,
    input  wire [3:0] enet_rxd,
    input  wire       enet_rx_ctl,
    output wire       enet_mdc,
    inout  wire       enet_mdio,
    output wire       enet_rst_n
);

    // ---------------------------------------------------------------- PLL
    // c0 = 25 MHz (0 graus)  -> logica TX
    // c1 = 25 MHz (90 graus) -> clock TXC encaminhado ao PHY
    // c2 = 50 MHz            -> sistema Nios II
    wire [4:0] pll_clk;
    wire       pll_locked;
    altpll #(
        .bandwidth_type          ("AUTO"),
        .clk0_divide_by          (2),
        .clk0_duty_cycle         (50),
        .clk0_multiply_by        (1),
        .clk0_phase_shift        ("0"),
        .clk1_divide_by          (2),
        .clk1_duty_cycle         (50),
        .clk1_multiply_by        (1),
        .clk1_phase_shift        ("10000"),
        .clk2_divide_by          (1),
        .clk2_duty_cycle         (50),
        .clk2_multiply_by        (1),
        .clk2_phase_shift        ("0"),
        .compensate_clock        ("CLK2"),
        .inclk0_input_frequency  (20000),
        .intended_device_family  ("Cyclone 10 LP"),
        .lpm_hint                ("CBX_MODULE_PREFIX=sys_pll"),
        .lpm_type                ("altpll"),
        .operation_mode          ("NORMAL"),
        .pll_type                ("AUTO"),
        .port_activeclock        ("PORT_UNUSED"),
        .port_areset             ("PORT_USED"),
        .port_clkbad0            ("PORT_UNUSED"),
        .port_clkbad1            ("PORT_UNUSED"),
        .port_clkloss            ("PORT_UNUSED"),
        .port_clkswitch          ("PORT_UNUSED"),
        .port_configupdate       ("PORT_UNUSED"),
        .port_fbin               ("PORT_UNUSED"),
        .port_inclk0             ("PORT_USED"),
        .port_inclk1             ("PORT_UNUSED"),
        .port_locked             ("PORT_USED"),
        .port_pfdena             ("PORT_UNUSED"),
        .port_phasecounterselect ("PORT_UNUSED"),
        .port_phasedone          ("PORT_UNUSED"),
        .port_phasestep          ("PORT_UNUSED"),
        .port_phaseupdown        ("PORT_UNUSED"),
        .port_pllena             ("PORT_UNUSED"),
        .port_scanaclr           ("PORT_UNUSED"),
        .port_scanclk            ("PORT_UNUSED"),
        .port_scanclkena         ("PORT_UNUSED"),
        .port_scandata           ("PORT_UNUSED"),
        .port_scandataout        ("PORT_UNUSED"),
        .port_scandone           ("PORT_UNUSED"),
        .port_scanread           ("PORT_UNUSED"),
        .port_scanwrite          ("PORT_UNUSED"),
        .port_clk0               ("PORT_USED"),
        .port_clk1               ("PORT_USED"),
        .port_clk2               ("PORT_USED"),
        .port_clk3               ("PORT_UNUSED"),
        .port_clk4               ("PORT_UNUSED"),
        .port_clk5               ("PORT_UNUSED"),
        .self_reset_on_loss_lock ("OFF"),
        .width_clock             (5)
    ) u_pll (
        .inclk  ({1'b0, clk_50}),
        .areset (1'b0),
        .clk    (pll_clk),
        .locked (pll_locked)
    );

    wire clk_tx    = pll_clk[0];
    wire clk_tx_90 = pll_clk[1];
    wire clk_sys   = pll_clk[2];

    // reset do sistema: botao PB0 ou PLL fora de lock
    reg [2:0] rst_sync;
    always @(posedge clk_sys or negedge pll_locked)
        if (!pll_locked) rst_sync <= 3'b000;
        else             rst_sync <= {rst_sync[1:0], user_pb0};
    wire sys_reset_n = rst_sync[2];

    // ---------------------------------------------------------------- SoC
    wire [3:0] led_n;
    wire [1:0] phy_ctrl;

    soc u_soc (
        .clk_clk         (clk_sys),
        .reset_reset_n   (sys_reset_n),
        .dip_export      (user_dip),
        .led_export      (led_n),
        .mdio_export     (enet_mdio),
        .phy_ctrl_export (phy_ctrl),
        .eth_tx_clk      (clk_tx),
        .eth_tx_clk_90   (clk_tx_90),
        .eth_txc         (enet_txc),
        .eth_txd         (enet_txd),
        .eth_tx_ctl      (enet_tx_ctl),
        .eth_rxc         (enet_rxc),
        .eth_rxd         (enet_rxd),
        .eth_rx_ctl      (enet_rx_ctl)
    );

    assign user_led   = led_n;        // o SW ja escreve em logica ativa-baixa
    assign enet_mdc   = phy_ctrl[0];
    assign enet_rst_n = phy_ctrl[1];

endmodule
