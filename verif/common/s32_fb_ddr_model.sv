//============================================================================
// Production framebuffer + deterministic MiSTer-style DDR model.
//
// Used by real-ROM qualification to exercise the same s32_fb_if RTL as the
// hardware top.  It injects reproducible request stalls and read-data bubbles,
// checks stalled-request stability, and measures service deadlines.
//============================================================================
`timescale 1ns/1ps

module s32_fb_ddr_model #(
    parameter integer LINE_DEADLINE_CYCLES = 5900,
    parameter integer SERVICE_DEADLINE_CYCLES = 8192
)(
    input             clk,
    input             rst,

    input             wr_start,
    input       [1:0] wr_buf,
    input       [8:0] wr_x,
    input       [7:0] wr_y,
    input             wr_valid,
    input      [15:0] wr_pix,
    input             wr_end,
    input             wr_shadow,
    output            wr_busy,
    output            wr_can_start,

    input             er_req,
    input       [1:0] er_buf,
    input       [7:0] er_y,
    output            er_ack,

    input             rd_req,
    input       [1:0] rd_buf,
    input       [7:0] rd_y,
    output            rd_ack,
    input       [8:0] rd_x,
    output     [15:0] rd_pix,

    // second (Multi32 screen-B) read lane, pass straight through to the DUT
    input             rd2_req,
    input       [1:0] rd2_buf,
    input       [7:0] rd2_y,
    output            rd2_ack,
    output     [15:0] rd2_pix,

    output reg [31:0] write_accepts,
    output reg [31:0] sprite_write_accepts,
    output reg        sprite_write_accepted,
    output reg [31:0] run_starts,
    output reg [31:0] run_pixels,
    output reg [31:0] read_accepts,
    output reg [31:0] line_acks,
    output reg [31:0] line_acks_a,
    output reg [31:0] line_acks_b,
    output reg [31:0] max_wr_wait,
    output reg [31:0] max_rd_wait,
    output reg [31:0] max_rd_wait_a,
    output reg [31:0] max_rd_wait_b,
    output reg [31:0] max_er_wait,
    output reg        deadline_fail
);

wire        dd_busy;
wire [7:0]  dd_burst;
wire [28:0] dd_addr;
reg  [63:0] dd_dout;
reg         dd_ready;
wire        dd_rd, dd_we;
wire [63:0] dd_din;
wire [7:0]  dd_be;

s32_fb_if #(.FB_BASE(32'h0000_0000)) dut (
    .clk(clk), .rst(rst),
    .DDRAM_BUSY(dd_busy), .DDRAM_BURSTCNT(dd_burst),
    .DDRAM_ADDR(dd_addr), .DDRAM_DOUT(dd_dout),
    .DDRAM_DOUT_READY(dd_ready), .DDRAM_RD(dd_rd),
    .DDRAM_DIN(dd_din), .DDRAM_BE(dd_be), .DDRAM_WE(dd_we),
    .wr_start(wr_start), .wr_buf(wr_buf), .wr_x(wr_x), .wr_y(wr_y),
    .wr_valid(wr_valid), .wr_pix(wr_pix), .wr_end(wr_end),
    .wr_shadow(wr_shadow), .wr_busy(wr_busy),
    .wr_can_start(wr_can_start),
    .er_req(er_req), .er_buf(er_buf), .er_y(er_y), .er_ack(er_ack),
    .rd_req(rd_req), .rd_buf(rd_buf), .rd_y(rd_y), .rd_ack(rd_ack),
    .rd_x(rd_x), .rd_pix(rd_pix),
    .rd2_req(rd2_req), .rd2_buf(rd2_buf), .rd2_y(rd2_y), .rd2_ack(rd2_ack),
    .rd2_pix(rd2_pix)
);

// Four buffers x 256 lines x 128 64-bit words.  Transparent initialization
// removes irrelevant host-memory power-up noise; the game still exercises the
// production erase engine on every commanded buffer erase.
reg [63:0] ddr [0:131071];
integer init_i;
initial begin
    for (init_i = 0; init_i < 131072; init_i = init_i + 1)
        ddr[init_i] = 64'hffff_ffff_ffff_ffff;
end

reg [7:0] busy_lfsr;
reg [31:0] model_cycle;
reg busy_r;
assign dd_busy = busy_r;

reg [16:0] read_addr;
reg  [7:0] read_left;
reg  [3:0] read_delay;
wire [16:0] local_addr = dd_addr[16:0];

always @(posedge clk) begin
    dd_ready <= 1'b0;
    sprite_write_accepted <= 1'b0;
    if (rst) begin
        busy_lfsr   <= 8'ha5;
        model_cycle <= 0;
        busy_r      <= 1'b0;
        read_addr   <= 0;
        read_left   <= 0;
        read_delay  <= 0;
        dd_dout     <= 0;
        write_accepts <= 0;
        sprite_write_accepts <= 0;
        sprite_write_accepted <= 1'b0;
        run_starts <= 0;
        run_pixels <= 0;
        read_accepts  <= 0;
    end
    else begin
        model_cycle <= model_cycle + 1'd1;
        busy_lfsr <= {busy_lfsr[6:0],
                      busy_lfsr[7] ^ busy_lfsr[5] ^
                      busy_lfsr[4] ^ busy_lfsr[3]};
        busy_r <= ((model_cycle % 13) == 4) ||
                  (busy_lfsr[0] && busy_lfsr[3]);

        if (dd_we && !dd_busy) begin
            write_accepts <= write_accepts + 1'd1;
            if (wr_busy) begin
                sprite_write_accepts <= sprite_write_accepts + 1'd1;
                sprite_write_accepted <= 1'b1;
            end
            if (dd_burst !== 8'd1)
                $fatal(1, "GA2 DDR write burst=%0d, expected 1", dd_burst);
            if (dd_be[0]) ddr[local_addr][7:0]   <= dd_din[7:0];
            if (dd_be[1]) ddr[local_addr][15:8]  <= dd_din[15:8];
            if (dd_be[2]) ddr[local_addr][23:16] <= dd_din[23:16];
            if (dd_be[3]) ddr[local_addr][31:24] <= dd_din[31:24];
            if (dd_be[4]) ddr[local_addr][39:32] <= dd_din[39:32];
            if (dd_be[5]) ddr[local_addr][47:40] <= dd_din[47:40];
            if (dd_be[6]) ddr[local_addr][55:48] <= dd_din[55:48];
            if (dd_be[7]) ddr[local_addr][63:56] <= dd_din[63:56];
        end

        if (wr_start) run_starts <= run_starts + 1'd1;
        if (wr_valid) run_pixels <= run_pixels + 1'd1;

        if (dd_rd && !dd_busy) begin
            if (read_left != 0)
                $fatal(1, "GA2 DDR accepted overlapping reads");
            read_accepts <= read_accepts + 1'd1;
            read_addr  <= local_addr;
            read_left  <= dd_burst;
            read_delay <= 4'd2 + model_cycle[1:0];
        end
        else if (read_left != 0) begin
            if (read_delay != 0)
                read_delay <= read_delay - 1'd1;
            else if (model_cycle[2:0] != 3'b101) begin
                dd_dout  <= ddr[read_addr];
                dd_ready <= 1'b1;
                read_addr <= read_addr + 1'd1;
                read_left <= read_left - 1'd1;
            end
        end
    end
end

// A stalled MiSTer request must remain bit-for-bit stable.
reg stall_seen;
reg stall_rd, stall_we;
reg [28:0] stall_addr;
reg [7:0] stall_burst, stall_be;
reg [63:0] stall_din;
always @(negedge clk) begin
    if (rst || !dd_busy) begin
        stall_seen = 1'b0;
    end
    else if (stall_seen) begin
        if ({dd_rd, dd_we, dd_addr, dd_burst} !==
            {stall_rd, stall_we, stall_addr, stall_burst})
            $fatal(1, "GA2 DDR request changed while busy");
        if (stall_we && {dd_din, dd_be} !== {stall_din, stall_be})
            $fatal(1, "GA2 DDR write payload changed while busy");
    end
    else if (dd_rd || dd_we) begin
        stall_seen  = 1'b1;
        stall_rd    = dd_rd;
        stall_we    = dd_we;
        stall_addr  = dd_addr;
        stall_burst = dd_burst;
        stall_din   = dd_din;
        stall_be    = dd_be;
    end
end

reg rd_ack_d, rd2_ack_d;
reg [31:0] wr_wait, rd_wait_a, rd_wait_b, er_wait;
always @(posedge clk) begin
    if (rst) begin
        rd_ack_d <= 0;
        rd2_ack_d <= 0;
        line_acks <= 0;
        line_acks_a <= 0;
        line_acks_b <= 0;
        wr_wait <= 0; rd_wait_a <= 0; rd_wait_b <= 0; er_wait <= 0;
        max_wr_wait <= 0; max_rd_wait <= 0; max_er_wait <= 0;
        max_rd_wait_a <= 0; max_rd_wait_b <= 0;
        deadline_fail <= 0;
    end
    else begin
        rd_ack_d <= rd_ack;
        rd2_ack_d <= rd2_ack;
        if (rd_ack && !rd_ack_d) begin
            line_acks <= line_acks + 1'd1;
            line_acks_a <= line_acks_a + 1'd1;
        end
        if (rd2_ack && !rd2_ack_d) begin
            line_acks <= line_acks + 1'd1;
            line_acks_b <= line_acks_b + 1'd1;
        end

        if (wr_busy) begin
            wr_wait <= wr_wait + 1'd1;
            if (wr_wait + 1'd1 > max_wr_wait) max_wr_wait <= wr_wait + 1'd1;
            if (wr_wait + 1'd1 >= SERVICE_DEADLINE_CYCLES) begin
                deadline_fail <= 1'b1;
                $fatal(1, "GA2 framebuffer sprite flush exceeded %0d clocks",
                       SERVICE_DEADLINE_CYCLES);
            end
        end
        else wr_wait <= 0;

        if (rd_req && !rd_ack) begin
            rd_wait_a <= rd_wait_a + 1'd1;
            if (rd_wait_a + 1'd1 > max_rd_wait_a) max_rd_wait_a <= rd_wait_a + 1'd1;
            if (rd_wait_a + 1'd1 > max_rd_wait) max_rd_wait <= rd_wait_a + 1'd1;
            if (rd_wait_a + 1'd1 >= LINE_DEADLINE_CYCLES) begin
                deadline_fail <= 1'b1;
                $fatal(1, "GA2 framebuffer line read A exceeded %0d clocks",
                       LINE_DEADLINE_CYCLES);
            end
        end
        else rd_wait_a <= 0;

        if (rd2_req && !rd2_ack) begin
            rd_wait_b <= rd_wait_b + 1'd1;
            if (rd_wait_b + 1'd1 > max_rd_wait_b) max_rd_wait_b <= rd_wait_b + 1'd1;
            if (rd_wait_b + 1'd1 > max_rd_wait) max_rd_wait <= rd_wait_b + 1'd1;
            if (rd_wait_b + 1'd1 >= LINE_DEADLINE_CYCLES) begin
                deadline_fail <= 1'b1;
                $fatal(1, "GA2 framebuffer line read B exceeded %0d clocks",
                       LINE_DEADLINE_CYCLES);
            end
        end
        else rd_wait_b <= 0;

        if (er_req && !er_ack) begin
            er_wait <= er_wait + 1'd1;
            if (er_wait + 1'd1 > max_er_wait) max_er_wait <= er_wait + 1'd1;
            if (er_wait + 1'd1 >= SERVICE_DEADLINE_CYCLES) begin
                deadline_fail <= 1'b1;
                $fatal(1, "GA2 framebuffer erase line exceeded %0d clocks",
                       SERVICE_DEADLINE_CYCLES);
            end
        end
        else er_wait <= 0;
    end
end

endmodule
