`timescale 1ns/1ps

import s32_pkg::*;

module tb_rom_loader_wave_clear;
reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;
reg download = 1'b0;
reg wr = 1'b0;
reg [26:0] addr = 27'd0;
reg [15:0] dout = 16'd0;
wire wait_req;
wire sdr_req;
wire [24:1] sdr_addr;
wire [15:0] sdr_data;
wire [1:0] sdr_be;
reg sdr_ack = 1'b0;
wire rom_loaded;
board_desc_t board;

s32_rom_loader #(.WIDE(1), .CLEAR_RF_WAVE(1)) dut (
    .clk(clk), .rst(rst), .mem_ready(1'b1),
    .ioctl_download(download), .ioctl_index(8'd0), .ioctl_wr(wr),
    .ioctl_addr(addr), .ioctl_dout(dout), .ioctl_wait(wait_req),
    .board_desc(board),
    .sdr_wr_req(sdr_req), .sdr_wr_addr(sdr_addr),
    .sdr_wr_din(sdr_data), .sdr_wr_be(sdr_be), .sdr_wr_ack(sdr_ack),
    .v25_wr(), .v25_waddr(), .v25_wdata(),
    .eep_wr(), .eep_waddr(), .eep_wdata(), .eep_loaded(),
    .rom_loaded(rom_loaded)
);

integer writes = 0;
integer cycles = 0;
reg req_seen = 1'b0;
always @(posedge clk) begin
    sdr_ack <= 1'b0;
    if (sdr_req && !req_seen) begin
        req_seen <= 1'b1;
        if (sdr_addr !== SDR_MULTIPCM_BASE[24:1] + writes)
            $fatal(1, "wave clear address %h expected %h", sdr_addr,
                   SDR_MULTIPCM_BASE[24:1] + writes);
        if (sdr_data !== 16'h0000 || sdr_be !== 2'b11)
            $fatal(1, "wave clear payload mismatch");
        sdr_ack <= 1'b1;
        writes <= writes + 1;
    end
    if (!sdr_req) req_seen <= 1'b0;
    cycles <= cycles + 1;
    if (cycles > 150000) $fatal(1, "wave clear timeout");
end

initial begin
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    // Descriptor index 0 is the final production transfer and starts a new
    // load epoch. Its first word is enough for this boot-gate fixture.
    @(negedge clk); download = 1'b1; wr = 1'b1; addr = 27'd0; dout = 16'd0;
    @(posedge clk); #1;
    @(negedge clk); wr = 1'b0; download = 1'b0;

    wait (rom_loaded);
    #1;
    if (writes != 32768)
        $fatal(1, "wave clear wrote %0d words expected 32768", writes);
    if (wait_req) $fatal(1, "loader WAIT remained asserted after wave clear");
    $display("ROM LOADER WAVE CLEAR PASS writes=%0d", writes);
    $finish;
end
endmodule
