`timescale 1ns/1ps

module tb_rom_loader_orunners;
reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;
reg mem_ready = 1'b0;
reg ioctl_download = 1'b0;
reg [7:0] ioctl_index = 0;
reg ioctl_wr = 0;
reg [26:0] ioctl_addr = 0;
reg [15:0] ioctl_dout = 0;
wire ioctl_wait;
wire board_desc_t board_desc;
wire sdr_wr_req;
wire [24:1] sdr_wr_addr;
wire [15:0] sdr_wr_din;
wire [1:0] sdr_wr_be;
reg sdr_wr_ack = 0;
wire v25_wr;
wire [15:0] v25_waddr;
wire [7:0] v25_wdata;
wire eep_wr;
wire [5:0] eep_waddr;
wire [15:0] eep_wdata;
wire eep_loaded;
wire rom_loaded;
integer errors = 0;

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

task automatic send_word(input [7:0] index, input [26:0] address,
                         input [15:0] data);
begin
    @(negedge clk);
    ioctl_download = 1'b1;
    ioctl_index = index;
    ioctl_addr = address;
    ioctl_dout = data;
    ioctl_wr = 1'b1;
    @(posedge clk); #1;
    ioctl_wr = 1'b0;
end
endtask

task automatic ack_word;
begin
    sdr_wr_ack = 1'b1;
    @(posedge clk); #1;
    sdr_wr_ack = 1'b0;
end
endtask

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("FAIL: %0s", name);
    end
end
endtask

initial begin
    repeat (3) @(posedge clk); #1;
    check(ioctl_wait, "reset waits for SDRAM");
    @(negedge clk); rst = 1'b0; mem_ready = 1'b1;
    repeat (2) @(posedge clk);

    // The OutRunners stream has no accepted V25/MCU index.
    send_word(8'd8, 27'd0, 16'h1234);
    check(!sdr_wr_req && !v25_wr, "MCU index is rejected");

    // Optimized sprite index 9 starts at the fixed sprite aperture.
    send_word(8'd9, 27'd0, 16'hABCD);
    check(sdr_wr_req && sdr_wr_addr === 24'h800000 &&
          sdr_wr_din === 16'hABCD && sdr_wr_be === 2'b11,
          "sprite index maps directly to sprite aperture");
    ack_word();

    // Main CPU index remains a normal fixed-offset SDRAM region.
    send_word(8'd4, 27'd0, 16'h55AA);
    check(sdr_wr_req && sdr_wr_addr === 24'h000000 &&
          sdr_wr_din === 16'h55AA, "main index maps to main aperture");
    ack_word();

    if (errors == 0) $display("OUTRUNNERS ROM LOADER PASS");
    else $display("OUTRUNNERS ROM LOADER FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #100000;
    $display("OUTRUNNERS ROM LOADER FAIL (timeout)");
    $finish;
end
endmodule
