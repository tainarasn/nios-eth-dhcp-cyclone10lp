// =============================================================================
// eth_rgmii_mac.v
// MAC Ethernet 10/100 simples com interface RGMII (modo 100 Mbit/s, 25 MHz),
// escravo Avalon-MM para o Nios II.
//
//  * RX: detecta preambulo/SFD, filtra endereco (unicast proprio / broadcast /
//        promiscuo), grava o quadro (incluindo FCS) em um de 2 buffers de 2 KB
//        e verifica o CRC-32. Gera IRQ quando ha quadro disponivel.
//  * TX: le o quadro do buffer TX (2 KB), envia preambulo + SFD, dados
//        (padding automatico ate 60 bytes), FCS calculado em HW e IFG.
//
// Mapa de registradores (enderecos em PALAVRAS de 32 bits; offset em bytes):
//   0x000-0x1FF (0x0000-0x07FF) : janela RX (somente leitura) do buffer atual
//   0x200-0x3FF (0x0800-0x0FFF) : buffer TX (somente escrita)
//   0x400 (0x1000) STATUS  R : [0] rx_avail [1] tx_busy [2] rx_crc_ok
//                               [3] rx_idx  [8] irq_en
//   0x401 (0x1004) RX_LEN  R : bytes do quadro atual (inclui 4 bytes de FCS)
//   0x402 (0x1008) RX_POP  W : libera o buffer RX atual
//   0x403 (0x100C) TX_LEN  W : escreve o tamanho e dispara a transmissao
//   0x404 (0x1010) MAC_LO RW : mac[0..3] (byte 0 = primeiro octeto do MAC)
//   0x405 (0x1014) MAC_HI RW : [15:0] mac[4..5]  [16] promiscuo
//   0x406 (0x1018) IRQ_EN RW : [0] habilita IRQ de RX
//   0x407 (0x101C) RX_CNT  R : quadros recebidos
//   0x408 (0x1020) TX_CNT  R : quadros transmitidos
//   0x409 (0x1024) DROP    R : quadros descartados (buffer cheio/tamanho)
//   0x40A (0x1028) CRCERR  R : quadros aceitos com erro de CRC
// Latencia de leitura fixa = 2 ciclos.
// =============================================================================
module eth_rgmii_mac (
    input  wire        clk,            // clock do sistema (Avalon) - 50 MHz
    input  wire        reset,          // reset sincrono ativo alto

    // Avalon-MM slave
    input  wire [10:0] avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [3:0]  avs_byteenable,
    output reg  [31:0] avs_readdata,

    output wire        irq,

    // clocks de transmissao (gerados pela PLL no top-level)
    input  wire        tx_clk,         // 25 MHz, fase 0
    input  wire        tx_clk_90,      // 25 MHz, fase 90 graus (encaminhado ao PHY)

    // RGMII
    output wire        rgmii_txc,
    output reg  [3:0]  rgmii_txd,
    output reg         rgmii_tx_ctl,
    input  wire        rgmii_rxc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl
);

    // -------------------------------------------------------------------------
    // CRC-32 Ethernet (refletido, polinomio 0xEDB88320), um byte por vez
    // -------------------------------------------------------------------------
    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0]  d;
        integer i;
        reg [31:0] c;
        begin
            c = crc;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0] ^ d[i]) c = (c >> 1) ^ 32'hEDB88320;
                else             c = (c >> 1);
            end
            crc32_byte = c;
        end
    endfunction

    function [1:0] bin2gray; input [1:0] b; bin2gray = b ^ (b >> 1); endfunction
    function [1:0] gray2bin; input [1:0] g; gray2bin = {g[1], g[1] ^ g[0]}; endfunction

    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    // =========================================================================
    // Registradores do dominio do sistema
    // =========================================================================
    reg  [31:0] mac_lo;          // mac[0..3]
    reg  [16:0] mac_hi;          // [15:0] mac[4..5], [16] promisc
    reg         irq_en;
    reg  [10:0] tx_len;
    reg         tx_req_t;        // toggle: pedido de TX
    reg  [1:0]  rd_bin;          // contador de leitura RX (2 buffers -> 2 bits)
    reg  [31:0] rx_cnt, tx_cnt;

    wire [47:0] my_mac  = {mac_hi[15:0], mac_lo};   // byte0 em [7:0]
    wire        promisc = mac_hi[16];

    // =========================================================================
    // RX - dominio rgmii_rxc
    // =========================================================================
    // reset sincronizado no dominio RX
    reg [2:0] rx_rst_sync;
    always @(posedge rgmii_rxc or posedge reset)
        if (reset) rx_rst_sync <= 3'b111;
        else       rx_rst_sync <= {rx_rst_sync[1:0], 1'b0};
    wire rx_reset = rx_rst_sync[2];

    // Em 100 Mbit/s o dado e' estavel durante todo o periodo de RXC (o mesmo
    // nibble nas duas bordas). Amostramos na borda de descida (meio do olho)
    // e depois re-registramos na borda de subida.
    (* altera_attribute = "-name FAST_INPUT_REGISTER ON" *) reg [3:0] rxd_n;
    (* altera_attribute = "-name FAST_INPUT_REGISTER ON" *) reg       rxctl_n;
    always @(negedge rgmii_rxc) begin
        rxd_n   <= rgmii_rxd;
        rxctl_n <= rgmii_rx_ctl;
    end

    reg [3:0] rx_nib;
    reg       rx_dv;
    always @(posedge rgmii_rxc) begin
        rx_nib <= rxd_n;
        rx_dv  <= rxctl_n;
    end

    localparam R_IDLE = 2'd0, R_PRE = 2'd1, R_DATA = 2'd2, R_DROP = 2'd3;
    (* preserve, syn_encoding = "user" *) reg [1:0]  rx_state;
    reg        rx_phase;          // 0 = nibble baixo, 1 = nibble alto
    reg [3:0]  rx_lo;
    reg [7:0]  rx_byte;
    reg [11:0] rx_cnt_b;          // bytes recebidos no quadro
    reg [31:0] rx_crc;
    reg        rx_is_bc, rx_is_uc;
    reg        rx_we;
    reg [11:0] rx_waddr;          // {buffer, offset[10:0]}
    reg [1:0]  wr_bin;            // contador de escrita RX
    reg [1:0]  wr_gray;
    reg [10:0] rx_len0, rx_len1;
    reg        rx_crcok0, rx_crcok1;
    (* noprune *) reg        rx_commit;         // pulso: quadro aceito (para Signal Tap)
    (* noprune *) reg        rx_sof;            // pulso: SFD detectado (para Signal Tap)
    reg [15:0] rx_drop_cnt;       // (leitura assincrona, apenas depuracao)
    reg [15:0] rx_crcerr_cnt;

    // contador de leitura sincronizado para o dominio RX
    reg [1:0] rd_gray_s1, rd_gray_s2;
    reg [1:0] rd_gray;            // (dominio sys) registrado
    always @(posedge rgmii_rxc) begin
        rd_gray_s1 <= rd_gray;
        rd_gray_s2 <= rd_gray_s1;
    end
    wire [1:0] rd_bin_rx = gray2bin(rd_gray_s2);
    wire       rx_full   = ((wr_bin - rd_bin_rx) == 2'd2);

    // byte atual de endereco de destino para comparacao
    wire [7:0] mac_byte_at = (rx_cnt_b == 12'd0) ? my_mac[7:0]   :
                             (rx_cnt_b == 12'd1) ? my_mac[15:8]  :
                             (rx_cnt_b == 12'd2) ? my_mac[23:16] :
                             (rx_cnt_b == 12'd3) ? my_mac[31:24] :
                             (rx_cnt_b == 12'd4) ? my_mac[39:32] :
                                                   my_mac[47:40];
    wire [7:0] rx_new_byte = {rx_nib, rx_lo};

    always @(posedge rgmii_rxc) begin
        if (rx_reset) begin
            rx_state      <= R_IDLE;
            rx_phase      <= 1'b0;
            rx_we         <= 1'b0;
            wr_bin        <= 2'd0;
            wr_gray       <= 2'd0;
            rx_commit     <= 1'b0;
            rx_sof        <= 1'b0;
            rx_drop_cnt   <= 16'd0;
            rx_crcerr_cnt <= 16'd0;
            rx_cnt_b      <= 12'd0;
        end else begin
            rx_we     <= 1'b0;
            rx_commit <= 1'b0;
            rx_sof    <= 1'b0;
            wr_gray   <= bin2gray(wr_bin);
            case (rx_state)
            R_IDLE: begin
                if (rx_dv) rx_state <= (rx_nib == 4'h5) ? R_PRE : R_DROP;
            end
            R_PRE: begin
                if (!rx_dv)                rx_state <= R_IDLE;
                else if (rx_nib == 4'hD) begin
                    rx_state <= R_DATA;
                    rx_phase <= 1'b0;
                    rx_cnt_b <= 12'd0;
                    rx_crc   <= 32'hFFFFFFFF;
                    rx_is_bc <= 1'b1;
                    rx_is_uc <= 1'b1;
                    rx_sof   <= 1'b1;
                end else if (rx_nib != 4'h5) rx_state <= R_DROP;
            end
            R_DATA: begin
                if (rx_dv) begin
                    if (!rx_phase) begin
                        rx_lo    <= rx_nib;
                        rx_phase <= 1'b1;
                    end else begin
                        rx_phase <= 1'b0;
                        rx_byte  <= rx_new_byte;
                        rx_crc   <= crc32_byte(rx_crc, rx_new_byte);
                        if (rx_cnt_b < 12'd6) begin
                            if (rx_new_byte != 8'hFF)        rx_is_bc <= 1'b0;
                            if (rx_new_byte != mac_byte_at)  rx_is_uc <= 1'b0;
                        end
                        if (rx_cnt_b < 12'd2047) begin
                            rx_we    <= 1'b1;
                            rx_waddr <= {wr_bin[0], rx_cnt_b[10:0]};
                        end
                        rx_cnt_b <= rx_cnt_b + 12'd1;
                    end
                end else begin
                    // fim do quadro
                    rx_state <= R_IDLE;
                    if ((rx_is_bc | rx_is_uc | promisc) && !rx_phase) begin
                        if (!rx_full && rx_cnt_b >= 12'd64 && rx_cnt_b <= 12'd1522) begin
                            if (wr_bin[0]) begin
                                rx_len1   <= rx_cnt_b[10:0];
                                rx_crcok1 <= (rx_crc == CRC_RESIDUE);
                            end else begin
                                rx_len0   <= rx_cnt_b[10:0];
                                rx_crcok0 <= (rx_crc == CRC_RESIDUE);
                            end
                            if (rx_crc != CRC_RESIDUE) rx_crcerr_cnt <= rx_crcerr_cnt + 16'd1;
                            wr_bin    <= wr_bin + 2'd1;
                            rx_commit <= 1'b1;
                        end else begin
                            rx_drop_cnt <= rx_drop_cnt + 16'd1;
                        end
                    end
                end
            end
            R_DROP: begin
                if (!rx_dv) rx_state <= R_IDLE;
            end
            endcase
        end
    end

    // Buffer RX: escrita 8 bits (RXC), leitura 32 bits (clk do sistema)
    wire [31:0] rx_q;
    wire [9:0]  rx_raddr = {rd_bin[0], avs_address[8:0]};
    altsyncram #(
        .operation_mode         ("DUAL_PORT"),
        .width_a                (8),
        .widthad_a              (12),
        .numwords_a             (4096),
        .width_b                (32),
        .widthad_b              (10),
        .numwords_b             (1024),
        .width_byteena_a        (1),
        .address_reg_b          ("CLOCK1"),
        .outdata_reg_b          ("UNREGISTERED"),
        .clock_enable_input_a   ("BYPASS"),
        .clock_enable_input_b   ("BYPASS"),
        .clock_enable_output_b  ("BYPASS"),
        .intended_device_family ("Cyclone 10 LP"),
        .lpm_type               ("altsyncram"),
        .power_up_uninitialized ("FALSE"),
        .ram_block_type         ("M9K")
    ) rx_ram (
        .clock0     (rgmii_rxc),
        .wren_a     (rx_we),
        .address_a  (rx_waddr),
        .data_a     (rx_byte),
        .clock1     (clk),
        .address_b  (rx_raddr),
        .q_b        (rx_q),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .data_b({32{1'b1}}), .eccstatus(),
        .q_a(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
    );

    // =========================================================================
    // TX - dominio tx_clk (25 MHz)
    // =========================================================================
    reg [2:0] tx_rst_sync;
    always @(posedge tx_clk or posedge reset)
        if (reset) tx_rst_sync <= 3'b111;
        else       tx_rst_sync <= {tx_rst_sync[1:0], 1'b0};
    wire tx_reset = tx_rst_sync[2];

    reg [2:0]  tx_req_s;         // sincronizador do toggle de pedido
    reg        tx_ack_t;         // toggle: transmissao concluida
    localparam T_IDLE = 3'd0, T_PRE = 3'd1, T_DATA = 3'd2, T_FCS = 3'd3, T_IFG = 3'd4;
    (* preserve, syn_encoding = "user" *) reg [2:0]  tx_state;
    reg [4:0]  tx_ncnt;          // contador de nibbles (preambulo/FCS/IFG)
    reg        tx_phase;
    reg [10:0] tx_i;             // indice do byte atual
    reg [10:0] tx_flen;          // tamanho com padding (>= 60)
    reg [10:0] tx_ulen;          // tamanho escrito pelo SW
    reg [10:0] tx_raddr;
    reg [7:0]  tx_cur;
    reg [31:0] tx_crc;
    reg [31:0] tx_fcs;
    (* noprune *) reg        tx_en;            // = rgmii_tx_ctl (copia interna p/ Signal Tap)
    wire [7:0] tx_q;

    always @(posedge tx_clk) begin
        if (tx_reset) begin
            tx_req_s     <= 3'b000;
            tx_ack_t     <= 1'b0;
            tx_state     <= T_IDLE;
            rgmii_txd    <= 4'h0;
            rgmii_tx_ctl <= 1'b0;
            tx_en        <= 1'b0;
            tx_raddr     <= 11'd0;
        end else begin
            tx_req_s <= {tx_req_s[1:0], tx_req_t};
            case (tx_state)
            T_IDLE: begin
                rgmii_tx_ctl <= 1'b0;
                tx_en        <= 1'b0;
                rgmii_txd    <= 4'h0;
                tx_raddr     <= 11'd0;
                if (tx_req_s[2] != tx_ack_t) begin
                    tx_ulen  <= tx_len;                       // estavel (sys aguarda)
                    tx_flen  <= (tx_len < 11'd60) ? 11'd60 : tx_len;
                    tx_state <= T_PRE;
                    tx_ncnt  <= 5'd0;
                    tx_crc   <= 32'hFFFFFFFF;
                end
            end
            T_PRE: begin
                // 15 nibbles 0x5 + nibble 0xD  (= 7 x 0x55 + 0xD5)
                rgmii_tx_ctl <= 1'b1;
                tx_en        <= 1'b1;
                rgmii_txd    <= (tx_ncnt == 5'd15) ? 4'hD : 4'h5;
                tx_ncnt      <= tx_ncnt + 5'd1;
                if (tx_ncnt == 5'd15) begin
                    tx_cur   <= (tx_ulen != 11'd0) ? tx_q : 8'h00;  // byte 0
                    tx_raddr <= 11'd1;
                    tx_i     <= 11'd0;
                    tx_phase <= 1'b0;
                    tx_state <= T_DATA;
                end
            end
            T_DATA: begin
                if (!tx_phase) begin
                    rgmii_txd <= tx_cur[3:0];
                    tx_crc    <= crc32_byte(tx_crc, tx_cur);
                    tx_phase  <= 1'b1;
                end else begin
                    rgmii_txd <= tx_cur[7:4];
                    tx_phase  <= 1'b0;
                    tx_cur    <= ((tx_i + 11'd1) < tx_ulen) ? tx_q : 8'h00;
                    tx_raddr  <= tx_i + 11'd2;
                    tx_i      <= tx_i + 11'd1;
                    if ((tx_i + 11'd1) == tx_flen) begin
                        tx_state <= T_FCS;
                        tx_ncnt  <= 5'd0;
                        tx_fcs   <= ~tx_crc;
                    end
                end
            end
            T_FCS: begin
                rgmii_txd <= tx_fcs[3:0];
                tx_fcs    <= {4'h0, tx_fcs[31:4]};
                tx_ncnt   <= tx_ncnt + 5'd1;
                if (tx_ncnt == 5'd7) begin
                    tx_state <= T_IFG;
                    tx_ncnt  <= 5'd0;
                end
            end
            T_IFG: begin
                // >= 12 bytes de intervalo entre quadros (24 nibbles)
                rgmii_tx_ctl <= 1'b0;
                tx_en        <= 1'b0;
                rgmii_txd    <= 4'h0;
                tx_ncnt      <= tx_ncnt + 5'd1;
                if (tx_ncnt == 5'd25) begin
                    tx_ack_t <= ~tx_ack_t;
                    tx_state <= T_IDLE;
                end
            end
            default: tx_state <= T_IDLE;
            endcase
        end
    end

    // Buffer TX: escrita 32 bits (sys), leitura 8 bits (tx_clk)
    wire        tx_we = avs_write && (avs_address[10:9] == 2'b01);
    altsyncram #(
        .operation_mode         ("DUAL_PORT"),
        .width_a                (32),
        .widthad_a              (9),
        .numwords_a             (512),
        .width_b                (8),
        .widthad_b              (11),
        .numwords_b             (2048),
        .width_byteena_a        (4),
        .byte_size              (8),
        .address_reg_b          ("CLOCK1"),
        .outdata_reg_b          ("UNREGISTERED"),
        .clock_enable_input_a   ("BYPASS"),
        .clock_enable_input_b   ("BYPASS"),
        .clock_enable_output_b  ("BYPASS"),
        .intended_device_family ("Cyclone 10 LP"),
        .lpm_type               ("altsyncram"),
        .power_up_uninitialized ("FALSE"),
        .ram_block_type         ("M9K")
    ) tx_ram (
        .clock0     (clk),
        .wren_a     (tx_we),
        .address_a  (avs_address[8:0]),
        .data_a     (avs_writedata),
        .byteena_a  (avs_byteenable),
        .clock1     (tx_clk),
        .address_b  (tx_raddr),
        .q_b        (tx_q),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .data_b({8{1'b1}}), .eccstatus(),
        .q_a(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
    );

    // Encaminhamento do clock TX ao PHY (borda deslocada 90 graus = 10 ns)
    altddio_out #(
        .width                  (1),
        .intended_device_family ("Cyclone 10 LP"),
        .lpm_type               ("altddio_out"),
        .power_up_high          ("OFF"),
        .oe_reg                 ("UNREGISTERED"),
        .extend_oe_disable      ("OFF")
    ) txc_ddio (
        .outclock   (tx_clk_90),
        .datain_h   (1'b1),
        .datain_l   (1'b0),
        .dataout    (rgmii_txc),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .oe_out(), .outclocken(1'b1),
        .sclr(1'b0), .sset(1'b0)
    );

    // =========================================================================
    // Dominio do sistema: sincronizadores, registradores e Avalon
    // =========================================================================
    reg [1:0] wr_gray_s1, wr_gray_s2;
    reg [2:0] tx_ack_s;
    reg [1:0] wr_sys_prev;
    always @(posedge clk) begin
        wr_gray_s1 <= wr_gray;
        wr_gray_s2 <= wr_gray_s1;
        tx_ack_s   <= {tx_ack_s[1:0], tx_ack_t};
    end
    wire [1:0] wr_sys   = gray2bin(wr_gray_s2);
    wire       rx_avail = (wr_sys != rd_bin);
    wire       tx_busy  = (tx_req_t != tx_ack_s[2]);
    wire [10:0] rx_len_cur  = rd_bin[0] ? rx_len1   : rx_len0;
    wire        rx_crc_cur  = rd_bin[0] ? rx_crcok1 : rx_crcok0;

    assign irq = irq_en & rx_avail;

    // pulsos no dominio do sistema (uteis para Signal Tap)
    (* noprune *) reg rx_pop_p;
    (* noprune *) reg tx_start_p;
    (* noprune *) reg tx_done_p;

    wire reg_sel = (avs_address[10:9] == 2'b10);
    always @(posedge clk) begin
        if (reset) begin
            mac_lo      <= 32'h00000000;
            mac_hi      <= 17'h0;
            irq_en      <= 1'b0;
            tx_len      <= 11'd0;
            tx_req_t    <= 1'b0;
            rd_bin      <= 2'd0;
            rd_gray     <= 2'd0;
            rx_cnt      <= 32'd0;
            tx_cnt      <= 32'd0;
            wr_sys_prev <= 2'd0;
            rx_pop_p    <= 1'b0;
            tx_start_p  <= 1'b0;
            tx_done_p   <= 1'b0;
        end else begin
            rx_pop_p   <= 1'b0;
            tx_start_p <= 1'b0;
            tx_done_p  <= (tx_ack_s[2] != tx_ack_s[1]);
            rd_gray    <= bin2gray(rd_bin);
            wr_sys_prev <= wr_sys;
            rx_cnt     <= rx_cnt + {30'd0, (wr_sys - wr_sys_prev)};
            if (tx_done_p) tx_cnt <= tx_cnt + 32'd1;
            if (avs_write && reg_sel) begin
                case (avs_address[3:0])
                4'h2: if (rx_avail) begin rd_bin <= rd_bin + 2'd1; rx_pop_p <= 1'b1; end
                4'h3: if (!tx_busy) begin
                          tx_len     <= avs_writedata[10:0];
                          tx_req_t   <= ~tx_req_t;
                          tx_start_p <= 1'b1;
                      end
                4'h4: mac_lo <= avs_writedata;
                4'h5: mac_hi <= avs_writedata[16:0];
                4'h6: irq_en <= avs_writedata[0];
                default: ;
                endcase
            end
        end
    end

    // Leitura com latencia fixa de 2 ciclos
    reg        rd_ram_q1;
    reg [31:0] reg_q1;
    always @(posedge clk) begin
        rd_ram_q1 <= (avs_address[10:9] == 2'b00);
        case (avs_address[3:0])
        4'h0:    reg_q1 <= {23'd0, irq_en, 4'd0, rd_bin[0], rx_crc_cur, tx_busy, rx_avail};
        4'h1:    reg_q1 <= {21'd0, rx_len_cur};
        4'h4:    reg_q1 <= mac_lo;
        4'h5:    reg_q1 <= {15'd0, mac_hi};
        4'h6:    reg_q1 <= {31'd0, irq_en};
        4'h7:    reg_q1 <= rx_cnt;
        4'h8:    reg_q1 <= tx_cnt;
        4'h9:    reg_q1 <= {16'd0, rx_drop_cnt};
        4'hA:    reg_q1 <= {16'd0, rx_crcerr_cnt};
        default: reg_q1 <= 32'd0;
        endcase
        avs_readdata <= rd_ram_q1 ? rx_q : reg_q1;
    end

endmodule
