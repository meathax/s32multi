//============================================================================
//  Directed test: s32_mixer + s32_palette pixel pipeline
//  1. NBG0 pixel with pen 1, palette[1]=white -> rgb = F8F8F8 at that x
//  2. background elsewhere -> black (palette[0]=0)
//  3. blend: NBG0 over NBG1 with blendmask + factor -> exact MAME arithmetic
//  4. sprite shadow pen -> halves the layer beneath
//  5. synchronous line-RAM launch latency and parity-bank alignment
//  6. raw sprite group (not OR-adjusted effective group) controls blending
//  7. all four color-offset modes select bank 0/1/none correctly
//  8. backdrop static/line-color indices come from VRAM $1FF5E, not mixer $5E
//  9. offset-before-blend arithmetic and both palette operands are phase-safe
// 10. $1FF8E NBG pen-0 pixels are backdrop fallbacks, never normal-priority
// 11. production digital output order is offset -> blend -> shadow -> clamp,
//     followed by the 5-bit-to-8-bit output latch expansion
//============================================================================
`timescale 1ns/1ps

module tb_mixer;

reg clk_ram = 0;
always #5 clk_ram = ~clk_ram;
reg clk_sys = 0;
always @(posedge clk_ram) clk_sys = ~clk_sys;   // /2, edge-aligned

// palette
reg         cpu_we = 0;
reg  [14:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
wire [13:0] mix_addr;
wire [15:0] mix_data;

s32_palette pal (
    .clk(clk_sys), .mix_clk(clk_ram),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(2'b11), .cpu_rdata(), .mixer_r4e(16'h0000),
    .mix_addr(mix_addr), .mix_data(mix_data)
);

// mixer
reg         reg_we = 0;
reg  [5:0]  reg_addr = 0;
reg  [15:0] reg_wdata = 0;
reg   [1:0] reg_be = 2'b11;
reg  [8:0]  disp_x = 0, disp_y = 0;
reg         lb_we = 0;
reg  [2:0]  lb_layer = 0;
reg  [8:0]  lb_wx = 0;
reg  [13:0] lb_wpix = 0;
reg         lb_bank = 0;
reg  [15:0] spr_pix = 16'hffff;
reg  [15:0] bg_ctrl = 16'h0000;
reg   [5:0] layer_off = 6'b000000;
wire [23:0] rgb;
reg         rst = 1;
wire [13:0] px_text, px_nbg0, px_nbg1, px_nbg2, px_nbg3, px_bmp;

s32_linebuf lbuf (
    .clk(clk_ram),
    .lb_we(lb_we), .lb_layer(lb_layer), .lb_wx(lb_wx),
    .lb_wpix(lb_wpix), .lb_bank(lb_bank),
    .rd_x(disp_x), .rd_bank(disp_y[0]),
    .px_text(px_text), .px_nbg0(px_nbg0), .px_nbg1(px_nbg1),
    .px_nbg2(px_nbg2), .px_nbg3(px_nbg3), .px_bmp(px_bmp)
);

reg frame_latch = 1'b0;

s32_mixer mix (
    .clk(clk_ram), .rst(rst),
    .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_be(reg_be),
    .reg_rdata(), .reg_raddr(6'h0), .reg_r4e(),
    .disp_x(disp_x), .disp_y(disp_y), .disp_active(1'b1), .display_en(1'b1),
    .flip_y(1'b0), .frame_latch(frame_latch),
    .layer_off(layer_off), .bg_ctrl(bg_ctrl),
    .px_text(px_text), .px_nbg0(px_nbg0), .px_nbg1(px_nbg1),
    .px_nbg2(px_nbg2), .px_nbg3(px_nbg3), .px_bmp(px_bmp),
    .spr_pix(spr_pix),
    .pal_addr(mix_addr), .pal_data(mix_data),
    .rgb(rgb)
);

task wreg(input [5:0] a, input [15:0] d);
    @(posedge clk_ram); reg_we <= 1; reg_addr <= a; reg_wdata <= d;
    @(posedge clk_ram); reg_we <= 0;
endtask
// s32_mixer's color-offset select ($3E), per-layer offset flags and both
// offset banks are whole-frame quantities: the DUT only samples the live
// mreg values into coloroffs_bank0/1 (and the r3e_f/r4c15_f/
// layer_color_flags_f snapshot) on a frame_latch pulse at vblank -- and
// resets to 18'hFFFFF (i.e. -1 per 6-bit channel), not zero. Every directed
// wreg() to 0x1f/0x19/0x1a/0x20-0x25 in this file must be followed by a
// pulse here before the new values are visible to a pixel check.
task pulse_frame_latch;
    @(posedge clk_ram); frame_latch <= 1'b1;
    @(posedge clk_ram); frame_latch <= 1'b0;
endtask
task wreg_lanes(input [5:0] a, input [15:0] d, input [1:0] lanes);
    @(negedge clk_ram);
    reg_we = 1'b1; reg_addr = a; reg_wdata = d; reg_be = lanes;
    @(negedge clk_ram);
    reg_we = 1'b0; reg_be = 2'b11;
endtask
task wpal(input [14:0] a, input [15:0] d);
    @(posedge clk_sys); cpu_we <= 1; cpu_addr <= a; cpu_wdata <= d;
    @(posedge clk_sys); cpu_we <= 0;
endtask
task wlb(input [2:0] lay, input bank, input [8:0] x, input [13:0] pix);
    @(posedge clk_ram); lb_we <= 1; lb_layer <= lay; lb_bank <= bank;
                        lb_wx <= x; lb_wpix <= pix;
    @(posedge clk_ram); lb_we <= 0;
endtask

// step to pixel x and let the pipeline finish (via a dummy x first so the
// pipeline re-runs even when the same x is sampled twice in a row)
task px(input [8:0] x);
    @(posedge clk_ram); disp_x <= 9'd511;
    repeat (14) @(posedge clk_ram);
    disp_x <= x;
    repeat (14) @(posedge clk_ram);
endtask

`ifdef MIXDBG
always @(posedge clk_ram)
    if (mix.ph != 4'hF || mix.disp_x != mix.dx_d)
        $display("[%0t] x=%0d ph=%0d best=%02x sel=%0d addr=%04x pd=%04x fp=%04x rgb=%06x",
            $time, disp_x, mix.ph, mix.best, mix.bestsel, mix_addr, mix_data,
            mix.first_pal, rgb);
`endif

integer errors = 0;
task check(input [23:0] got, input [23:0] want, input [8:0] x);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL x=%0d rgb=%06x want=%06x first=%0d idx=%04x pal=%04x co=%0d r=%0d g=%0d b=%0d sum=%0d/%0d/%0d blend=%0d",
                 x, got, want, mix.bestsel_hold, mix.idx_winner,
                 mix.first_pal, mix.co1_hold,
                 mix.r1_pipe, mix.g1_pipe, mix.b1_pipe,
                 mix.rr_pipe, mix.gg_pipe, mix.bb_pipe, mix.blend_hold);
    end
endtask

initial begin
    repeat (4) @(posedge clk_ram);
    rst = 0;
    repeat (2) @(posedge clk_ram);

    // Mixer register writes must preserve disabled byte lanes.
    wreg_lanes(6'h3f, 16'h1234, 2'b11);
    wreg_lanes(6'h3f, 16'h00aa, 2'b01);
    wreg_lanes(6'h3f, 16'hbb00, 2'b10);
    if (mix.mreg[6'h3f] !== 16'hbbaa) begin
        $display("  FAIL mixer byte-enable merge: got %04x want bbaa", mix.mreg[6'h3f]);
        errors = errors + 1;
    end

    // palette: [0]=black [1]=white [2]=xBGR blue=8 [3]=mid grey
    // [0x21]=red-ish 15
    wpal(15'h0000, 16'h0000);
    wpal(15'h0001, 16'h7FFF);
    wpal(15'h0002, 16'h2000);          // B=8
    wpal(15'h0003, 16'h4210);          // B=G=R=16
    wpal(15'h0020, 16'h03E0);          // G=31 (opaque-zero fallback)
    wpal(15'h0021, 16'h000F);          // R=15 (pal idx 0x21)
    wpal(15'h0030, 16'h001F);          // R=31 (fallback-rank check)
    wpal(15'h0400, 16'h000F);          // static backdrop: R=15
    wpal(15'h0203, 16'h03E0);          // line backdrop: G=31

    // mixer: NBG0 prio F shift 0; NBG1 prio 7 shift 0; others explicitly
    // programmed low — the register file resets to 0xFFFF like MAME's
    // video_start memset, so a directed test must set every reg it relies on
    wreg(6'h11, 16'h000F);             // NBG0: reg 0x22
    wreg(6'h12, 16'h0007);             // NBG1: reg 0x24
    wreg(6'h16, 16'h0001);             // background reg 0x2C
    wreg(6'h10, 16'h0000);             // TEXT off (prio 0)
    wreg(6'h13, 16'h0000);             // NBG2 off
    wreg(6'h14, 16'h0000);             // NBG3 off
    wreg(6'h15, 16'h0000);             // BITMAP off
    wreg(6'h00, 16'h0000);             // sprite groups 0-15 prio 0
    wreg(6'h01, 16'h0000);
    wreg(6'h02, 16'h0000);
    wreg(6'h03, 16'h0000);
    wreg(6'h04, 16'h0000);
    wreg(6'h05, 16'h0000);
    wreg(6'h06, 16'h0000);
    wreg(6'h07, 16'h0000);
    wreg(6'h26, 16'h0000);             // 0x4C sprite group config
    wreg(6'h27, 16'h0000);             // 0x4E blend off
    wreg(6'h1f, 16'h0000);             // 0x3E color-offset select
    wreg(6'h19, 16'h0000);             // NBG0 blend reg
    wreg(6'h1a, 16'h0000);             // NBG1 blend reg
    wreg(6'h20, 16'h0000);             // 0x40-0x4A RGB offsets = 0
    wreg(6'h21, 16'h0000);
    wreg(6'h22, 16'h0000);
    wreg(6'h23, 16'h0000);
    wreg(6'h24, 16'h0000);
    wreg(6'h25, 16'h0000);
    pulse_frame_latch();
    wreg(6'h2f, 16'h0000);             // mixer $5E must not drive backdrop

    // line buffers (bank 0, line 0): NBG0 pen 1 at x=10; NBG1 pen 2 at x=10
    // and x=12; NBG0 pen 0x21 (pal 2, pen 1) at x=14
    wlb(3'd1, 1'b0, 9'd10, 14'h2001);
    wlb(3'd2, 1'b0, 9'd10, 14'h2002);
    wlb(3'd2, 1'b0, 9'd12, 14'h2002);
    wlb(3'd1, 1'b0, 9'd14, 14'h2021);
    // Same coordinate, different parity banks: catches a stale-bank or
    // one-pixel RAM-address alignment error after synchronous conversion.
    wlb(3'd1, 1'b0, 9'd20, 14'h2001);
    wlb(3'd1, 1'b1, 9'd20, 14'h2021);
    wlb(3'd1, 1'b0, 9'd22, 14'h2003);
    // Valid NBG pen 0 is produced only by $1FF8E[8+bg].  Keep two
    // differently coloured payloads to verify its special fallback order.
    wlb(3'd2, 1'b0, 9'd24, 14'h2020); // NBG1 fallback -> green
    wlb(3'd1, 1'b0, 9'd26, 14'h2030); // NBG0 fallback -> red
    wlb(3'd4, 1'b0, 9'd26, 14'h2020); // NBG3 fallback -> green
    wlb(3'd1, 1'b0, 9'd28, 14'h2001); // ordinary NBG0 -> white
    wlb(3'd2, 1'b0, 9'd28, 14'h2020); // NBG1 fallback -> green

    // A disp_x transition issues the RAM read first.  The timing-closed mixer
    // then snapshots candidates and resolves winner/partner/index on three
    // successive clocks before launching the first palette lookup.
    @(posedge clk_ram); disp_x <= 9'd511;
    repeat (14) @(posedge clk_ram);
    disp_x <= 9'd10;
    @(posedge clk_ram); #1;
    if (mix.pixel_changed !== 1'b1 || mix.ph !== 4'hf) begin
        errors = errors + 1;
        $display("  FAIL synchronous RAM launch strobe was not registered");
    end
    @(posedge clk_ram); #1;
    if (mix.winner_pending !== 1'b1 || mix.ph !== 4'hf) begin
        errors = errors + 1;
        $display("  FAIL candidate snapshot stage misaligned");
    end
    @(posedge clk_ram); #1;
    if (mix.second_pending !== 1'b1 || mix.ph !== 4'hf) begin
        errors = errors + 1;
        $display("  FAIL winner stage misaligned");
    end
    @(posedge clk_ram); #1;
    if (mix.second_pending !== 1'b0 || mix.context_pending !== 1'b1 ||
        mix.ph !== 4'hf || mix_addr !== 14'd1) begin
        errors = errors + 1;
        $display("  FAIL partner register stage misaligned: second=%b context=%b ph=%0d addr=%04x",
                 mix.second_pending, mix.context_pending, mix.ph, mix_addr);
    end
    @(posedge clk_ram); #1;
    if (mix.context_pending !== 1'b0 || mix.ph !== 4'd0 || mix_addr !== 14'd1) begin
        errors = errors + 1;
        $display("  FAIL partner/palette context stage misaligned: context=%b ph=%0d addr=%04x",
                 mix.context_pending, mix.ph, mix_addr);
    end
    @(posedge clk_ram); #1;
    if (mix.ph !== 4'd1 || mix_addr !== 14'd2) begin
        errors = errors + 1;
        $display("  FAIL runner palette launch misaligned: ph=%0d addr=%04x",
                 mix.ph, mix_addr);
    end
    repeat (7) @(posedge clk_ram); #1;
    check(rgb, 24'hFFFFFF, 9'd10);

    // --- 1: winner pixel ---
    px(9'd9);                          // background -> black
    check(rgb, 24'h000000, 9'd9);
    px(9'd10);                         // NBG0 pen1 -> white (31<<3 = F8)
    check(rgb, 24'hFFFFFF, 9'd10);
    px(9'd12);                         // NBG1 pen2 -> palette[2]=B=8 -> B 8<<3=40
    check(rgb, 24'h000042, 9'd12);
    px(9'd14);                         // NBG0 idx 0x21 -> R=15 -> 78,0,0
    check(rgb, 24'h7B0000, 9'd14);

    // --- backdrop source: VRAM $1FF5E, including the per-line low 9 bits ---
    bg_ctrl = 16'h0400;                // static palette index $0400
    px(9'd9);
    check(rgb, 24'h7B0000, 9'd9);
    bg_ctrl = 16'h8200;                // base $0200 + (0 + y)
    disp_y = 9'd3;
    px(9'd9);
    check(rgb, 24'h00FF00, 9'd9);       // palette[$0203]
    bg_ctrl = 16'h0000;
    disp_y = 9'd0;

    // --- $1FF8E opaque-zero ordering ---
    // MAME documents the hardware theory as pen 0 above backdrop but behind
    // every real pixel.  The line-buffer encoding makes valid && pen==0
    // unique to that path for NBG0-3.
    bg_ctrl = 16'h0400;                // red backdrop
    px(9'd24);
    check(rgb, 24'h00FF00, 9'd24);     // fallback beats backdrop -> green

    // Even the lowest-priority ordinary bitmap pixel must beat a fallback
    // from NBG1 configured at priority 7.
    wreg(6'h15, 16'h0001);
    wlb(3'd5, 1'b0, 9'd24, 14'h2002);
    px(9'd24);
    check(rgb, 24'h000042, 9'd24);     // bitmap blue, not fallback green
    wlb(3'd5, 1'b0, 9'd24, 14'h0000);
    wreg(6'h15, 16'h0000);

    // A lowest-priority sprite also beats the fallback.  Mixer mode 0 maps
    // raw group 0 to effective group 1.
    wreg(6'h01, 16'h0001);
    spr_pix = 16'h8001;
    px(9'd24);
    check(rgb, 24'hFFFFFF, 9'd24);
    spr_pix = 16'hffff;
    wreg(6'h01, 16'h0000);

    // Lowest-priority text and ordinary NBG pixels also beat the fallback.
    wreg(6'h10, 16'h0001);
    wlb(3'd0, 1'b0, 9'd24, 14'h2001);
    px(9'd24);
    check(rgb, 24'hFFFFFF, 9'd24);
    wlb(3'd0, 1'b0, 9'd24, 14'h0000);
    wreg(6'h10, 16'h0000);
    wreg(6'h11, 16'h0001);
    wlb(3'd1, 1'b0, 9'd24, 14'h2001);
    px(9'd24);
    check(rgb, 24'hFFFFFF, 9'd24);
    wlb(3'd1, 1'b0, 9'd24, 14'h0000);
    wreg(6'h11, 16'h000F);

    // Layer disable and mixer priority zero both suppress the fallback.
    layer_off[2] = 1'b1;
    px(9'd24);
    check(rgb, 24'h7B0000, 9'd24);     // backdrop red
    layer_off = 6'b000000;
    wreg(6'h12, 16'h0000);
    px(9'd24);
    check(rgb, 24'h7B0000, 9'd24);
    wreg(6'h12, 16'h0007);

    // Simultaneous fallbacks use the mixer's deterministic NBG tie-rank, not
    // their configured priorities: the chosen order resolves NBG0 above NBG3.
    wreg(6'h11, 16'h0001);
    wreg(6'h14, 16'h000F);
    px(9'd26);
    check(rgb, 24'hFF0000, 9'd26);
    wreg(6'h11, 16'h000F);
    wreg(6'h14, 16'h0000);

    // The fallback remains a real mixer candidate for blending.  A normal
    // winner sees it as the runner-up, and a fallback winner sees backdrop.
    wreg(6'h27, 16'h0B00);             // blend enable, factor 3
    wreg(6'h19, 16'h0100);             // NBG0 blends with NBG1
    px(9'd28);
    check(rgb, 24'h7BFF7B, 9'd28);     // white + green
    wreg(6'h19, 16'h0000);
    wreg(6'h1a, 16'h2000);             // NBG1 blends with background
    px(9'd24);
    check(rgb, 24'h397B00, 9'd24);     // green + red backdrop
    wreg(6'h1a, 16'h0000);
    wreg(6'h27, 16'h0000);
    bg_ctrl = 16'h0000;

    // --- 2: blend NBG0 (winner) with NBG1 at x=10 ---
    // enable: reg 0x4E bit11, factor 3; NBG0 blend reg 0x32 (word 0x19):
    // blendmask bit for NBG1 (laynum 2) = reg bit (6+2)=8
    wreg(6'h27, 16'h0B00);             // 0x4E: enable | factor 3
    wreg(6'h19, 16'h0100);             // NBG0 blendmask: NBG1
    px(9'd10);
    // white(31,31,31) * (7-3) + blue(0,0,8)... palette[2]=0x2000: B=8,G=0,R=0
    // r = (31*4 + 0*4)>>3 = 15 -> 78; g likewise 15 -> 78; b = (31*4+8*4)>>3=19 -> 98
    check(rgb, 24'h7B7B9C, 9'd10);
    wreg(6'h27, 16'h0000);             // blend off again
    wreg(6'h19, 16'h0000);

    // --- 3: sprite shadow pen halves what's underneath ---
    // 0x4C nibble 7: shift 11, mask F, or 0 -> sprpixmask 0x7ff, shadowpen 0x7fe
    // sprite group = (pix>>11)&F = 0 -> group reg 0 priority must be nonzero
    wreg(6'h26, 16'h0007);             // 0x4C = mode 7 (no RMW-shadow bit)
    wreg(6'h00, 16'h000F);             // sprite group 0 prio F
    spr_pix = 16'h07FE;                // shadow pen (transparent, shadows below)
    px(9'd10);                         // white halved: 31>>1=15 -> 78
    check(rgb, 24'h7B7B7B, 9'd10);
    spr_pix = 16'hffff;
    px(9'd10);                         // back to full white
    check(rgb, 24'hFFFFFF, 9'd10);

    // --- 4: opaque sprite wins over NBG0 ---
    // sprite pen 1 group 0: pix = 0x8001 -> masked pen 1 -> palette[1] white
    // group reg 0 palbase 0 shift 0 prio F (rank 7 beats NBG0 rank 5)
    spr_pix = 16'h8001;
    px(9'd10);
    check(rgb, 24'hFFFFFF, 9'd10);
    spr_pix = 16'hffff;

    // --- 5: blend mask uses raw sprite group, not effective register group ---
    // Mode 1: raw group 0 is OR-adjusted to effective group 2 for priority
    // and palette selection. MAME still tests sprite-blend bit 0. With a
    // half blend, white NBG0 over blue sprite produces 78/78/98.
    wreg(6'h26, 16'h0001);             // shift14 mask1, effective OR=2
    wreg(6'h02, 16'h0007);             // effective sprite group 2 priority 7
    wreg(6'h27, 16'h0B00);             // blend enable, factor 3
    wreg(6'h19, 16'h1000);             // NBG0 blends with sprite; code=raw group 0
    spr_pix = 16'h8002;                // raw group 0, palette[2] blue
    px(9'd10);
    check(rgb, 24'h7B7B9C, 9'd10);
    spr_pix = 16'hffff;
    wreg(6'h27, 16'h0000);
    wreg(6'h19, 16'h0000);

    // --- 6: line parity selects the matching synchronous RAM bank ---
    disp_y = 9'd0;
    px(9'd20);
    check(rgb, 24'hFFFFFF, 9'd20);     // even line -> bank 0, white
    disp_y = 9'd1;
    px(9'd20);
    check(rgb, 24'h7B0000, 9'd20);     // odd line -> bank 1, red
    disp_y = 9'd0;
    px(9'd20);
    check(rgb, 24'hFFFFFF, 9'd20);     // switch back without stale bank data

    // --- 7: color-offset mode/bank decode ---
    // Bank 0 offsets RGB=(+1,+2,+3); bank 1=(-1,-2,-3). Applied to
    // palette[3]=(16,16,16), the distinct outputs are bank0=88/90/98,
    // bank1=78/70/68, and bank2(no offset)=80/80/80.
    wreg(6'h20, 16'h0001);             // bank 0 R +1
    wreg(6'h21, 16'h0002);             // bank 0 G +2
    wreg(6'h22, 16'h0003);             // bank 0 B +3
    wreg(6'h23, 16'h003f);             // bank 1 R -1 (signed 6-bit)
    wreg(6'h24, 16'h003e);             // bank 1 G -2
    wreg(6'h25, 16'h003d);             // bank 1 B -3

    // mode 00 -> bank !layerflag
    wreg(6'h1f, 16'h0000); wreg(6'h19, 16'h0000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h7B736B, 9'd22);
    wreg(6'h19, 16'h4000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h8C949C, 9'd22);

    // mode 01 -> bank 2 (no offset), independent of layerflag
    wreg(6'h1f, 16'h0002); wreg(6'h19, 16'h0000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h848484, 9'd22);

    // mode 10 -> flag 0 selects bank 2; flag 1 selects bank 0
    wreg(6'h1f, 16'h8000); wreg(6'h19, 16'h0000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h848484, 9'd22);
    wreg(6'h19, 16'h4000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h8C949C, 9'd22);

    // --- 8: signed offsets occur before blending; second lookup is distinct ---
    // NBG0 white uses bank1 (-32) => -1/channel. NBG1 blue uses bank0
    // (+31) => (31,31,39). Factor 0 gives ((-1*7)+second)/8 = (3,3,4).
    // This also catches either palette-clock phase returning the first color
    // for both blend operands.
    wreg(6'h20, 16'h001f); wreg(6'h21, 16'h001f); wreg(6'h22, 16'h001f);
    wreg(6'h23, 16'h0020); wreg(6'h24, 16'h0020); wreg(6'h25, 16'h0020);
    wreg(6'h1f, 16'h0000);
    wreg(6'h19, 16'h0100);             // NBG0 flag0(bank1), blend NBG1
    wreg(6'h1a, 16'h4000);             // NBG1 flag1(bank0)
    pulse_frame_latch();
    wreg(6'h27, 16'h0800);             // blend enable, factor 0
    px(9'd10);
    check(rgb, 24'h181821, 9'd10);

    wreg(6'h20, 16'h0001); wreg(6'h21, 16'h0002); wreg(6'h22, 16'h0003);
    wreg(6'h23, 16'h003f); wreg(6'h24, 16'h003e); wreg(6'h25, 16'h003d);
    wreg(6'h27, 16'h0000); wreg(6'h1a, 16'h0000);

    // mode 11 -> bank !layerflag, like mode 00
    wreg(6'h1f, 16'h8002); wreg(6'h19, 16'h0000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h7B736B, 9'd22);
    wreg(6'h19, 16'h4000);
    pulse_frame_latch();
    px(9'd22); check(rgb, 24'h8C949C, 9'd22);

    // --- 10: positional-gun board mixer config (MAME segas32_v.cpp mixer dump:
    // 0x40=0x42=0x44=0xFFEB, 0x4E=0x0C00).  util::sext(0xFFEB,6) = -21 must
    // darken every channel with the upper write bits ignored, clamping at 0;
    // with blend factor 4 the offsets apply per-operand before the weighted
    // sum.  A sign-extension or clamp fault here is the "glowing" failure mode.
    wreg(6'h20, 16'hFFEB); wreg(6'h21, 16'hFFEB); wreg(6'h22, 16'hFFEB);
    wreg(6'h23, 16'h0000); wreg(6'h24, 16'h0000); wreg(6'h25, 16'h0000);
    wreg(6'h1f, 16'h0000);             // mode 00: bank = !layerflag
    pulse_frame_latch();
    wreg(6'h27, 16'h0000);             // blend off first
    wreg(6'h19, 16'h4000);             // NBG0 flag=1 -> bank 0 (-21)
    wreg(6'h1a, 16'h0000);
    pulse_frame_latch();               // mreg[0x19][14] feeds layer_color_flags
    px(9'd10);                          // white (31,31,31) - 21 = (10,10,10)
    check(rgb, 24'h525252, 9'd10);
    px(9'd22);                          // grey (16,16,16) - 21 clamps to 0
    check(rgb, 24'h000000, 9'd22);
    // Positional-gun board blend: 0x4E=0x0C00 (enable, factor 4). Winner NBG0 darkened by
    // bank 0; partner NBG1 (flag 0 -> bank 1 = zero offsets) stays white:
    // each channel = (10*3 + 31*5) >> 3 = 23 -> 0xB8.
    wpal(15'h0002, 16'h7FFF);
    wreg(6'h27, 16'h0C00);
    wreg(6'h19, 16'h4100);             // bank 0 + blendmask NBG1
    pulse_frame_latch();
    px(9'd10);
    check(rgb, 24'hBDBDBD, 9'd10);

    // --- 11: exact 315-5242-facing digital pipeline invariant ---
    // The same offset/blend result is 23. A shadow pen then shifts it to 11,
    // clamp5 retains 11, and the output latch expands 5'b01011 as 0x58.
    // Applying shadow before blend, or quantizing/clamping at either earlier
    // stage, produces a different value and must fail this fixture.
    wreg(6'h26, 16'h0007);
    wreg(6'h00, 16'h000F);
    spr_pix = 16'h07FE;
    px(9'd10);
    check(rgb, 24'h5A5A5A, 9'd10);
    spr_pix = 16'hffff;

    wreg(6'h27, 16'h0000);
    wreg(6'h19, 16'h0000);
    wreg(6'h20, 16'h0000); wreg(6'h21, 16'h0000); wreg(6'h22, 16'h0000);

    if (errors == 0) $display("MIXER PASS");
    else             $display("MIXER FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #200000;
    $display("MIXER FAIL (timeout)");
    $finish;
end

endmodule
