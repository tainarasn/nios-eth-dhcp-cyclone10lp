// =============================================================================
// tb_eth.v - testbench: eth_rgmii_mac em loopback RGMII (TX -> RX) e user_hw
// Rodar:  cd hw/sim ; vsim -c -do run_tb.do
// =============================================================================
`timescale 1ns/1ps
module tb_eth;

    reg clk = 0, reset = 1;
    reg tx_clk = 0, tx_clk_90 = 0;
    always #10 clk = ~clk;                         // 50 MHz
    always #20 tx_clk = ~tx_clk;                   // 25 MHz
    initial begin #10; forever #20 tx_clk_90 = ~tx_clk_90; end   // +90 graus

    // ---------------- MAC
    reg  [10:0] m_addr;  reg m_rd = 0, m_wr = 0;
    reg  [31:0] m_wdata; reg [3:0] m_be = 4'hF;
    wire [31:0] m_rdata;
    wire irq, txc, tx_ctl;
    wire [3:0] txd;

    eth_rgmii_mac dut (
        .clk(clk), .reset(reset),
        .avs_address(m_addr), .avs_read(m_rd), .avs_write(m_wr),
        .avs_writedata(m_wdata), .avs_byteenable(m_be), .avs_readdata(m_rdata),
        .irq(irq), .tx_clk(tx_clk), .tx_clk_90(tx_clk_90),
        .rgmii_txc(txc), .rgmii_txd(txd), .rgmii_tx_ctl(tx_ctl),
        .rgmii_rxc(txc), .rgmii_rxd(txd), .rgmii_rx_ctl(tx_ctl)   // loopback
    );

    // ---------------- USER HW
    reg  [6:0]  u_addr; reg u_rd = 0, u_wr = 0;
    reg  [31:0] u_wdata; reg [3:0] u_be = 4'hF;
    wire [31:0] u_rdata;
    user_hw uhw (
        .clk(clk), .reset(reset),
        .avs_address(u_addr), .avs_read(u_rd), .avs_write(u_wr),
        .avs_writedata(u_wdata), .avs_byteenable(u_be), .avs_readdata(u_rdata)
    );

    integer errors = 0;

    task mwr(input [10:0] a, input [31:0] d);
        begin @(posedge clk); m_addr <= a; m_wdata <= d; m_wr <= 1;
              @(posedge clk); m_wr <= 0; end
    endtask
    task mrd(input [10:0] a, output [31:0] d);
        begin @(posedge clk); m_addr <= a; m_rd <= 1;
              @(posedge clk); m_rd <= 0;
              @(posedge clk); #1 d = m_rdata; end      // latencia 2
    endtask
    task uwr(input [6:0] a, input [31:0] d);
        begin @(posedge clk); u_addr <= a; u_wdata <= d; u_wr <= 1;
              @(posedge clk); u_wr <= 0; end
    endtask
    task urd(input [6:0] a, output [31:0] d);
        begin @(posedge clk); u_addr <= a; #1 d = u_rdata; end
    endtask

    // captura dos nibbles transmitidos (para conferir preambulo + FCS)
    reg [7:0] cap [0:2047];
    integer   cap_n, nib_i;
    reg [3:0] lo_nib;
    always @(posedge tx_clk_90) begin            // amostra como o PHY (borda de TXC)
        if (tx_ctl) begin
            if (nib_i[0] == 0) lo_nib = txd;
            else begin cap[cap_n] = {txd, lo_nib}; cap_n = cap_n + 1; end
            nib_i = nib_i + 1;
        end
    end

    reg [7:0]  frame [0:127];
    reg [31:0] d, st;
    integer    i, len, w;

    task send_frame(input integer n);
        begin
            for (w = 0; w < (n + 3) / 4; w = w + 1)
                mwr(11'h200 + w, {frame[4*w+3], frame[4*w+2], frame[4*w+1], frame[4*w]});
            cap_n = 0; nib_i = 0;
            mwr(11'h403, n);
        end
    endtask

    task check_rx(input integer exp_len, input integer exp_crc_ok);
        begin
            i = 0;
            mrd(11'h400, st);
            while (!st[0] && i < 2000) begin mrd(11'h400, st); i = i + 1; end
            if (!st[0]) begin $display("ERRO: nenhum quadro recebido"); errors = errors + 1; end
            else begin
                mrd(11'h401, d); len = d;
                $display("RX: len=%0d crc_ok=%0d irq=%0d", len, st[2], irq);
                if (len != exp_len) begin $display("ERRO: len esperado %0d", exp_len); errors = errors + 1; end
                if (st[2] != exp_crc_ok) begin $display("ERRO: crc_ok"); errors = errors + 1; end
                for (w = 0; w < 16; w = w + 1) begin
                    mrd(w, d);
                    if (d !== {frame[4*w+3], frame[4*w+2], frame[4*w+1], frame[4*w]} && 4*w+3 < 42) begin
                        $display("ERRO: palavra %0d = %h", w, d); errors = errors + 1;
                    end
                end
                mwr(11'h402, 1);              // pop
            end
        end
    endtask

    initial begin
        for (i = 0; i < 128; i = i + 1) frame[i] = 0;
        #200 reset = 0;
        #200;
        // MAC = 02:10:C1:0A:00:10, IRQ habilitada
        mwr(11'h404, 32'h0AC11002);
        mwr(11'h405, 32'h00001000);
        mwr(11'h406, 1);

        // ---------- teste 1: unicast 60 bytes
        frame[0]=8'h02; frame[1]=8'h10; frame[2]=8'hC1; frame[3]=8'h0A; frame[4]=8'h00; frame[5]=8'h10;
        frame[6]=8'h02; frame[7]=0; frame[8]=0; frame[9]=0; frame[10]=0; frame[11]=8'h01;
        frame[12]=8'h08; frame[13]=8'h00;
        for (i = 0; i < 46; i = i + 1) frame[14+i] = i;
        send_frame(60);
        check_rx(64, 1);
        $display("TX: %0d bytes capturados; preambulo %h %h ... SFD %h", cap_n, cap[0], cap[1], cap[7]);
        if (cap[7] != 8'hD5 || cap[0] != 8'h55) begin $display("ERRO: preambulo/SFD"); errors = errors + 1; end
        $display("TX FCS = %h %h %h %h (esperado 10 21 34 54)", cap[68], cap[69], cap[70], cap[71]);
        if ({cap[68],cap[69],cap[70],cap[71]} != 32'h10213454) begin $display("ERRO: FCS"); errors = errors + 1; end

        // ---------- teste 2: broadcast curto (42 bytes -> padding p/ 60)
        for (i = 0; i < 6; i = i + 1) frame[i] = 8'hFF;
        frame[12]=8'h08; frame[13]=8'h06;
        for (i = 0; i < 28; i = i + 1) frame[14+i] = i;
        for (i = 42; i < 64; i = i + 1) frame[i] = 0;
        send_frame(42);
        check_rx(64, 1);
        $display("TX FCS = %h %h %h %h (esperado a9 5a b7 99)", cap[68], cap[69], cap[70], cap[71]);
        if ({cap[68],cap[69],cap[70],cap[71]} != 32'ha95ab799) begin $display("ERRO: FCS broadcast"); errors = errors + 1; end

        // ---------- teste 3: destino de outro MAC deve ser descartado
        frame[0]=8'h02; frame[1]=8'h99; frame[2]=8'h99; frame[3]=8'h99; frame[4]=8'h99; frame[5]=8'h99;
        send_frame(60);
        #20000;
        mrd(11'h400, st);
        if (st[0]) begin $display("ERRO: quadro de outro MAC foi aceito"); errors = errors + 1; end
        else $display("RX: quadro de outro destino descartado (ok)");

        // ---------- teste USER HW: "ABC" 0xF7 0xFF 'z'
        uwr(7'h20, 32'hF7434241);
        uwr(7'h21, 32'h00007AFF);
        uwr(7'h01, 6);
        uwr(7'h00, 1);
        urd(7'h00, d);
        while (!d[1]) urd(7'h00, d);
        urd(7'h40, d);
        $display("USER HW: out[0..3] = %h (esperado 00444342)", d);
        if (d != 32'h00444342) begin $display("ERRO: user_hw palavra 0"); errors = errors + 1; end
        urd(7'h41, d);
        $display("USER HW: out[4..5] = %h (esperado ....7B00)", d[15:0]);
        if (d[15:0] != 16'h7B00) begin $display("ERRO: user_hw palavra 1"); errors = errors + 1; end

        if (errors == 0) $display("*** TODOS OS TESTES PASSARAM ***");
        else             $display("*** %0d ERRO(S) ***", errors);
        $finish;
    end

    initial begin #3000000; $display("TIMEOUT"); $finish; end
endmodule
