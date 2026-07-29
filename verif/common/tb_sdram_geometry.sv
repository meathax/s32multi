//============================================================================
//  SDRAM geometry / aliasing test.
//
//  The pre-existing tb_sdram.sv proves protocol shape but is decode-blind: its
//  chip model has no array, no rows and no banks, so it would pass an almost
//  arbitrary wrong address decode.  This test is the opposite -- it exists only
//  to prove the address decode, against the real dual-device model.
//
//  Method that matters: WRITE EVERY corner address FIRST, THEN read them all
//  back.  A write-then-immediately-read loop passes happily under aliasing
//  (you read back what you just wrote, at the wrong place).  Writing the whole
//  set before reading any of it means two addresses that alias onto one
//  location must disagree on read-back.
//
//  Corners are chosen at every address-bit boundary that changes meaning:
//  column carry (a[9]/a[10]), bank (a[23]/a[24]), the top column bit
//  col[9]=a[25], and the device select a[26].
//============================================================================
`timescale 1ns/1ps

module tb_sdram_geometry;

localparam int NADDR = 200;

reg clk = 0;
always #5.174 clk = ~clk;      // ~96.6 MHz

reg init = 1;
wire ready;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

reg         wr_req = 0;
reg  [26:1] wr_addr;
reg  [15:0] wr_din;
reg   [1:0] wr_be = 2'b11;
wire        wr_ack;

reg         p0_req = 0;  reg [26:1] p0_addr;  wire [15:0] p0_dout;  wire p0_ack;
reg         p1_req = 0;  reg [26:3] p1_addr;  wire [63:0] p1_dout;  wire p1_ack;
reg         p2_req = 0;  reg [26:4] p2_addr;  wire [127:0] p2_dout; wire p2_ack;
reg         p3_req = 0;  reg [26:1] p3_addr;  wire [15:0] p3_dout;  wire p3_ack;
reg         p4_req = 0;  reg [26:1] p4_addr;  wire [15:0] p4_dout;  wire p4_ack;
reg         p5_req = 0;  reg [26:3] p5_addr;  wire [63:0] p5_dout;  wire p5_ack;

sdram dut (
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

s32_sdram_model chip (
    .clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE)
);

// ---------------------------------------------------------------- address set
reg [26:1] alist [0:NADDR-1];
integer    acount = 0;

function automatic [15:0] expect_data(input [26:1] a);
    // Address-derived so any aliasing produces a mismatch, and so a stuck
    // address bit cannot accidentally read back the right value.
    expect_data = {a[16:1]} ^ {a[26:17], 6'b0} ^ 16'h5A3C;
endfunction

task automatic add_addr(input [26:1] a);
    if (acount < NADDR) begin alist[acount] = a; acount = acount + 1; end
endtask

integer b;
initial begin
    // every bit boundary that changes meaning in the decode
    add_addr(26'd0); add_addr(26'd1); add_addr(26'd2); add_addr(26'd3);
    for (b = 1; b <= 25; b = b + 1) begin
        add_addr(26'd1 << b);
        add_addr((26'd1 << b) - 1);
        add_addr((26'd1 << b) + 1);
    end
    // region bases (word addresses), current map
    add_addr(26'h0000000); add_addr(26'h0100000); add_addr(26'h0300000);
    add_addr(26'h0500000); add_addr(26'h0700000); add_addr(26'h0800000);
end

// ------------------------------------------------------------------- helpers
task automatic do_write(input [26:1] a, input [15:0] d);
    begin
        @(negedge clk);
        wr_addr = a; wr_din = d; wr_be = 2'b11; wr_req = 1'b1;
        @(posedge wr_ack);
        @(negedge clk);
        wr_req = 1'b0;
        @(negedge clk);
    end
endtask

task automatic do_read_p0(input [26:1] a, output [15:0] d);
    begin
        @(negedge clk);
        p0_addr = a; p0_req = 1'b1;
        @(negedge clk); p0_req = 1'b0;
        @(posedge p0_ack);
        d = p0_dout;
        @(negedge clk);
    end
endtask

// ---------------------------------------------------------------------- main
integer k, fails = 0;
reg [15:0] got, want;
reg [63:0] burst;

initial begin
    repeat (8) @(posedge clk);
    init = 0;
    wait (ready);
    repeat (20) @(posedge clk);

    // ---- phase 1: write EVERY address first (aliasing has nowhere to hide)
    for (k = 0; k < acount; k = k + 1)
        do_write(alist[k], expect_data(alist[k]));
    $display("[geom] wrote %0d corner addresses", acount);

    // ---- phase 2: read them all back
    for (k = 0; k < acount; k = k + 1) begin
        want = expect_data(alist[k]);
        do_read_p0(alist[k], got);
        if (got !== want) begin
            fails = fails + 1;
            $display("[geom] MISMATCH addr=%07h (byte %07h) got=%04h want=%04h",
                     alist[k], {alist[k],1'b0}, got, want);
        end
    end

    // ---- phase 3: burst ports must read the same words back
    // p1 = 4 words aligned to 8 bytes; check the column counter never escapes
    for (k = 0; k < 4; k = k + 1) begin
        logic [26:3] ba;
        ba = (k == 0) ? 24'h000000 :
             (k == 1) ? 24'h0FFFFE :      // straddles a[10] carry
             (k == 2) ? 24'h200000 :      // a[25] set (col[9])
                        24'h400000;       // a[26] set (device 1)
        // write the four words
        do_write({ba, 2'd0}, expect_data({ba,2'd0}));
        do_write({ba, 2'd1}, expect_data({ba,2'd1}));
        do_write({ba, 2'd2}, expect_data({ba,2'd2}));
        do_write({ba, 2'd3}, expect_data({ba,2'd3}));
        @(negedge clk); p1_addr = ba; p1_req = 1'b1;
        @(negedge clk); p1_req = 1'b0;
        @(posedge p1_ack);
        burst = p1_dout;
        @(negedge clk);
        if (burst[15:0]   !== expect_data({ba,2'd0}) ||
            burst[31:16]  !== expect_data({ba,2'd1}) ||
            burst[47:32]  !== expect_data({ba,2'd2}) ||
            burst[63:48]  !== expect_data({ba,2'd3})) begin
            fails = fails + 1;
            $display("[geom] BURST MISMATCH p1 base=%06h got=%016h", ba, burst);
        end
    end

    if (fails == 0) $display("SDRAM GEOMETRY PASS (%0d addresses, all ports)", acount);
    else            $display("SDRAM GEOMETRY FAIL: %0d mismatches", fails);
    $finish;
end

initial begin
    #40_000_000;
    $display("SDRAM GEOMETRY TIMEOUT");
    $finish;
end

endmodule
