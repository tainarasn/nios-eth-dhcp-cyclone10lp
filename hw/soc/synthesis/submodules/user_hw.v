// =============================================================================
// user_hw.v  -  "USER HW" do trabalho
// Recebe uma string (ate 128 bytes; a aplicacao usa no maximo 100) e devolve
// cada caractere somado de 1. Se o caractere for 0xF7, ele vira 0x00.
//
// Mapa (enderecos em PALAVRAS de 32 bits; offset em bytes):
//   0x00 (0x000) CTRL   W: [0]=1 inicia o processamento
//                       R: [0] busy  [1] done
//   0x01 (0x004) LEN   RW: numero de caracteres (0..128)
//   0x02 (0x008) COUNT  R: quantas strings ja foram processadas
//   0x20-0x3F (0x080-0x0FF) IN  RW: buffer de entrada (4 chars por palavra,
//                                   byte 0 = primeiro caractere)
//   0x40-0x5F (0x100-0x17F) OUT  R: buffer de saida
// Processa 1 caractere por ciclo de clock.
// =============================================================================
module user_hw (
    input  wire        clk,
    input  wire        reset,
    input  wire [6:0]  avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [3:0]  avs_byteenable,
    output reg  [31:0] avs_readdata
);

    reg [7:0]  in_mem  [0:127];
    reg [7:0]  out_mem [0:127];
    reg [7:0]  len;
    reg [7:0]  idx;
    reg        busy, done;
    reg [31:0] count;

    // sinais para o Signal Tap
    (* noprune *) reg        start_p;          // pulso de inicio
    (* noprune *) reg [7:0]  cur_in;           // caractere em processamento
    (* noprune *) reg [7:0]  cur_out;

    function [7:0] transform;
        input [7:0] c;
        transform = (c == 8'hF7) ? 8'h00 : (c + 8'd1);
    endfunction

    wire wr_in = avs_write && (avs_address[6:5] == 2'b01);
    wire [4:0] w = avs_address[4:0];

    integer k;
    always @(posedge clk) begin
        if (reset) begin
            len     <= 8'd0;
            idx     <= 8'd0;
            busy    <= 1'b0;
            done    <= 1'b0;
            count   <= 32'd0;
            start_p <= 1'b0;
            cur_in  <= 8'd0;
            cur_out <= 8'd0;
        end else begin
            start_p <= 1'b0;

            // escrita no buffer de entrada (com byteenable)
            if (wr_in && !busy) begin
                if (avs_byteenable[0]) in_mem[{w, 2'd0}] <= avs_writedata[7:0];
                if (avs_byteenable[1]) in_mem[{w, 2'd1}] <= avs_writedata[15:8];
                if (avs_byteenable[2]) in_mem[{w, 2'd2}] <= avs_writedata[23:16];
                if (avs_byteenable[3]) in_mem[{w, 2'd3}] <= avs_writedata[31:24];
            end

            if (avs_write && avs_address == 7'd1 && !busy)
                len <= (avs_writedata[7:0] > 8'd128) ? 8'd128 : avs_writedata[7:0];

            if (avs_write && avs_address == 7'd0 && avs_writedata[0] && !busy) begin
                idx     <= 8'd0;
                done    <= 1'b0;
                start_p <= 1'b1;
                if (len == 8'd0) begin
                    done  <= 1'b1;
                    count <= count + 32'd1;
                end else
                    busy <= 1'b1;
            end else if (busy) begin
                cur_in  <= in_mem[idx[6:0]];
                cur_out <= transform(in_mem[idx[6:0]]);
                out_mem[idx[6:0]] <= transform(in_mem[idx[6:0]]);
                idx <= idx + 8'd1;
                if (idx + 8'd1 == len) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    count <= count + 32'd1;
                end
            end
        end
    end

    // leitura combinacional (latencia 0)
    always @(*) begin
        case (avs_address[6:5])
        2'b00: begin
            case (avs_address[1:0])
            2'd0:    avs_readdata = {30'd0, done, busy};
            2'd1:    avs_readdata = {24'd0, len};
            2'd2:    avs_readdata = count;
            default: avs_readdata = 32'd0;
            endcase
        end
        2'b01:   avs_readdata = {in_mem[{w,2'd3}], in_mem[{w,2'd2}], in_mem[{w,2'd1}], in_mem[{w,2'd0}]};
        2'b10:   avs_readdata = {out_mem[{w,2'd3}], out_mem[{w,2'd2}], out_mem[{w,2'd1}], out_mem[{w,2'd0}]};
        default: avs_readdata = 32'd0;
        endcase
    end

endmodule
