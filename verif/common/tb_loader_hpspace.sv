// End-to-end HPS-pacing test of the MCU download path (V25 hypothesis H2):
//   hps_io-faithful ioctl driver -> s32_rom_loader (clk_sys)
//     -> sdram.sv (clk_ram, real controller incl. refresh)
//     -> DQM-masked behavioural SDRAM storage -> p5 read-back.
// The MiSTer HPS contract is: ioctl_wr is a one-clk_sys strobe per byte and the
// host never strobes while ioctl_wait is high; after wait falls the next strobe
// may come immediately.  This bench drives the WHOLE 64KB MCU region at the
// tightest contract-legal pacing (gap 0) plus the descriptor, then compares
// every byte of both destinations (SDRAM via p5 bursts, and the legacy BRAM
// observation port).  It also measures the longest ioctl_wait stall so the
// margin against the real SPI inter-byte gap can be judged, and finally
// documents the contract-violation case: one strobe issued during wait must be
// dropped by design (that byte, and only that byte, goes missing).
`timescale 1ns/1ps
`default_nettype none

module tb_loader_hpspace;

import s32_pkg::*;

// clk_ram ~100 MHz; clk_sys = clk_ram/2, edge-aligned (same-PLL model).
// INDEPENDENT aligned oscillators (edges in the same timestep), matching
// tb_core_v25sdram: a clk_sys derived from posedge clk_ram skews the domains
// by a delta cycle, giving the loader one clk_ram of early wr_ack/ready
// visibility silicon does not have and hiding races it does.
reg clk_ram = 1'b0;
always #5 clk_ram = ~clk_ram;
reg clk_sys = 1'b0;
always #10 clk_sys = ~clk_sys;

reg rst_n = 1'b0;   // models pll_locked

// ------------------------------------------------------------------
// DUT 1: loader (clk_sys)
// ------------------------------------------------------------------
reg         ioctl_download = 1'b0;
reg   [7:0] ioctl_index = 8'd0;
reg         ioctl_wr = 1'b0;
reg  [26:0] ioctl_addr = '0;
reg  [15:0] ioctl_dout = '0;
wire        ioctl_wait;
board_desc_t board_desc;
wire        sw_req;
wire [26:1] sw_addr;
wire [15:0] sw_din;
wire  [1:0] sw_be;
wire        sw_ack;
wire        v25_wr;
wire [15:0] v25_waddr;
wire  [7:0] v25_wdata;
wire        rom_loaded;

wire        sdram_ready;
reg         mem_ready_meta = 1'b0, mem_ready_sys = 1'b0;
always @(posedge clk_sys) begin
    if (!rst_n) begin mem_ready_meta <= 1'b0; mem_ready_sys <= 1'b0; end
    else begin mem_ready_meta <= sdram_ready; mem_ready_sys <= mem_ready_meta; end
end

s32_rom_loader loader (
    .clk(clk_sys), .rst(~rst_n),
    .mem_ready(mem_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .board_desc(board_desc),
    .sdr_wr_req(sw_req), .sdr_wr_addr(sw_addr), .sdr_wr_din(sw_din),
    .sdr_wr_be(sw_be), .sdr_wr_ack(sw_ack),
    .v25_wr(v25_wr), .v25_waddr(v25_waddr), .v25_wdata(v25_wdata),
    .eep_wr(), .eep_waddr(), .eep_wdata(),
    .eep_loaded(), .rom_loaded(rom_loaded)
);

// ------------------------------------------------------------------
// DUT 2: real SDRAM controller (clk_ram) + DQM-masked storage model
// (model identical to the proven tb_sdram_v25load one)
// ------------------------------------------------------------------
tri [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH;
wire SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;
reg  [15:0] mem_dq = 16'h0000;
reg         mem_oe = 1'b0;
assign SDRAM_DQ = mem_oe ? mem_dq : 16'hzzzz;

reg p0_req=0,p1_req=0,p2_req=0,p3_req=0,p4_req=0;
reg [26:1] p0_addr=0,p3_addr=0,p4_addr=0; reg [26:3] p1_addr=0; reg [26:4] p2_addr=0;
wire [15:0] p0_dout,p3_dout,p4_dout; wire [63:0] p1_dout; wire [127:0] p2_dout;
wire p0_ack,p1_ack,p2_ack,p3_ack,p4_ack;
reg         p5_req = 1'b0;
reg  [26:3] p5_addr = '0;
wire [63:0] p5_dout;
wire        p5_ack;

sdram sdr (
    .clk(clk_ram), .init(~rst_n), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din), .wr_be(sw_be), .wr_ack(sw_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

localparam [3:0] C_ACT=4'b0011, C_WRITE=4'b0100, C_READ=4'b0101;
wire [3:0] cmd_bus = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
logic [15:0] store [longint];
reg   [12:0] arow [0:3];
reg   [1:0]  rd_valid;
longint      rd_addr [0:1];
function automatic longint lin(input [1:0] bank, input [12:0] row, input [9:0] col);
    lin = {bank, row, col};
endfunction
always @(negedge clk_ram) begin
    if (cmd_bus == C_ACT) arow[SDRAM_BA] <= SDRAM_A[12:0];
    if (cmd_bus == C_WRITE) begin
        longint wa; logic [15:0] cur;
        wa  = lin(SDRAM_BA, arow[SDRAM_BA], SDRAM_A[9:0]);
        cur = store.exists(wa) ? store[wa] : 16'h0000;
        if (!SDRAM_DQML) cur[7:0]  = SDRAM_DQ[7:0];
        if (!SDRAM_DQMH) cur[15:8] = SDRAM_DQ[15:8];
        store[wa] = cur;
    end
    rd_valid[1] <= rd_valid[0];
    rd_valid[0] <= (cmd_bus == C_READ);
    rd_addr[1]  <= rd_addr[0];
    rd_addr[0]  <= lin(SDRAM_BA, arow[SDRAM_BA], SDRAM_A[9:0]);
    mem_oe = rd_valid[1];
    if (rd_valid[1]) mem_dq = store.exists(rd_addr[1]) ? store[rd_addr[1]] : 16'h0000;
end

// ------------------------------------------------------------------
// Reference data
// ------------------------------------------------------------------
localparam [26:0] OFF_MCU_TB = 27'h0E0_0040;   // == loader OFF_MCU
localparam [26:1] MCU_WBASE  = SDR_MCU_BASE[26:1]; // derived, not hard-coded

// Same permutation as the loader (kept literal so a loader typo cannot
// self-verify).
function automatic [15:0] tb_dst(input [15:0] i);
    tb_dst = { i[13], i[15], i[11], i[12], i[14], i[6], i[3], i[4],
               i[8],  i[2],  i[7],  i[10], i[9],  i[5], i[1], i[0] };
endfunction
function automatic [7:0] f(input [15:0] src);
    f = src[7:0] ^ src[15:8] ^ 8'hA5;
endfunction

reg [7:0] exp_img  [0:65535];   // expected descrambled image
reg [7:0] bram_img [0:65535];   // captured legacy BRAM port writes
reg [0:0] bram_hit [0:65535];
always @(posedge clk_sys)
    if (v25_wr) begin
        bram_img[v25_waddr] <= v25_wdata;
        bram_hit[v25_waddr] <= 1'b1;
    end

// ------------------------------------------------------------------
// hps_io-faithful driver (clk_sys).  gap = extra idle clk_sys between the
// wait release and the next strobe; 0 is the tightest legal pacing.
// ------------------------------------------------------------------
integer wait_stall_max = 0;
task automatic hps_byte(input [26:0] a, input [7:0] d, input integer gap);
    integer stall;
    begin
        stall = 0;
        @(negedge clk_sys);
        while (ioctl_wait) begin @(negedge clk_sys); stall = stall + 1; end
        if (stall > wait_stall_max) wait_stall_max = stall;
        repeat (gap) @(negedge clk_sys);
        ioctl_addr = a; ioctl_dout = d; ioctl_wr = 1'b1;
        @(negedge clk_sys);
        ioctl_wr = 1'b0;
    end
endtask

integer errors = 0;
task automatic p5_check(input [16:0] off);
    integer t, b;
    reg [63:0] expw;
    begin
        for (b = 0; b < 8; b = b + 1)
            expw[b*8 +: 8] = exp_img[{off[16:3], 3'b000} + b[16:0]];
        @(negedge clk_ram); p5_addr = MCU_WBASE[26:3] + off[16:3]; p5_req = 1'b1;
        @(negedge clk_ram); p5_req = 1'b0;
        t = 0; while (!p5_ack && t < 400) begin @(posedge clk_ram); #1; t = t + 1; end
        if (!p5_ack) begin
            $display("FAIL p5 timeout off=%05x", off); errors = errors + 1;
        end
        else if (p5_dout !== expw) begin
            $display("FAIL off=%05x got=%016x exp=%016x", off, p5_dout, expw);
            errors = errors + 1;
        end
        while (p5_ack) @(posedge clk_ram);
    end
endtask

integer i, t0, miss;
initial begin
    for (i = 0; i < 65536; i = i + 1) begin
        exp_img[tb_dst(i[15:0])] = f(i[15:0]);
        bram_hit[i] = 1'b0;
    end
    for (i = 0; i < 4; i = i + 1) arow[i] = 13'd0;
    rd_valid = 2'b00;
    repeat (8) @(posedge clk_ram);
    @(negedge clk_ram); rst_n = 1'b1;
    t0 = 0; while (!sdram_ready && t0 < 70000) begin @(posedge clk_ram); #1; t0 = t0 + 1; end
    if (!sdram_ready) $fatal(1, "SDRAM init timed out");
    repeat (8) @(negedge clk_sys);

    // ---- download: descriptor (ga2-style: has_v25, ga2 table, ppi) ----
    ioctl_download = 1'b1; ioctl_index = 8'd0;
    hps_byte(27'd0, 8'h22, 0);
    for (i = 1; i < 63; i = i + 1) hps_byte(i[26:0], (i == 3) ? 8'h83 : 8'h00, 0);
    hps_byte(27'd63, 8'h00, 0);

    // ---- the whole 64KB MCU region at the tightest legal pacing ----
    for (i = 0; i < 65536; i = i + 1)
        hps_byte(OFF_MCU_TB + i[26:0], f(i[15:0]), 0);

    @(negedge clk_sys);
    while (ioctl_wait) @(negedge clk_sys);
    ioctl_download = 1'b0;
    t0 = 0; while (!rom_loaded && t0 < 2000) begin @(posedge clk_sys); #1; t0 = t0 + 1; end
    if (!rom_loaded) begin $display("FAIL rom_loaded never rose"); errors = errors + 1; end
    if (board_desc.has_v25 !== 1'b1) begin
        $display("FAIL descriptor has_v25 not latched"); errors = errors + 1;
    end

    // ---- verify every byte, both destinations ----
    for (i = 0; i < 65536; i = i + 8) p5_check(i[16:0]);
    miss = 0;
    for (i = 0; i < 65536; i = i + 1) begin
        if (!bram_hit[i]) miss = miss + 1;
        else if (bram_img[i] !== exp_img[i]) miss = miss + 1;
    end
    if (miss != 0) begin
        $display("FAIL BRAM observation image: %0d bytes wrong/missing", miss);
        errors = errors + 1;
    end
    $display("HPSPACE max ioctl_wait stall seen: %0d clk_sys (%0d ns)",
             wait_stall_max, wait_stall_max * 20);

    // ---- documented contract violation: strobe during wait is dropped ----
    ioctl_download = 1'b1;
    hps_byte(OFF_MCU_TB, 8'h11, 0);            // legal write (asserts wait)
    @(negedge clk_sys);
    ioctl_addr = OFF_MCU_TB + 27'd1;           // illegal: wait is still high
    ioctl_dout = 8'h22; ioctl_wr = 1'b1;
    @(negedge clk_sys); ioctl_wr = 1'b0;
    @(negedge clk_sys);
    while (ioctl_wait) @(negedge clk_sys);
    ioctl_download = 1'b0;
    repeat (20) @(negedge clk_sys);
    if (bram_img[tb_dst(16'd1)] === 8'h22)
        $display("NOTE contract-violation byte was accepted (loader queued it)");
    else
        $display("NOTE contract-violation byte dropped as designed (HPS must honour ioctl_wait)");

    if (errors == 0) $display("LOADER HPSPACE PASS");
    else             $display("LOADER HPSPACE FAIL (%0d errors)", errors);
    $finish;
end

initial begin #120_000_000; $display("LOADER HPSPACE FAIL (timeout)"); $finish; end

endmodule

`default_nettype wire
