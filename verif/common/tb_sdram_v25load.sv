// CONTROLLER byte-lane (DQM) test: byte-masked writes via wr_be=01/10 + p5
// read-back, against an ideal-DQM behavioural chip model.
//
// HISTORY NOTE — this is NOT the production MCU load path any more.  The
// loader was rewritten (2026-07-22) to pair stream bytes into ordinary
// be=11 full-word writes after the per-byte DQM-masked pattern this bench
// drives was observed corrupting scattered bytes of the MCU region on real
// hardware (a below-RTL DQM/board-level effect this ideal chip model cannot
// reproduce — this bench passed throughout).  Production-path coverage now
// lives in tb_loader_hpspace.  Kept as a controller-level byte-lane test.
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_v25load;

reg clk = 1'b0;
always #5 clk = ~clk;

reg init = 1'b1;
wire ready;

tri [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH;
wire SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

reg  [15:0] mem_dq = 16'h0000;
reg         mem_oe = 1'b0;
assign SDRAM_DQ = mem_oe ? mem_dq : 16'hzzzz;

reg        wr_req = 1'b0;
reg [26:1] wr_addr = '0;
reg [15:0] wr_din = '0;
reg [1:0]  wr_be = 2'b11;
wire       wr_ack;

// unused ports
reg p0_req=0,p1_req=0,p2_req=0,p3_req=0,p4_req=0;
reg [26:1] p0_addr=0,p3_addr=0,p4_addr=0; reg [26:3] p1_addr=0; reg [26:4] p2_addr=0;
wire [15:0] p0_dout,p3_dout,p4_dout; wire [63:0] p1_dout; wire [127:0] p2_dout;
wire p0_ack,p1_ack,p2_ack,p3_ack,p4_ack;

reg        p5_req = 1'b0;
reg [26:3] p5_addr = '0;
wire [63:0] p5_dout;
wire       p5_ack;

sdram dut (
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

// ------------------------------------------------------------------
// Behavioural SDR SDRAM storage model: real array, DQM-masked writes,
// CL2 reads.  Sampled on negedge like the proven tb_sdram read model.
// ------------------------------------------------------------------
localparam [2:0] C_ACT=3'b011, C_WRITE=3'b100, C_READ=3'b101;
// nCS is the DEVICE SELECT on the 128 MB module, not a command bit.
wire [2:0] cmd_bus = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
wire       chip_bus = SDRAM_nCS;

logic [15:0] store [longint];   // {chip, bank[1:0], row[12:0], col[9:0]} -> word
reg   [12:0] arow [0:1][0:3];
reg   [1:0]  rd_valid;
longint      rd_addr [0:1];

function automatic longint lin(input chip, input [1:0] bank, input [12:0] row, input [9:0] col);
    lin = {chip, bank, row, col};
endfunction

always @(negedge clk) begin
    if (cmd_bus == C_ACT) arow[chip_bus][SDRAM_BA] <= SDRAM_A[12:0];
    if (cmd_bus == C_WRITE) begin
        longint wa; logic [15:0] cur;
        wa  = lin(chip_bus, SDRAM_BA, arow[chip_bus][SDRAM_BA], {SDRAM_A[9], SDRAM_A[8:0]});
        cur = store.exists(wa) ? store[wa] : 16'h0000;
        // DQM is the shorted A[12:11] net on this module.
        if (!SDRAM_A[11]) cur[7:0]  = SDRAM_DQ[7:0];
        if (!SDRAM_A[12]) cur[15:8] = SDRAM_DQ[15:8];
        store[wa] = cur;
    end
    rd_valid[1] <= rd_valid[0];
    rd_valid[0] <= (cmd_bus == C_READ);
    rd_addr[1]  <= rd_addr[0];
    rd_addr[0]  <= lin(chip_bus, SDRAM_BA, arow[chip_bus][SDRAM_BA], {SDRAM_A[9], SDRAM_A[8:0]});
    mem_oe = rd_valid[1];
    if (rd_valid[1]) mem_dq = store.exists(rd_addr[1]) ? store[rd_addr[1]] : 16'h0000;
end

// ------------------------------------------------------------------
// SDR_MCU_BASE (word address).  Matches rtl/s32_pkg SDR_MCU_BASE=0x0E00000.
// ------------------------------------------------------------------
localparam [26:1] MCU_WBASE = 26'h0700000;  // SDR_MCU_BASE (0x0E00000) >> 1

task automatic wr_byte(input [26:1] waddr, input lane_hi, input [7:0] b);
    begin
        @(negedge clk);
        wr_addr = waddr; wr_din = {b, b}; wr_be = lane_hi ? 2'b10 : 2'b01; wr_req = 1'b1;
        @(negedge clk); wr_req = 1'b0;
        while (!wr_ack) @(posedge clk);
        while (wr_ack)  @(posedge clk);
    end
endtask

// Write a descrambled byte at MCU byte offset `off` (0..): word = base + off/2,
// lane = off&1 -- exactly what s32_rom_loader does for the MCU region.
task automatic mcu_wr(input [16:0] off, input [7:0] b);
    wr_byte(MCU_WBASE + off[16:1], off[0], b);
endtask

integer errors = 0;
task automatic p5_read_block(input [16:0] off, input [63:0] expw);
    integer t;
    begin
        @(negedge clk); p5_addr = MCU_WBASE[26:3] + off[16:3]; p5_req = 1'b1;
        @(negedge clk); p5_req = 1'b0;
        t = 0; while (!p5_ack && t < 200) begin @(posedge clk); #1; t = t + 1; end
        if (!p5_ack) begin $display("FAIL p5 read timeout off=%05x", off); errors = errors + 1; end
        else if (p5_dout !== expw) begin
            $display("FAIL off=%05x got=%016x exp=%016x", off, p5_dout, expw);
            errors = errors + 1;
        end
        while (p5_ack) @(posedge clk);
    end
endtask

// Expected descrambled byte value pattern (distinct, adjacent bytes differ).
function automatic [7:0] exp_byte(input [16:0] off); exp_byte = off[7:0] ^ 8'h5a; endfunction

integer i, blk, t2;
reg [63:0] eword;
localparam integer NBYTES = 2048;     // 256 p5 blocks
initial begin
    for (i=0;i<4;i=i+1) begin arow[0][i] = 13'd0; arow[1][i] = 13'd0; end
    rd_valid = 2'b00;
    repeat (4) @(posedge clk);
    @(negedge clk); init = 1'b0;
    t2 = 0; while (!ready && t2 < 70000) begin @(posedge clk); #1; t2 = t2 + 1; end
    if (!ready) $fatal(1, "SDRAM init timed out");

    // --- Test A: ascending byte writes (both lanes of each word consecutive) ---
    for (i = 0; i < NBYTES; i = i + 1) mcu_wr(i[16:0], exp_byte(i[16:0]));
    for (blk = 0; blk < NBYTES/8; blk = blk + 1) begin
        eword = { exp_byte(blk*8+7), exp_byte(blk*8+6), exp_byte(blk*8+5), exp_byte(blk*8+4),
                  exp_byte(blk*8+3), exp_byte(blk*8+2), exp_byte(blk*8+1), exp_byte(blk*8+0) };
        p5_read_block((blk*8), eword);
    end
    $display("Test A (ascending byte-lane writes): %0d errors", errors);

    // --- Test B: separated lanes (all low bytes, then all high) -> mimics the
    // real descrambled scatter where a word's two bytes are written far apart ---
    store.delete();
    for (i = 0; i < NBYTES; i = i + 2) mcu_wr(i[16:0],        exp_byte(i[16:0]));        // low bytes
    for (i = 1; i < NBYTES; i = i + 2) mcu_wr(i[16:0],        exp_byte(i[16:0]));        // high bytes later
    for (blk = 0; blk < NBYTES/8; blk = blk + 1) begin
        eword = { exp_byte(blk*8+7), exp_byte(blk*8+6), exp_byte(blk*8+5), exp_byte(blk*8+4),
                  exp_byte(blk*8+3), exp_byte(blk*8+2), exp_byte(blk*8+1), exp_byte(blk*8+0) };
        p5_read_block((blk*8), eword);
    end

    if (errors == 0) $display("SDRAM V25LOAD PASS");
    else             $display("SDRAM V25LOAD FAIL (%0d errors)", errors);
    $finish;
end

initial begin #20_000_000; $display("SDRAM V25LOAD FAIL (timeout)"); $finish; end

endmodule

`default_nettype wire
