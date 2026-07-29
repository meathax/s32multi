//============================================================================
//  Full-core integration boot test (DESIGN.md §11 integration tier).
//  Boots s32_core with a synthetic V60 program served from a behavioral
//  SDRAM model. The program (in "ROM"):
//    - sets SP
//    - writes a palette entry through 0x600000
//    - writes a VRAM word through 0x300000
//    - writes the vblank vector + unmask to the interrupt controller
//    - spins; the vblank IRQ handler writes a magic to work RAM and HALTs
//  Checks: palette/VRAM writes land, CRT generates vsync, vblank IRQ taken.
//============================================================================
`timescale 1ns/1ps

module tb_core_boot;

import s32_pkg::*;

reg clk_sys = 0, clk_ram = 0, rst = 1;
always #10.3 clk_sys = ~clk_sys;
always #5.15 clk_ram = ~clk_ram;

// clock enables: cpu = /3 of clk_sys
reg [1:0] div3 = 0;
reg ce_cpu = 0;
always @(posedge clk_sys) begin
    div3 <= (div3 == 2) ? 2'd0 : div3 + 1'd1;
    ce_cpu <= (div3 == 2);
end

board_desc_t board = '0;

// behavioral "SDRAM" program memory on p0
reg [15:0] rom [0:8191];   // 16KB of program
wire        p0_req;
wire [26:1] p0_addr;
reg  [15:0] p0_dout;
reg         p0_ack;
always @(posedge clk_sys) begin
    p0_ack <= p0_req & ~p0_ack;
    p0_dout <= rom[p0_addr[13:1]];
end

wire hs, vs, hb, vb, ce_pix;
wire [23:0] rgb_a, rgb_b;
wire [7:0] adcz [0:7];
for (genvar gi=0; gi<8; gi++) assign adcz[gi] = 8'h80;
wire tdv [0:2];
wire signed [8:0] tdx [0:2], tdy [0:2];
wire [7:0] tbn [0:2];
for (genvar gt=0; gt<3; gt++) begin
    assign tdv[gt] = 0; assign tdx[gt] = 0; assign tdy[gt] = 0;
    assign tbn[gt] = 8'hff;
end

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram), .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(), .sdr_p1_addr(), .sdr_p1_dout(64'h0), .sdr_p1_ack(1'b0),
    .sdr_p2_req(), .sdr_p2_addr(), .sdr_p2_dout(128'h0), .sdr_p2_ack(1'b0),
    .sdr_p3_req(), .sdr_p3_addr(), .sdr_p3_dout(16'h0), .sdr_p3_ack(1'b0),
    .sdr_p4_req(), .sdr_p4_addr(), .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
    .sdr_p5_req(), .sdr_p5_addr(), .sdr_p5_dout(64'h0), .sdr_p5_ack(1'b0),
    .fb_wr_start(), .fb_wr_buf(), .fb_wr_x(), .fb_wr_y(),
    .fb_wr_valid(), .fb_wr_pix(), .fb_wr_end(),
    .fb_wr_shadow(), .fb_wr_busy(1'b0),
    .fb_er_req(), .fb_er_buf(), .fb_er_y(), .fb_er_ack(1'b1),
    .fb_rd_req(), .fb_rd_buf(), .fb_rd_y(), .fb_rd_ack(1'b1),
    .fb_rd_x(), .fb_rd_pix(16'hffff),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
    .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0),
    .eep_rd_data(), .eep_rd_addr(6'h0), .eep_upload(1'b0), .eep_modified(),
    .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff),
    .in_svc12(8'hff), .in_svc34(8'hff),
    .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
    .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adcz),
    .trk_dv(tdv), .trk_dx(tdx), .trk_dy(tdy), .trk_btn(tbn),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(rgb_a), .rgb_b(rgb_b), .ce_pix(ce_pix),
    .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(), .audio_r(),
    .out_lamps()
);

// program assembly (mirrors tb_v60_directed helpers)
integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) rom[pc_a>>1][15:8] = b;
    else         rom[pc_a>>1][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
// MOVW #imm32, Rn
task movw_imm_reg(input [31:0] v, input [4:0] rn);
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(v);
endtask
// MOVW Rn, $addr (direct)
task movw_reg_abs(input [4:0] rn, input [31:0] a);
    ab(8'h2D); ab(8'h00 | rn); ab(8'hF3); aw32(a);
endtask

integer i;
integer vs_count = 0;
initial begin
    for (i = 0; i < 8192; i = i + 1) rom[i] = 16'h0000;
    pc_a = 0;

    // reset vector area: V60 starts at 0xFFFFF0 -> ROM mirror of 0xFFFFF0 =
    // maincpu offset 0x1FFFF0 — outside our 16KB model. For the test we set
    // START_PC via the ROM mirror decode: s32_core maps 0xF00000+ to
    // maincpu[0x0FFFFx]; our model wraps A[13:1], so 0xFFFFF0 lands at
    // rom[0x1FF8] — place a JMP $000000 there.
    pc_a = 32'h3FF0;                  // rom word 0x1FF8 = byte 0x3FF0
    ab(8'hD6); ab(8'hF3); aw32(32'h0000_0000);   // JMP direct $000000

    pc_a = 0;
    movw_imm_reg(32'h0020_F000, 5'd31);          // SP in work RAM
    movw_imm_reg(32'h0000_7FFF, 5'd0);
    movw_reg_abs(5'd0, 32'h0060_0000);           // palette[0] = 0x7FFF
    movw_imm_reg(32'h0000_1234, 5'd1);
    movw_reg_abs(5'd1, 32'h0030_0000);           // VRAM[0] = 0x1234
    // IO-7: write a byte to the s32comm share RAM (0x800000). The regular PCB
    // has S32COMM, so this must store as RAM (only D[7:0] is mapped).
    movw_imm_reg(32'h0000_005A, 5'd6);
    movw_reg_abs(5'd6, 32'h0080_0000);           // comm share RAM[0] = 0x5A
    // intc: vector for source0 (vblank) = 0x05 -> reg0 @0xD00000
    movw_imm_reg(32'h0000_0005, 5'd2);
    movw_reg_abs(5'd2, 32'h00D0_0000);
    // unmask: mask reg = byte offset 6 -> addr 0xD00006 (MAME int_control_w:
    // both byte lanes are registers; the word write also clears pending[7])
    movw_imm_reg(32'h0000_00FE, 5'd3);
    movw_reg_abs(5'd3, 32'h00D0_0006);
    // enable IE in PSW: UPDPSW is complex; instead poll with IE forced below.
    // spin: BR8 -2 (0x6A disp8=0xFE)
    ab(8'h6A); ab(8'hFE);

    // vblank handler at 0x100: write magic to work RAM 0x200100, HALT
    pc_a = 32'h100;
    movw_imm_reg(32'h0000_CAFE, 5'd4);
    movw_reg_abs(5'd4, 32'h0020_0100);
    ab(8'h00);                                    // HALT

    // vector table: SBR=0 -> vector 0x45 (0x40+5) at 0x114... collides with
    // handler; move handler: use vector value 0x05 -> table entry 0x45*4=0x114
    // Our handler starts at 0x100 and 0x114 falls inside it — instead point
    // table entry at 0x140 and place handler there.
    rom[(32'h114)>>1]     = 16'h0140;
    rom[((32'h114)>>1)+1] = 16'h0000;
    pc_a = 32'h140;
    movw_imm_reg(32'h0000_CAFE, 5'd4);
    movw_reg_abs(5'd4, 32'h0020_0100);
    ab(8'h00);

    // run
    repeat (10) @(posedge clk_sys);
    rst = 0;

    // wait until the spin loop is reached (palette + vram written)
    repeat (30000) @(posedge clk_sys);

    // force IE so the vblank IRQ is taken (program-level UPDPSW covered in
    // the directed CPU suite; this test targets the intc->CPU->handler path)
    force core.v60.psw_rest = core.v60.psw_rest | 32'h0004_0000;
    release core.v60.psw_rest;

    // let a few frames elapse
    repeat (900000) @(posedge clk_sys);

    $display("palette[0]=%04x vram[0]=%04x wram[0x80]=%04x comm[0]=%02x halted=%0d vs_count=%0d",
        core.pal0.sim_peek(14'h0000), core.vram.video_ram.sim_peek(16'h0000),
        core.work_ram.sim_peek(16'h0080), core.comm_peek(11'h000), core.v60.dbg_halted, vs_count);

    if (core.pal0.sim_peek(14'h0000) == 16'h7FFF &&
        core.vram.video_ram.sim_peek(16'h0000) == 16'h1234 &&
        core.work_ram.sim_peek(16'h0080) == 16'hCAFE &&
        core.comm_peek(11'h000) == 8'h5A &&
        vs_count >= 1)
        $display("CORE BOOT PASS");
    else
        $display("CORE BOOT FAIL");
    $finish;
end

// count vsyncs
reg vs_d;
always @(posedge clk_sys) begin
    vs_d <= vs;
    if (vs & ~vs_d) vs_count = vs_count + 1;
end

endmodule
