//============================================================================
//  Tier 8: ga2 (Golden Axe: Revenge of Death Adder) boot-path test.
//  Drives s32_core through the hardware sequence ga2's boot exercises:
//   1. V25 protection wakeup: byte reads at 0xA00000+ must return
//      "wake up! GOLDEN AXE..." from the HLE (board.has_v25, ga2 table)
//   2. tile name write to VRAM + palette write (bank 0)
//   3. sprite list: JUMP command then a draw entry, engine walks it
//   4. intc: vblank vector delivered, handler runs, writes magic, HALT
//  PASS requires all four observed.
//============================================================================
`timescale 1ns/1ps

module tb_core_ga2path;

import s32_pkg::*;

reg clk_sys = 0, clk_ram = 0, rst = 1;
always #10.35 clk_sys = ~clk_sys;
always #5.175 clk_ram = ~clk_ram;

reg ce_cpu = 0;
reg [1:0] cdiv = 0;
always @(posedge clk_sys) begin
    cdiv <= (cdiv == 2) ? 0 : cdiv + 1;
    ce_cpu <= (cdiv == 0);
end

board_desc_t board;
initial begin
    board = '0;
    board.has_v25 = 1'b1;    // ga2
    board.v25_table = 1'b0;  // ga2 opcode table
    board.has_ppi = 1'b1;    // 4-player board
end

// --- ROM model on SDRAM p0 (16KB window, mirrored) ---
// Same pattern as tb_core_boot: the icache fill FSM lives on clk_sys and
// pulses req for one clk_sys cycle per word, so ack must answer in the
// clk_sys domain (a single-cycle toggle == the real controller's 2-clk_ram
// stretched ack as seen from clk_sys).
reg [15:0] rom [0:8191];
wire        p0_req;
wire [26:1] p0_addr;
reg  [15:0] p0_dout;
reg         p0_ack = 0;
always @(posedge clk_sys) begin
    p0_ack  <= p0_req & ~p0_ack;
    p0_dout <= rom[p0_addr[13:1]];
end

// sprite ROM p2: return a fixed pattern
wire p2_req; reg p2_ack;
always @(posedge clk_ram) p2_ack <= p2_req;

wire fbw_start, fbw_valid, fbw_end, fbe_req, fbr_req;
wire [7:0] adc_a [0:7];
wire       tdv_a [0:2];
wire signed [8:0] tdx_a [0:2], tdy_a [0:2];
wire [7:0] tbt_a [0:2];
generate
    for (genvar gi = 0; gi < 8; gi = gi + 1) assign adc_a[gi] = 8'h80;
    for (genvar gj = 0; gj < 3; gj = gj + 1) begin
        assign tdv_a[gj] = 1'b0;
        assign tdx_a[gj] = 9'sd0;
        assign tdy_a[gj] = 9'sd0;
        assign tbt_a[gj] = 8'hff;
    end
endgenerate
reg  fbe_ack;
always @(posedge clk_ram) fbe_ack <= fbe_req;
integer spr_px_writes = 0;
always @(posedge clk_ram) if (fbw_valid) spr_px_writes = spr_px_writes + 1;

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram), .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(), .sdr_p1_addr(), .sdr_p1_dout(64'h0), .sdr_p1_ack(1'b1),
    .sdr_p2_req(p2_req), .sdr_p2_addr(), .sdr_p2_dout({8{16'h1111}}), .sdr_p2_ack(p2_ack),
    .sdr_p3_req(), .sdr_p3_addr(), .sdr_p3_dout(16'h0), .sdr_p3_ack(1'b0),
    .sdr_p4_req(), .sdr_p4_addr(), .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
    .sdr_p5_req(), .sdr_p5_addr(), .sdr_p5_dout(64'h0), .sdr_p5_ack(1'b0),
    .fb_wr_start(fbw_start), .fb_wr_buf(), .fb_wr_x(), .fb_wr_y(),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(), .fb_wr_end(fbw_end),
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
    .adc_ch(adc_a),
    .trk_dv(tdv_a), .trk_dx(tdx_a), .trk_dy(tdy_a),
    .trk_btn(tbt_a),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(), .rgb_b(), .ce_pix(), .hs(), .vs(), .hb(), .vb(),
    .audio_l(), .audio_r(), .out_lamps(),
    .debug_pc(), .debug_halted(), .debug_status(), .debug_first_rom(), .debug_hcnt()
);

// ---------------------------------------------------------------------
// program assembler helpers (same encodings as tb_core_boot)
// ---------------------------------------------------------------------
integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) rom[pc_a[31:1]][15:8] = b;
    else         rom[pc_a[31:1]][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
task movw_imm_reg(input [31:0] imm, input [4:0] rn);
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm);
endtask
task movw_reg_abs(input [4:0] rn, input [31:0] a);
    ab(8'h2D); ab(8'h00 | rn); ab(8'hF3); aw32(a);
endtask
// MOVB $abs32 -> Rn  (byte read from absolute address)
task movb_abs_reg(input [31:0] a, input [4:0] rn);
    ab(8'h09); ab(8'h20 | rn); ab(8'hF3); aw32(a);
endtask

integer i;
initial begin
    for (i = 0; i < 8192; i = i + 1) rom[i] = 16'h0000;

    // reset vector: JMP $000000 (mirror wrap puts 0xFFFFF0 at rom 0x3FF0)
    pc_a = 32'h3FF0;
    ab(8'hD6); ab(8'hF3); aw32(32'h0000_0000);

    pc_a = 0;
    movw_imm_reg(32'h0020_F000, 5'd31);           // SP
    // 1) V25 wakeup window is the byte range 0xA00100-0xA0015F (proven from
    // the real ga2 boot code; see docs/audit.md R3): first byte = 'w' (0x77)
    movb_abs_reg(32'h00A0_0100, 5'd6);
    // byte offset 0x22 within the string window -> word idx 17 = 'X'
    movb_abs_reg(32'h00A0_0122, 5'd7);
    // store to wram for checking
    movw_reg_abs(5'd6, 32'h0020_0010);
    movw_reg_abs(5'd7, 32'h0020_0012);
    // 2) VRAM tile name + palette
    movw_imm_reg(32'h0000_BEE5, 5'd0);
    movw_reg_abs(5'd0, 32'h0030_0040);
    movw_imm_reg(32'h0000_7C1F, 5'd1);
    movw_reg_abs(5'd1, 32'h0060_0002);
    // 3) sprite list: entry0 = JUMP to entry2 (cmd 2, target 2);
    //    entry2 = draw 8x8 -> writes pixels; entry3 = END
    //    jump word0: cmd=10 -> 0x8000 | target(2)
    movw_imm_reg(32'h0000_8002, 5'd2);
    movw_reg_abs(5'd2, 32'h0040_0000);            // sprite RAM word 0
    //    draw entry at idx2 (byte 0x20): word0=0 (draw), src 1x1, dst 8x8
    movw_imm_reg(32'h0000_0000, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_0020);            // cmd draw
    movw_imm_reg(32'h0000_0102, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_0022);            // srch=1, srcw=1 (4bpp: sw1[6:1])
    movw_imm_reg(32'h0000_0008, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_0024);            // dsth=8
    movw_reg_abs(5'd3, 32'h0040_0026);            // dstw=8
    movw_imm_reg(32'h0000_0050, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_0028);            // ypos
    movw_reg_abs(5'd3, 32'h0040_002A);            // xpos
    movw_imm_reg(32'h0000_0000, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_002C);            // addr
    movw_imm_reg(32'h0000_0010, 5'd3);
    movw_reg_abs(5'd3, 32'h0040_002E);            // palette
    //    end entry at idx3 (byte 0x30): cmd=11
    movw_imm_reg(32'h0000_C000, 5'd4);
    movw_reg_abs(5'd4, 32'h0040_0030);
    // enable sprite auto mode (ctl reg3=0)
    // 4) intc vector + unmask, then spin
    movw_imm_reg(32'h0000_0005, 5'd2);
    movw_reg_abs(5'd2, 32'h00D0_0000);
    movw_imm_reg(32'h0000_00FE, 5'd3);
    movw_reg_abs(5'd3, 32'h00D0_0006);   // mask = byte offset 6 (MAME decode)
    ab(8'h6A); ab(8'h00);                          // BR8 self-loop (disp 0)

    // vblank vector: intc delivers ctl[0]+0x40 = 0x45; table entry (SBR=0)
    // lives at 0x45*4 = 0x114 -> point it at the handler at 0x140.
    pc_a = 32'h114; aw32(32'h0000_0140);
    pc_a = 32'h140;
    movw_imm_reg(32'h0000_CAFE, 5'd4);
    movw_reg_abs(5'd4, 32'h0020_0100);            // wram magic
    ab(8'h00);                                     // HALT
end

`ifdef GA2DBG
// bus transaction trace: prot reads, wram writes, intc writes, IRQ vectoring
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.m_we && core.A[23:20]==4'hA)
        $display("[%0t] PROT RD  a=%06x be=%b d=%04x", $time, {core.A,1'b0}, core.m_be, core.m_rdata);
    if (core.m_req && core.m_ack && core.m_we && core.A[23:20]==4'h2)
        $display("[%0t] WRAM WR  a=%06x be=%b d=%04x", $time, {core.A,1'b0}, core.m_be, core.m_wdata);
    if (core.m_req && core.m_ack && core.m_we && core.A[23:20]==4'hD)
        $display("[%0t] INTC WR  a=%06x be=%b d=%04x", $time, {core.A,1'b0}, core.m_be, core.m_wdata);
end
reg [31:0] pc_last;
always @(posedge clk_sys) begin
    if (core.v60.dbg_pc != pc_last) begin
        if (core.v60.dbg_pc > 32'hFF && core.v60.dbg_pc < 32'h200)
            $display("[%0t] PC=%08x", $time, core.v60.dbg_pc);
        pc_last <= core.v60.dbg_pc;
    end
end
`endif

// force IE like the boot test (UPDPSW covered by directed tests)
initial begin
    repeat (20) @(posedge clk_sys);
    rst = 0;
    // wait until the main program reaches its spin loop, then poke IE once
    // (momentary force+release, as in tb_core_boot — a held force would keep
    // IE set through exception entry and cause an interrupt storm)
    repeat (60_000) @(posedge clk_sys);
    force core.v60.psw_rest = core.v60.psw_rest | 32'h0004_0000;
    release core.v60.psw_rest;
    // run up to 3 frames
    repeat (2_600_000) @(posedge clk_ram);
    $display("wake0=%02x wakeX=%02x vram=%04x pal=%04x wram_magic=%04x spr_px=%0d halted=%0d",
        core.work_ram.sim_peek(16'h0008) & 16'h00ff,
        core.work_ram.sim_peek(16'h0009) & 16'h00ff,
        core.vram.video_ram.sim_peek(16'h0020), core.pal0.sim_peek(14'h0001),
        core.work_ram.sim_peek(16'h0080), spr_px_writes, core.v60.dbg_halted);
    if ((core.work_ram.sim_peek(16'h0008) & 16'h00ff) == "w" &&
        (core.work_ram.sim_peek(16'h0009) & 16'h00ff) == "X" &&
        core.vram.video_ram.sim_peek(16'h0020) == 16'hBEE5 &&
        core.pal0.sim_peek(14'h0001) == 16'h7C1F &&
        core.work_ram.sim_peek(16'h0080) == 16'hCAFE &&
        spr_px_writes > 0 &&
        core.v60.dbg_halted)
        $display("GA2 PATH PASS");
    else
        $display("GA2 PATH FAIL");
    $finish;
end

endmodule
