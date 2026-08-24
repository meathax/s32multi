// Directed regression for MiSTer WIDE=1 (16-bit) ROM transfers.
// Verifies descriptor latching, full-word SDRAM writes, EEPROM words, and the
// rom_loaded end gate for the OutRunners-only production profile.
`timescale 1ns/1ps

module tb_rom_loader_wide;
import s32_pkg::*;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;
reg mem_ready = 1'b0;
reg ioctl_download = 1'b0;
reg [7:0] ioctl_index = 8'd0;
reg ioctl_wr = 1'b0;
reg [26:0] ioctl_addr = 27'd0;
reg [15:0] ioctl_dout = 16'd0;
wire ioctl_wait;
wire board_desc_t board_desc;
wire sdr_wr_req;
wire [24:1] sdr_wr_addr;
wire [15:0] sdr_wr_din;
wire [1:0] sdr_wr_be;
reg sdr_wr_ack = 1'b0;
wire v25_wr;
wire [15:0] v25_waddr;
wire [7:0] v25_wdata;
wire eep_wr;
wire [5:0] eep_waddr;
wire [15:0] eep_wdata;
wire eep_loaded;
wire rom_loaded;

s32_rom_loader #(.WIDE(1)) dut (
    .clk(clk), .rst(rst), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait), .board_desc(board_desc),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be), .sdr_wr_ack(sdr_wr_ack),
    .v25_wr(v25_wr), .v25_waddr(v25_waddr), .v25_wdata(v25_wdata),
    .eep_wr(eep_wr), .eep_waddr(eep_waddr), .eep_wdata(eep_wdata),
    .eep_loaded(eep_loaded), .rom_loaded(rom_loaded)
);

localparam [26:0] OFF_MAINCPU = 27'h0000040;
integer errors = 0;
integer i;

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin errors = errors + 1; $display("FAIL: %0s", name); end
end
endtask

task automatic send_word(input [7:0] index, input [26:0] address, input [15:0] data);
begin
    @(negedge clk);
    ioctl_download = 1'b1; ioctl_index = index; ioctl_addr = address;
    ioctl_dout = data; ioctl_wr = 1'b1;
    @(posedge clk); #1;
    @(negedge clk); ioctl_wr = 1'b0;
end
endtask

task automatic ack_word;
begin
    sdr_wr_ack = 1'b1;
    @(posedge clk); #1;
    sdr_wr_ack = 1'b0;
end
endtask

initial begin
    repeat (3) @(posedge clk); #1;
    check(ioctl_wait === 1'b1, "reset waits for SDRAM");
    @(negedge clk); rst = 1'b0; mem_ready = 1'b1;
    repeat (2) @(posedge clk);

    // OutRunners descriptor: Multi 32 + ADC, driving analog profile, no dual
    // communication reset override, and four valid sprite ROM banks.
    for (i = 0; i < 32; i = i + 1) begin
        if (i == 0) send_word(8'd0, i*2, 16'h1009);
        else if (i == 1) send_word(8'd0, i*2, 16'h8300);
        else send_word(8'd0, i*2, 16'h0000);
    end
    check(board_desc.multi32 && board_desc.has_adc, "wide descriptor flags");
    check(!board_desc.dual_comm_ff, "wide dual-PCB reset profile");
    check(board_desc.sprite_bank_valid, "wide descriptor profile");

    send_word(8'd0, OFF_MAINCPU, 16'hBBAA);
    check(sdr_wr_req && sdr_wr_addr === 24'h000000 &&
          sdr_wr_din === 16'hBBAA && sdr_wr_be === 2'b11,
          "wide maincpu full-word write");
    ack_word();

    @(negedge clk); ioctl_download = 1'b0;
    @(posedge clk); #1;
    check(rom_loaded, "wide download releases boot gate");

    send_word(8'd2, 27'd0, 16'h1234);
    check(eep_wr && eep_waddr === 6'd0 && eep_wdata === 16'h3412 &&
          eep_loaded, "wide factory EEPROM big-endian cell");

    send_word(8'd3, 27'd0, 16'h1234);
    check(eep_wr && eep_waddr === 6'd0 && eep_wdata === 16'h1234 &&
          eep_loaded, "wide persisted EEPROM word round-trips unchanged");

    if (errors == 0) $display("WIDE ROM LOADER PASS");
    else $display("WIDE ROM LOADER FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #100000;
    $display("WIDE ROM LOADER FAIL (timeout)");
    $finish;
end
endmodule
