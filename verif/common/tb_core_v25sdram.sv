//============================================================================
//  Real-V25 + REAL SDRAM CONTROLLER integration test (S32_REAL_V25).
//
//  tb_core_v25int proves the V25 inside s32_core against a *behavioural* p5
//  server; tb_loader_hpspace proves the loader + sdram.sv in isolation.  On
//  hardware the two meet: this bench closes that last gap by running the full
//  s32_core against the production rtl/mem/sdram.sv (clk_ram domain, real
//  round-robin arbitration with live V60 p0 traffic competing against the V25
//  p5 fetch) and a DQM-masked behavioural SDRAM chip model.  The V60 test
//  program and the genuine descrambled ga2 MCU image are preloaded through the
//  controller's own write port — the same port the ROM loader uses.
//
//  PASS = the V25 fetches through the real controller (p5 acks observed), the
//  firmware writes the wake bytes, and the polling V60 reads them and halts.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_core_v25sdram;

import s32_pkg::*;

// clk_ram ~96.6 MHz; clk_sys = clk_ram/2 and clk_v25 = clk_sys/2.  clk_sys and
// clk_ram are INDEPENDENT aligned oscillators (edges in the same timestep),
// exactly like tb_core_v25int: same-timestep NBA semantics model the silicon
// same-PLL aligned-edge behaviour (all FFs sample pre-edge values).  A derived
// clk_sys (toggled from posedge clk_ram) skews the domains by a delta cycle
// and manufactures req/ack races that silicon cannot produce.
// Integer half-periods (10ns/5ns) keep the exact 2:1 aligned relationship
// immune to timescale-precision rounding: fractional half-periods (#5.175)
// can round unevenly under a coarser global precision and silently break the
// alignment the same-PLL hardware guarantees.
reg clk_sys = 0, clk_ram = 0;
always #10 clk_sys = ~clk_sys;
always #5 clk_ram = ~clk_ram;
reg clk_v25 = 0;
always @(posedge clk_sys) clk_v25 <= ~clk_v25;

reg rst = 1;
reg init = 1;

reg ce_cpu = 0;
reg [1:0] cdiv = 0;
always @(posedge clk_sys) begin
    cdiv   <= (cdiv == 2) ? 0 : cdiv + 1;
    ce_cpu <= (cdiv == 0);
end

board_desc_t board;
initial begin
    board = '0;
    board.has_v25   = 1'b1;    // ga2: real V25 enabled
    board.v25_table = 1'b0;    // ga2 opcode-decryption table
    board.has_ppi   = 1'b1;    // 4-player board
end

// -------------------------------------------------------------------------
// Production SDRAM controller + DQM-masked chip model (as tb_loader_hpspace)
// -------------------------------------------------------------------------
tri [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0]  SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH;
wire SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;
reg  [15:0] mem_dq = 16'h0000;
reg         mem_oe = 1'b0;
assign SDRAM_DQ = mem_oe ? mem_dq : 16'hzzzz;

reg         wr_req = 1'b0;
reg  [26:1] wr_addr = '0;
reg  [15:0] wr_din = '0;
reg  [1:0]  wr_be = 2'b11;
wire        wr_ack;
wire        sdram_ready;

wire        p0_req, p1_req, p2_req, p3_req, p4_req, p5_req;
wire [26:1] p0_addr, p3_addr, p4_addr;
wire [26:3] p1_addr, p5_addr;
wire [26:4] p2_addr;
wire [15:0] p0_dout, p3_dout, p4_dout;
wire [63:0] p1_dout, p5_dout;
wire [127:0] p2_dout;
wire        p0_ack, p1_ack, p2_ack, p3_ack, p4_ack, p5_ack;

sdram sdr (
    .clk(clk_ram), .init(init), .ready(sdram_ready),
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

localparam [3:0] C_ACT=4'b0011, C_WRITE=4'b0100, C_READ=4'b0101;
wire [3:0] cmd_bus = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
reg [15:0] store [0:(1<<25)-1];   // {bank[1:0], row[12:0], col[9:0]} -> word
reg [12:0] arow [0:3];
reg [1:0]  rd_valid;
reg [24:0] rd_addr_p [0:1];
function automatic [24:0] lin(input [1:0] bank, input [12:0] row, input [9:0] col);
    lin = {bank, row, col};
endfunction
always @(negedge clk_ram) begin
    if (cmd_bus == C_ACT) arow[SDRAM_BA] <= SDRAM_A[12:0];
    if (cmd_bus == C_WRITE) begin
        reg [24:0] wa; reg [15:0] cur;
        wa  = lin(SDRAM_BA, arow[SDRAM_BA], SDRAM_A[9:0]);
        cur = store[wa];
        if (!SDRAM_DQML) cur[7:0]  = SDRAM_DQ[7:0];
        if (!SDRAM_DQMH) cur[15:8] = SDRAM_DQ[15:8];
        store[wa] = cur;
    end
    rd_valid[1]  <= rd_valid[0];
    rd_valid[0]  <= (cmd_bus == C_READ);
    rd_addr_p[1] <= rd_addr_p[0];
    rd_addr_p[0] <= lin(SDRAM_BA, arow[SDRAM_BA], SDRAM_A[9:0]);
    mem_oe = rd_valid[1];
    if (rd_valid[1]) mem_dq = store[rd_addr_p[1]];
end

// p5 activity counter (real controller acks)
integer p5_reads = 0;
integer p0_reads = 0;
reg p5_ack_d = 0, p0_ack_d = 0;
always @(posedge clk_ram) begin
    p5_ack_d <= p5_ack;
    p0_ack_d <= p0_ack;
    if (p5_ack && !p5_ack_d) p5_reads = p5_reads + 1;
    if (p0_ack && !p0_ack_d) p0_reads = p0_reads + 1;
end

// Port-level event trace: first N p0/p5 transactions after reset release
integer ev = 0;
reg p0_req_d = 0, p5_req_d = 0;
always @(posedge clk_ram) if (!rst && ev < 60) begin
    p0_req_d <= p0_req;
    p5_req_d <= p5_req;
    // (event counter retained for the request-drop regression check: the
    // pre-fix controller lost the V60's chained fill request and p0 froze at
    // one ack; the criteria below require the full boot to complete instead)
    if (p0_req && !p0_req_d) ev = ev + 1;
    if (p5_req && !p5_req_d) ev = ev + 1;
end

// -------------------------------------------------------------------------
// tie-offs identical to tb_core_v25int
// -------------------------------------------------------------------------
wire fbw_valid, fbe_req, fbr_req;
wire [7:0] adc_a [0:7];
wire       tdv_a [0:2];
wire signed [8:0] tdx_a [0:2], tdy_a [0:2];
wire [7:0] tbt_a [0:2];
generate
    for (genvar gi = 0; gi < 8; gi = gi + 1) assign adc_a[gi] = 8'h80;
    for (genvar gj = 0; gj < 3; gj = gj + 1) begin
        assign tdv_a[gj] = 1'b0; assign tdx_a[gj] = 9'sd0;
        assign tdy_a[gj] = 9'sd0; assign tbt_a[gj] = 8'hff;
    end
endgenerate
reg fbe_ack;
always @(posedge clk_ram) fbe_ack <= fbe_req;

wire dbg_halted_w;
wire [31:0] dbg_pc_w;
wire [23:0] dbg_v25_w;
wire [89:0] dbg_v25img_w;

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram), .clk_v25(clk_v25),
    .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(p1_req), .sdr_p1_addr(p1_addr), .sdr_p1_dout(p1_dout), .sdr_p1_ack(p1_ack),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr), .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_p3_req(p3_req), .sdr_p3_addr(p3_addr), .sdr_p3_dout(p3_dout), .sdr_p3_ack(p3_ack),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr), .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(), .fb_wr_buf(), .fb_wr_x(), .fb_wr_y(),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(), .fb_wr_end(),
    .fb_wr_shadow(), .fb_wr_busy(1'b0),
    .fb_er_req(fbe_req), .fb_er_buf(), .fb_er_y(), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(), .fb_rd_y(), .fb_rd_ack(1'b1),
    .fb_rd_x(), .fb_rd_pix(16'hffff),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
    .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0), .eep_rd_addr(6'h0),
    .eep_rd_data(), .eep_upload(1'b0), .eep_modified(),
    .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff),
    .in_svc12(8'hff), .in_svc34(8'hff),
    .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
    .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_a), .trk_dv(tdv_a), .trk_dx(tdx_a), .trk_dy(tdy_a), .trk_btn(tbt_a),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(), .rgb_b(), .ce_pix(), .hs(), .vs(), .hb(), .vb(),
    .audio_l(), .audio_r(), .out_lamps(),
    .debug_pc(dbg_pc_w), .debug_halted(dbg_halted_w), .debug_status(),
    .debug_first_rom(), .debug_hcnt(), .debug_v25(dbg_v25_w),
    .debug_v25_img(dbg_v25img_w)
);

// -------------------------------------------------------------------------
// V60 program assembler (identical to tb_core_v25int) -> staging array
// -------------------------------------------------------------------------
reg [15:0] rom [0:8191];
integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) rom[pc_a[31:1]][15:8] = b;
    else         rom[pc_a[31:1]][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w); ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); endtask
task movw_imm_reg(input [31:0] imm, input [4:0] rn); ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm); endtask
task movw_reg_abs(input [4:0] rn, input [31:0] a);   ab(8'h2D); ab(8'h00 | rn); ab(8'hF3); aw32(a); endtask
task movb_abs_reg(input [31:0] a, input [4:0] rn);   ab(8'h09); ab(8'h20 | rn); ab(8'hF3); aw32(a); endtask
task testb_abs(input [31:0] a); ab(8'hF0); ab(8'hF3); aw32(a); endtask
task be_poll_back6; ab(8'h64); ab(8'hFA); endtask

integer i;
initial begin
    for (i = 0; i < 8192; i = i + 1) rom[i] = 16'h0000;
    // The reset stub at byte 0xFFFF0 is preloaded separately below — the real
    // controller has no 16KB mirror, unlike tb_core_v25int's p0 model.
    pc_a = 0;
    movw_imm_reg(32'h0020_F000, 5'd31);          // SP
    testb_abs(32'h00A0_0100); be_poll_back6;     // wait for 'w'
    testb_abs(32'h00A0_0122); be_poll_back6;     // wait for later byte
    movb_abs_reg(32'h00A0_0100, 5'd6);
    movb_abs_reg(32'h00A0_0122, 5'd7);
    movw_reg_abs(5'd6, 32'h0020_0010);
    movw_reg_abs(5'd7, 32'h0020_0012);
    ab(8'h00);                                    // HALT
end

// Genuine ga2 MCU image, descrambled (identical to production loader)
reg [7:0] raw [0:65535];
reg [7:0] ext [0:65535];
function automatic [15:0] descramble(input [15:0] idx);
    descramble = {idx[14], idx[11], idx[15], idx[12], idx[13], idx[4], idx[3], idx[7],
                  idx[5], idx[10], idx[2], idx[8], idx[9], idx[6], idx[1], idx[0]};
endfunction
integer fd, got, src;
initial begin
    fd = $fopen("roms/sim/ga2/mcu.bin", "rb");
    if (fd == 0) begin $display("V25_SDRAM FAIL: cannot open roms/sim/ga2/mcu.bin"); $finish; end
    got = $fread(raw, fd); $fclose(fd);
    if (got != 65536) begin $display("V25_SDRAM FAIL: mcu.bin is %0d bytes", got); $finish; end
    for (src = 0; src < 65536; src = src + 1) ext[src] = raw[descramble(src[15:0])];
end

// -------------------------------------------------------------------------
// Preload through the controller's own write port (the loader's port)
// -------------------------------------------------------------------------
task automatic sdram_wr(input [26:1] a, input [15:0] d, input [1:0] be);
    begin
        @(negedge clk_ram);
        wr_addr = a; wr_din = d; wr_be = be; wr_req = 1'b1;
        @(negedge clk_ram); wr_req = 1'b0;
        while (!wr_ack) @(posedge clk_ram);
        while (wr_ack)  @(posedge clk_ram);
    end
endtask

localparam [26:1] MCU_WBASE = SDR_MCU_BASE[26:1];   // word address of 0x0E00000

integer w, t;
integer cyc = 0;
integer halt_cycle = -1;
reg dbg_v25img_fail = 0;
always @(posedge clk_sys) if (!rst) begin
    cyc <= cyc + 1;
    if (dbg_halted_w && halt_cycle < 0) halt_cycle <= cyc;
end

initial begin
    for (w = 0; w < (1<<25); w = w + 1) store[w] = 16'h0000;
    for (w = 0; w < 4; w = w + 1) arow[w] = 13'd0;
    rd_valid = 2'b00;
    repeat (8) @(posedge clk_ram);
    @(negedge clk_ram); init = 1'b0;
    t = 0; while (!sdram_ready && t < 70000) begin @(posedge clk_ram); #1; t = t + 1; end
    if (!sdram_ready) begin $display("V25_SDRAM FAIL: controller init timeout"); $finish; end

    // V60 program: 8192 words at maincpu base 0 (full-word writes)
    for (w = 0; w < 8192; w = w + 1)
        sdram_wr(w[23:0], rom[w], 2'b11);
    // V60 reset stub at its REAL address: byte 0xFFFF0 = JMP $000000
    // (D6 F3 00 00 00 00) -> words 0x7FFF8..0x7FFFA, little-endian.
    sdram_wr(24'h7FFF8, 16'hF3D6, 2'b11);
    sdram_wr(24'h7FFF9, 16'h0000, 2'b11);
    sdram_wr(24'h7FFFA, 16'h0000, 2'b11);
    // MCU image: descrambled bytes at SDR_MCU_BASE, per-lane like the loader
    for (w = 0; w < 65536; w = w + 2)
        sdram_wr(MCU_WBASE + w[26:1], {ext[w+1], ext[w]}, 2'b11);

    $display("V25_SDRAM preload done");
    repeat (8) @(negedge clk_sys);
    rst = 0;
    repeat (4_000_000) @(posedge clk_sys);
    $display("V25_SDRAM p5_reads=%0d p0_reads=%0d halted=%0d halt_cycle=%0d",
             p5_reads, p0_reads, dbg_halted_w, halt_cycle);
    $display("V25_SDRAM v60_pc=%08x v25dbg={ce=%0h wake=%b mbnz=%b unm=%b io=%b rdcnt=%02x mblast=%02x}",
             dbg_pc_w, dbg_v25_w[23:20], dbg_v25_w[19], dbg_v25_w[18],
             dbg_v25_w[17], dbg_v25_w[16], dbg_v25_w[15:8], dbg_v25_w[7:0]);
`ifndef S32_RELEASE_MINIMAL
    $display("V25_SDRAM sweep_done=%b hash=%06x (exp 83aa29) first_valid=%b first_line=%016x (exp ffffff0000040002)",
             dbg_v25img_w[89], dbg_v25img_w[87:64], dbg_v25img_w[88], dbg_v25img_w[63:0]);
    if (dbg_v25img_w[87:64] !== 24'h83AA29) begin
        $display("V25_SDRAM FAIL: image sweep hash mismatch");
        dbg_v25img_fail = 1;
    end
`else
    $display("V25_SDRAM release-minimal sweep_done=%b hash=%06x first_valid=%b first_line=%016x (exp ffffff0000040002)",
             dbg_v25img_w[89], dbg_v25img_w[87:64], dbg_v25img_w[88], dbg_v25img_w[63:0]);
    if (dbg_v25img_w[89] !== 1'b1 || dbg_v25img_w[87:64] !== 24'h000000) begin
        $display("V25_SDRAM FAIL: release-minimal sweep was not compiled out");
        dbg_v25img_fail = 1;
    end
`endif
    if (dbg_v25img_w[63:0] !== 64'hFFFF_FF00_0004_0002) begin
        $display("V25_SDRAM FAIL: first fetched line mismatch");
        dbg_v25img_fail = 1;
    end
    if (p5_reads > 0 && dbg_halted_w && halt_cycle > 2000 && !dbg_v25img_fail)
        $display("V25 SDRAM INTEGRATION PASS");
    else
        $display("V25 SDRAM INTEGRATION FAIL");
    $finish;
end

endmodule

`default_nettype wire
