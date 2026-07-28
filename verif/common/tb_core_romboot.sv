//============================================================================
//  Real-ROM boot harness: runs an actual game image (built by
//  tools/make_sim_images.py) on s32_core with full-size memory models.
//
//  Plusargs:
//    +IMG=<dir>     image directory (maincpu.hex/soundcpu.hex/tiles.hex/
//                   sprites.hex expected inside)
//    +B0=<hex>      board descriptor byte 0 (flags), default 0
//    +B1=<hex>      board descriptor byte 1 (bit 1 = flip Y), default 0
//    +B2=<hex>      protection selector (1 = Sonic), default 0
//    +SBM=<hex>     physical sprite-ROM bank mask (0/1/3), default 3
//    +FRAMES=<n>    frames to run (804k clk_sys each), default 3
//    +COINAT=<n>     assert P1 coin active-low starting at harness frame n
//    +COINLEN=<n>    coin assertion length in frames, default 1
//    +STARTAT=<n>    assert P1 start active-low starting at harness frame n
//    +STARTLEN=<n>   start assertion length in frames, default 1
//    +P1AT<n>=<f>    start P1 digital event slot n (0..3) at frame f
//    +P1LEN<n>=<n>   event length in frames, default 1
//    +P1MASK<n>=<h>  P1A bits to pull low: L/R/U/D=80/40/20/10,
//                    B3/B2/B1 (Magic/Jump/Attack)=04/02/01
//
//  This is a diagnostic, not a pass/fail tier: it reports boot progress
//  (PC movement, RAM/VRAM/palette/sprite/io write counts, IRQs taken,
//  exceptions, framebuffer pixels) and flags a stuck PC.
//============================================================================
`timescale 1ns/1ps

module tb_core_romboot;

import s32_pkg::*;

reg clk_sys = 0, clk_ram = 0, rst = 1;
reg clk_v25 = 0;
always #10.35 clk_sys = ~clk_sys;
always #5.175 clk_ram = ~clk_ram;
always @(posedge clk_sys) clk_v25 <= ~clk_v25;

// clock enables
reg sim_multi32 = 0;
reg ce_cpu = 0;  reg [15:0] cpu_acc = 0;
always @(posedge clk_sys) begin
    logic [16:0] cpu_sum;
    if (rst) begin
        cpu_acc <= 16'd0;
        ce_cpu <= 1'b0;
    end else begin
        // 16.10795 MHz V60 or 20 MHz V70, matching the production NCO.
        cpu_sum = cpu_acc + (sim_multi32 ? 16'd27127 : 16'd21848);
        ce_cpu <= cpu_sum[16];
        cpu_acc <= cpu_sum[15:0];
    end
end
reg ce_z80 = 0;  reg [15:0] z80_acc = 0;
always @(posedge clk_sys) begin
    logic [16:0] z80_sum;
    if (rst) begin
        z80_acc <= 16'd0;
        ce_z80 <= 1'b0;
    end else begin
        // 8.053975 MHz System32 or 8 MHz Multi32.
        z80_sum = z80_acc + (sim_multi32 ? 16'd10851 : 16'd10924);
        ce_z80 <= z80_sum[16];
        z80_acc <= z80_sum[15:0];
    end
end
reg ce_fm = 0; reg [15:0] fm_acc = 0;
always @(posedge clk_sys) begin
    logic [16:0] fm_sum;
    // Mirror the production free-running FM NCO, including while rst is high.
    fm_sum = fm_acc + (sim_multi32 ? 16'd10851 : 16'd10924);
    ce_fm <= fm_sum[16];
    fm_acc <= fm_sum[15:0];
end
reg ce_pcm = 0;  reg [15:0] pcm_acc = 0;
always @(posedge clk_sys) begin
    logic [16:0] pcm_sum;
    if (rst) begin
        pcm_acc <= 16'd0;
        ce_pcm <= 1'b0;
    end
    else begin
        // 12.5 MHz System32 or 10 MHz Multi32, matching production.
        pcm_sum = pcm_acc + (sim_multi32 ? 16'd13564 : 16'd16955);
        ce_pcm <= pcm_sum[16];
        pcm_acc <= pcm_sum[15:0];
    end
end

// board descriptor from plusargs
board_desc_t board;
integer b0;
integer b1;
integer b2;
integer sbm;
initial begin
    if (!$value$plusargs("B0=%h", b0)) b0 = 0;
    if (!$value$plusargs("B1=%h", b1)) b1 = 0;
    if (!$value$plusargs("B2=%h", b2)) b2 = 0;
    if (!$value$plusargs("SBM=%h", sbm)) sbm = 3;
    sim_multi32 = b0[0];
    board = '0;
    board.multi32     = b0[0];
    board.has_v25     = b0[1];
    board.v25_table   = b0[2];
    board.has_adc     = b0[3];
    board.has_track   = b0[4];
    board.has_ppi     = b0[5];
    board.has_dsp_hle = b0[6];
    board.dual_pcb    = b1[0];
    board.flip_y      = b1[1];
    board.gun_aim     = b1[2];
    board.coin_swap   = b1[3];
    board.orunners    = b1[4];
    board.prot_sel    = b2[6:0];
    board.sprite_bank_valid = 1'b1;
    board.sprite_bank_mask  = sbm[1:0];
end

// +SCREENB selects the Multi 32 second monitor, exactly as the MiSTer top does
// with the OSD "Screen (Multi32)" option: the RGB source AND the single DDR
// line-fetch port move together.  Defaults to 0, so every existing
// single-screen run stays bit-identical.
reg screen_b = 1'b0;
initial screen_b = $test$plusargs("SCREENB");

// ---------------------------------------------------------------------------
// memory models (SDRAM layout per s32_pkg bases)
// ---------------------------------------------------------------------------
reg [15:0]  mc  [0:1048575];    // maincpu   base 0x000000, 2MB
reg [15:0]  sc  [0:2097151];    // soundcpu  base 0x200000, 4MB
reg [63:0]  tl  [0:524287];     // tiles     base 0x600000, 4MB
reg [127:0] sp  [0:1048575];    // sprites   base 0x1000000, 16MB
reg [7:0] mcu_raw [0:65535];
reg [7:0] mcu_ext [0:65535];
integer mcu_fd, mcu_got, mcu_i;

function automatic [15:0] mcu_descramble(input [15:0] i);
    mcu_descramble = {i[14], i[11], i[15], i[12], i[13], i[4], i[3], i[7],
                      i[5], i[10], i[2], i[8], i[9], i[6], i[1], i[0]};
endfunction

string imgdir;
initial begin
    if (!$value$plusargs("IMG=%s", imgdir)) imgdir = ".";
    $readmemh({imgdir, "/maincpu.hex"},  mc);
    $readmemh({imgdir, "/soundcpu.hex"}, sc);
    $readmemh({imgdir, "/tiles.hex"},    tl);
    $readmemh({imgdir, "/sprites.hex"},  sp);
    mcu_fd = $fopen({imgdir, "/mcu.bin"}, "rb");
    if (mcu_fd == 0) begin
        $display("ROMBOOT FAIL: cannot open %s/mcu.bin", imgdir);
        $finish;
    end else begin
        mcu_got = $fread(mcu_raw, mcu_fd);
        $fclose(mcu_fd);
        if (mcu_got != 65536) begin
            $display("ROMBOOT FAIL: mcu.bin is %0d bytes, expected 65536", mcu_got);
            $finish;
        end
        for (mcu_i = 0; mcu_i < 65536; mcu_i = mcu_i + 1)
            mcu_ext[mcu_i] = mcu_raw[mcu_descramble(mcu_i[15:0])];
    end
end

// p0: V60 program (clk_sys single-cycle toggle ack)
wire        p0_req;
wire [24:1] p0_addr;
reg  [15:0] p0_dout;
reg         p0_ack = 0;
always @(posedge clk_sys) begin
    p0_ack  <= p0_req & ~p0_ack;
    p0_dout <= mc[p0_addr[20:1]];
end

// p5: production real-V25 program path. The loader stores the descrambled
// 64 KiB MCU image at SDR_MCU_BASE and the core fetches aligned 8-byte lines.
localparam [21:0] MCU_BASE_W = SDR_MCU_BASE[24:3];
wire        p5_req;
wire [24:3] p5_addr;
reg  [63:0] p5_dout = 64'h0;
reg         p5_ack = 0;
reg         p5_pend = 0;
reg  [24:3] p5_addr_l = 0;
wire [12:0] p5_off = p5_addr_l[15:3] - MCU_BASE_W[12:0];
always @(posedge clk_sys) begin
    p5_ack <= 1'b0;
    if (rst) begin
        p5_pend <= 1'b0;
    end else begin
        if (p5_req && !p5_pend) begin
            p5_addr_l <= p5_addr;
            p5_pend <= 1'b1;
        end
        if (p5_pend) begin
            p5_dout <= {
                mcu_ext[{p5_off, 3'd7}], mcu_ext[{p5_off, 3'd6}],
                mcu_ext[{p5_off, 3'd5}], mcu_ext[{p5_off, 3'd4}],
                mcu_ext[{p5_off, 3'd3}], mcu_ext[{p5_off, 3'd2}],
                mcu_ext[{p5_off, 3'd1}], mcu_ext[{p5_off, 3'd0}]
            };
            p5_ack <= 1'b1;
            p5_pend <= 1'b0;
        end
    end
end

// p1: tile data, 64-bit (clk_ram)
wire        p1_req;
wire [24:3] p1_addr;
reg  [63:0] p1_dout;
reg         p1_ack = 0;
always @(posedge clk_ram) begin
    p1_ack  <= p1_req & ~p1_ack;
    p1_dout <= tl[p1_addr[21:3] - SDR_TILES_BASE[21:3]];
end

// p2: sprite data, 128-bit (clk_ram)
wire        p2_req;
wire [24:4] p2_addr;
reg [127:0] p2_dout;
reg         p2_ack = 0;
always @(posedge clk_ram) begin
    p2_ack  <= p2_req & ~p2_ack;
    p2_dout <= sp[p2_addr[23:4]];   // sprites base 0x1000000
end

// p3: Z80 program/banks (clk_sys)
wire        p3_req;
wire [24:1] p3_addr;
reg  [15:0] p3_dout;
reg         p3_ack = 0;
always @(posedge clk_sys) begin
    p3_ack  <= p3_req & ~p3_ack;
    p3_dout <= sc[p3_addr[21:1]];   // soundcpu base 0x200000
end

// Framebuffer service.  The broad regression keeps the compact behavioral
// memory; +define+S32_REAL_FB_SIM selects the production s32_fb_if plus a
// deterministic MiSTer-style DDR model for Golden Axe qualification.
wire        fbw_start, fbw_valid, fbw_end, fbe_req, fbr_req;
wire  [1:0] fbw_buf, fbe_buf, fbr_buf_core;
// Mirror the MiSTer top: Multi 32 keeps {monitor, front/back} in the four
// physical sprite buffers, and the single line-fetch port is steered at the
// board level to whichever monitor is being presented.
wire  [1:0] fbr_buf = (b0[0] && screen_b) ? {1'b1, fbr_buf_core[0]} : fbr_buf_core;
wire  [8:0] fbw_x, fbr_x;
wire  [7:0] fbw_y, fbe_y, fbr_y;
wire [15:0] fbw_pix;
wire        fbw_shadow;
wire        fbw_busy, fbe_ack, fbr_ack;
wire [15:0] fbr_pix;

integer fbr_accepts = 0;
reg [1:0] fbr_buf_l;
reg [7:0] fbr_y_l;
reg fbr_req_d = 0, fbr_ack_h_d = 0;
always @(posedge clk_ram) begin
    fbr_req_d   <= fbr_req;
    fbr_ack_h_d <= fbr_ack;
    if (fbr_req && !fbr_req_d) begin
        fbr_buf_l <= fbr_buf;
        fbr_y_l   <= fbr_y;
    end
    if (fbr_ack && !fbr_ack_h_d)
        fbr_accepts = fbr_accepts + 1;
end

`ifdef S32_REAL_FB_SIM
wire [31:0] fb_ddr_writes, fb_ddr_reads, fb_line_acks;
wire [31:0] fb_max_wr_wait, fb_max_rd_wait, fb_max_er_wait;
wire        fb_deadline_fail;

s32_fb_ddr_model fb_service (
    .clk(clk_ram), .rst(rst),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(fbr_req), .rd_buf(fbr_buf), .rd_y(fbr_y), .rd_ack(fbr_ack),
    .rd_x(fbr_x), .rd_pix(fbr_pix),
    .write_accepts(fb_ddr_writes), .read_accepts(fb_ddr_reads),
    .line_acks(fb_line_acks),
    .max_wr_wait(fb_max_wr_wait), .max_rd_wait(fb_max_rd_wait),
    .max_er_wait(fb_max_er_wait), .deadline_fail(fb_deadline_fail)
);
`else
// Fast behavioral model: 4 buffers x 256 lines x 512 pixels.
reg [15:0] fbmem [0:3][0:255][0:511];
initial for (int b = 0; b < 4; b++)
    for (int y = 0; y < 256; y++)
        for (int x = 0; x < 512; x++) fbmem[b][y][x] = 16'hffff;
reg fbe_ack_r = 0, fbr_ack_r = 0;
assign fbe_ack = fbe_ack_r;
assign fbr_ack = fbr_ack_r;
assign fbw_busy = 1'b0;
always @(posedge clk_ram) begin
    fbe_ack_r <= fbe_req;
    fbr_ack_r <= fbr_req && !fbr_ack_r;
    if (fbw_valid) begin
        if (fbw_shadow) fbmem[fbw_buf][fbw_y][fbw_x][15] <= 1'b0;
        else            fbmem[fbw_buf][fbw_y][fbw_x] <= fbw_pix;
    end
    if (fbe_req && !fbe_ack_r)
        for (int x = 0; x < 512; x++) fbmem[fbe_buf][fbe_y][x] = 16'hffff;
end
assign fbr_pix = fbmem[fbr_buf_l][fbr_y_l][fbr_x];
`endif
integer spr_px = 0;
always @(posedge clk_ram) if (fbw_valid) spr_px = spr_px + 1;
// Renderer liveness: accepted sprite-ROM bursts and valid draw commands.
// These are harness-only probes; scale_start is asserted once per decoded
// non-clip/non-end sprite command.
integer spr_cmd_cnt = 0, srom_req_cnt = 0;
reg [15:0] spr_jump_prev [0:1];
reg        spr_jump_seen [0:1];
initial begin
    spr_jump_seen[0] = 1'b0;
    spr_jump_seen[1] = 1'b0;
end
always @(posedge clk_ram) begin
    if (core.sprite.scale_start) spr_cmd_cnt = spr_cmd_cnt + 1;
    if (p2_req && !p2_ack)       srom_req_cnt = srom_req_cnt + 1;
    // Report a command-list jump only when it changes for that framebuffer
    // parity.  This keeps long real-ROM runs concise while exposing the exact
    // list target consumed after each sprite-update pulse.
    if (core.sprite.rs == core.sprite.R_DECODE &&
        core.sprite.sw[0][15:14] == 2'b10) begin
        if (!spr_jump_seen[core.sprite.disp_buf[0]] ||
            spr_jump_prev[core.sprite.disp_buf[0]] != core.sprite.sw[0]) begin
            $display("[spr-list] frame %0d buf=%0d jump@%04x word=%04x target=%04x",
                cur_frame, core.sprite.disp_buf[0], core.sprite.list_idx,
                core.sprite.sw[0], {3'b000, core.sprite.sw[0][12:0]});
            spr_jump_seen[core.sprite.disp_buf[0]] = 1'b1;
            spr_jump_prev[core.sprite.disp_buf[0]] = core.sprite.sw[0];
        end
    end
end

// Confirm that the CPU-side I/O transaction returned each active-low pulse.
// P1A is C00000; MAME system32_generic puts P1 coin/start on port E
// (C00008) bits 2/4.
integer p1a_rd_cnt = 0, coin_rd_cnt = 0, start_rd_cnt = 0;
integer p1a_active_samples = 0;
integer coin_active_samples = 0, start_active_samples = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.m_we && !core.ack_d) begin
        if ({core.A[23:1], 1'b0} == 24'hc00000) begin
            p1a_rd_cnt = p1a_rd_cnt + 1;
            if (core.m_rdata[7:0] != 8'hff) begin
                p1a_active_samples = p1a_active_samples + 1;
                $display("[input-sampled] frame %0d: P1A read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.dbg_pc);
            end
        end
        if ({core.A[23:1], 1'b0} == 24'hc00008) begin
            coin_rd_cnt = coin_rd_cnt + 1;
            start_rd_cnt = start_rd_cnt + 1;
            if (!core.m_rdata[2]) begin
                coin_active_samples = coin_active_samples + 1;
                $display("[input-sampled] frame %0d: P1 coin read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.dbg_pc);
            end
            if (!core.m_rdata[4]) begin
                start_active_samples = start_active_samples + 1;
                $display("[input-sampled] frame %0d: P1 start read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.dbg_pc);
            end
        end
    end
end

// input stubs
reg  [7:0] in_p1a_r = 8'hff;
reg  [7:0] in_portc_r = 8'hff;
reg  [7:0] in_svc12_r = 8'hff;
integer coin_at, coin_len, start_at, start_len;
integer p1_at [0:3];
integer p1_len [0:3];
integer p1_mask [0:3];
integer p1_event_count;
initial begin
    if (!$value$plusargs("COINAT=%d", coin_at)) coin_at = -1;
    if (!$value$plusargs("COINLEN=%d", coin_len)) coin_len = 1;
    if (!$value$plusargs("STARTAT=%d", start_at)) start_at = -1;
    if (!$value$plusargs("STARTLEN=%d", start_len)) start_len = 1;
    if (!$value$plusargs("P1AT0=%d", p1_at[0])) p1_at[0] = -1;
    if (!$value$plusargs("P1LEN0=%d", p1_len[0])) p1_len[0] = 1;
    if (!$value$plusargs("P1MASK0=%h", p1_mask[0])) p1_mask[0] = 0;
    if (!$value$plusargs("P1AT1=%d", p1_at[1])) p1_at[1] = -1;
    if (!$value$plusargs("P1LEN1=%d", p1_len[1])) p1_len[1] = 1;
    if (!$value$plusargs("P1MASK1=%h", p1_mask[1])) p1_mask[1] = 0;
    if (!$value$plusargs("P1AT2=%d", p1_at[2])) p1_at[2] = -1;
    if (!$value$plusargs("P1LEN2=%d", p1_len[2])) p1_len[2] = 1;
    if (!$value$plusargs("P1MASK2=%h", p1_mask[2])) p1_mask[2] = 0;
    if (!$value$plusargs("P1AT3=%d", p1_at[3])) p1_at[3] = -1;
    if (!$value$plusargs("P1LEN3=%d", p1_len[3])) p1_len[3] = 1;
    if (!$value$plusargs("P1MASK3=%h", p1_mask[3])) p1_mask[3] = 0;
    p1_event_count = (p1_at[0] >= 0) + (p1_at[1] >= 0) +
                     (p1_at[2] >= 0) + (p1_at[3] >= 0);
end
wire [7:0] adc_a [0:7];
wire       tdv_a [0:2];
wire signed [8:0] tdx_a [0:2], tdy_a [0:2];
wire [7:0] tbt_a [0:2];
generate
    for (genvar gi = 0; gi < 8; gi = gi + 1) begin : adc_defaults
        // MAME's OutRunners cabinet rests with both steering wheels centred
        // (ANALOG1/4 = 0x80) and all four pedals released (ANALOG2/3/7/8 =
        // 0x00).  Feeding 0x80 to every channel makes gas and brake appear
        // half pressed and does not represent either MAME or the MiSTer top.
        assign adc_a[gi] = board.orunners
                         ? ((gi == 0 || gi == 3) ? 8'h80 : 8'h00)
                         : 8'h80;
    end
    for (genvar gj = 0; gj < 3; gj = gj + 1) begin
        assign tdv_a[gj] = 1'b0;
        assign tdx_a[gj] = 9'sd0;
        assign tdy_a[gj] = 9'sd0;
        assign tbt_a[gj] = 8'hff;
    end
endgenerate

wire hs, vs, hb, vb;
wire [23:0] rgb_a, rgb_b;
wire [23:0] rgb_out = screen_b ? rgb_b : rgb_a;
wire        ce_pix;
wire signed [15:0] audio_l, audio_r;

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
`ifdef S32_REAL_V25
    .clk_v25(clk_v25),
`endif
    .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm), .pause(1'b0),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(p1_req), .sdr_p1_addr(p1_addr), .sdr_p1_dout(p1_dout), .sdr_p1_ack(p1_ack),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr), .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_p3_req(p3_req), .sdr_p3_addr(p3_addr), .sdr_p3_dout(p3_dout), .sdr_p3_ack(p3_ack),
    .sdr_p4_req(), .sdr_p4_addr(), .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_wr_busy(fbw_busy),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(fbr_buf_core), .fb_rd_y(fbr_y), .fb_rd_ack(fbr_ack),
    .fb_rd_x(fbr_x), .fb_rd_pix(fbr_pix),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
    .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0), .eep_rd_addr(6'h0),
    .eep_rd_data(), .eep_upload(1'b0), .eep_modified(),
    .in_p1a(in_p1a_r), .in_p2a(8'hff), .in_portc(in_portc_r),
    .in_svc12(in_svc12_r), .in_svc34(8'hff),
    .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
    .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_a),
    .trk_dv(tdv_a), .trk_dx(tdx_a), .trk_dy(tdy_a),
    .trk_btn(tbt_a),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(rgb_a), .rgb_b(rgb_b), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r), .out_lamps(),
    .debug_pc(), .debug_halted(), .debug_status(), .debug_first_rom(), .debug_hcnt()
);

// MAME's v60_device::device_start() gives R0..R30 a deterministic zero
// startup value (SP and the architectural reset registers are handled
// separately).  FPGA configuration also gives these flops a known power-up
// state, while a four-state RTL simulator otherwise leaves them as X because
// the CPU's architectural reset deliberately does not rewrite every GPR.
// Mirror the one-time device-start state here so real-ROM diagnostics do not
// poison game RAM when GA2 uses R26 as its startup zero register.
integer v60_start_i;
initial begin
    for (v60_start_i = 0; v60_start_i < 31; v60_start_i = v60_start_i + 1)
        core.v60.r[v60_start_i] = 32'h0000_0000;
end

// ---------------------------------------------------------------------------
// progress instrumentation
// ---------------------------------------------------------------------------
integer n_vram_wr = 0, n_pal_wr = 0, n_spr_wr = 0, n_io_wr = 0;
integer n_intc_wr = 0, n_wram_wr = 0, n_exc = 0, n_irq = 0;
integer n_pal_alias_lo = 0, n_pal_alias_hi = 0;
integer n_pal_bank_lo = 0, n_pal_bank_hi = 0;
integer vs_count = 0;
integer snd_rom_reqs = 0, snd_opcodes = 0;
integer snd_bank_lo = 0, snd_bank_hi = 0;
integer snd_fm1 = 0, snd_fm2 = 0, snd_rfreg = 0, snd_rfram = 0;
integer snd_irqctl = 0, snd_audio_x = 0;
reg snd_zrom_req_d = 0;
reg vs_d;
always @(posedge clk_sys) begin
    vs_d <= vs;
    if (vs & ~vs_d) vs_count = vs_count + 1;
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d) begin
        case (core.A[23:20])
            4'h2: n_wram_wr = n_wram_wr + 1;
            4'h3: n_vram_wr = n_vram_wr + 1;
            4'h4: n_spr_wr  = n_spr_wr + 1;
            4'h6: begin
                n_pal_wr = n_pal_wr + 1;
                // CPU byte A15 selects MAME's alternate-format alias while
                // A14 selects the physical 0x2000-word palette half. Keeping
                // both statistics separate lets real-ROM runs distinguish an
                // alias-conversion problem from a mixer bank-address problem.
                if (core.A[15]) n_pal_alias_hi = n_pal_alias_hi + 1;
                else            n_pal_alias_lo = n_pal_alias_lo + 1;
                if (core.A[14]) n_pal_bank_hi = n_pal_bank_hi + 1;
                else            n_pal_bank_lo = n_pal_bank_lo + 1;
            end
            4'hC: n_io_wr   = n_io_wr + 1;
            4'hD: n_intc_wr = n_intc_wr + 1;
            default: ;
        endcase
    end
    if (!rst) begin
        snd_zrom_req_d <= core.sound.zrom_req;
        if (core.sound.zrom_req && !snd_zrom_req_d) snd_rom_reqs = snd_rom_reqs + 1;
        if (!core.sound.z_m1_n && !core.sound.z_mreq_n) snd_opcodes = snd_opcodes + 1;
        if (core.sound.z_io_wr && core.sound.z_addr[7:4] == 4'ha) snd_bank_lo = snd_bank_lo + 1;
        if (core.sound.z_io_wr && core.sound.z_addr[7:4] == 4'hb) snd_bank_hi = snd_bank_hi + 1;
        if (core.sound.z_io_wr && core.sound.z_addr[7:4] == 4'h8) snd_fm1 = snd_fm1 + 1;
        if (core.sound.z_io_wr && core.sound.z_addr[7:4] == 4'h9) snd_fm2 = snd_fm2 + 1;
        if (core.sound.z_mem_wr && core.sound.pcm_cs && !core.sound.z_addr[12]) snd_rfreg = snd_rfreg + 1;
        if (core.sound.z_mem_wr && core.sound.pcm_cs &&  core.sound.z_addr[12]) snd_rfram = snd_rfram + 1;
        if (core.sound.z_io_wr && core.sound.z_addr[7:4] == 4'hd) snd_irqctl = snd_irqctl + 1;
        if (^{audio_l, audio_r} === 1'bx) snd_audio_x = snd_audio_x + 1;
    end
end

// exception / irq counters (state-entry edges).  Use the numeric S_EXC_PUSH1
// value (75) rather than the hierarchical enum-item ref 7'd75,
// which trips a Verilator EnumItemRef elaboration fault (works in ModelSim too).
localparam [6:0] S_EXC_PUSH1_V = 7'd75;   // == s32_v60 st_t S_EXC_PUSH1
reg exc_d, irq_d;
always @(posedge clk_sys) begin
    exc_d <= (core.v60.st == S_EXC_PUSH1_V);
    if ((core.v60.st == S_EXC_PUSH1_V) && !exc_d) begin
        if (core.v60.exc_vector >= 8'h40) n_irq = n_irq + 1;
        else n_exc = n_exc + 1;
    end
end

// stuck-PC watchdog (+ one-shot deep state dump on a long freeze)
reg [31:0] last_pc = 0;
integer same_pc = 0;
reg dumped = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.dbg_pc == last_pc) same_pc = same_pc + 1;
    else begin same_pc = 0; last_pc = core.v60.dbg_pc; end
    if (same_pc == 500000 && !dumped) begin
        dumped = 1;
        $display("[FROZEN] pc=%08x st=%0d cur_op=%02x subop=%02x cls=%0d",
            core.v60.dbg_pc, core.v60.st, core.v60.cur_op, core.v60.subop, core.v60.cls);
        $display("[FROZEN] str_cnt=%08x str_src=%08x str_dst=%08x bit_len=%08x",
            core.v60.str_cnt, core.v60.str_src, core.v60.str_dst, core.v60.bit_len);
        $display("[FROZEN] op1=%08x op2=%08x r0=%08x r1=%08x r3=%08x r26=%08x sp=%08x",
            core.v60.op1, core.v60.op2, core.v60.r[0], core.v60.r[1],
            core.v60.r[3], core.v60.r[26], core.v60.r[31]);
    end
end

// frame capture: with +DUMPAT=<frame#> (+DUMPN=<count>, default 1) write
// active-video pixels of those frames as PPM files (dump<frame>.ppm in cwd)
integer dump_at, dump_n, dump_fd = 0, dump_x, dump_y, dump_every;
reg dumping = 0;
initial begin
    if (!$value$plusargs("DUMPAT=%d", dump_at)) dump_at = -1;
    if (!$value$plusargs("DUMPN=%d", dump_n)) dump_n = 1;
    // +DUMPEVERY=<n>: dump every n-th frame (stride) — maps the attract cycle
    if (!$value$plusargs("DUMPEVERY=%d", dump_every)) dump_every = 1;
end

// +DUMPSPRAT=<frame>: dump the V60-written sprite command RAM (0x400000, the
// display list) to sim_spriteram.hex so it can be diffed against MAME's list.
integer sprdump_at, sprdump_fd, sprdump_i;
reg vb_d2 = 0, sprdump_done = 0;
integer sprdump_last = -1;
integer wdump_fd;
reg wdone250 = 0, wdone400 = 0, wdone500 = 0;
initial if (!$value$plusargs("DUMPSPRAT=%d", sprdump_at)) sprdump_at = -1;
integer sprdump_cur = 0;
always @(posedge clk_sys) begin
    if (vb & ~vb_d2) sprdump_cur = sprdump_cur + 1;
    vb_d2 <= vb;
    // Dump mid-visible-frame (vcnt~150), after the V60's vblank-IRQ handler has
    // finished rewriting the sprite list and the engine is rendering it — the
    // vblank-edge snapshot caught the list mid-rewrite (empty/partial).
    // consecutive-frame sprite-list capture: dump sprite RAM at sprdump_at,
    // +1, +2 to sim_spr_<frame>.hex so per-frame coordinate oscillation
    // ("sprites dancing back and forth") can be diffed.
    if (sprdump_at >= 0 && sprdump_cur >= sprdump_at && sprdump_cur <= sprdump_at+2
        && core.vcnt == 9'd150 && sprdump_last != sprdump_cur) begin
        sprdump_last = sprdump_cur;
        sprdump_fd = $fopen($sformatf("sim_spr_%0d.hex", sprdump_cur), "w");
        for (sprdump_i = 0; sprdump_i < 65536; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.sprite_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[sprdump] wrote sim_spr_%0d.hex", sprdump_cur);
    end
    if (sprdump_at >= 0 && sprdump_cur == sprdump_at && !sprdump_done
        && core.vcnt == 9'd150) begin
        sprdump_done = 1'b1;
        sprdump_fd = $fopen("sim_spriteram.hex", "w");
        for (sprdump_i = 0; sprdump_i < 65536; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.sprite_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[sprdump] wrote sim_spriteram.hex at frame %0d", sprdump_cur);
        // Also dump the full V60 work RAM (0x200000-0x20FFFF = 0x8000 words) so
        // the game/object state can be diffed vs MAME's ga2_wram_select520.hex.
        sprdump_fd = $fopen("sim_wram.hex", "w");
        for (sprdump_i = 0; sprdump_i < 16'h8000; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.work_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[wramdump] wrote sim_wram.hex at frame %0d", sprdump_cur);
        // Also dump the full tilemap VRAM (0x10000 words) so the NBG name
        // tables can be diffed against MAME's videoram at the same screen.
        sprdump_fd = $fopen("sim_vram.hex", "w");
        for (sprdump_i = 0; sprdump_i < 17'h10000; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.vram.video_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[vramdump] wrote sim_vram.hex at frame %0d", sprdump_cur);
        // Palette shadow (16384 entries) so sprite/tilemap palettes can be
        // diffed vs MAME paletteram (e.g. the ga2 PLAYER-SELECT text at 0x450).
        sprdump_fd = $fopen("sim_pal.hex", "w");
        for (sprdump_i = 0; sprdump_i < 16'h4000; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.pal0.sim_shadow[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[paldump] wrote sim_pal.hex at frame %0d", sprdump_cur);
    end
    // Multi-frame work-RAM snapshots to locate the FIRST frame of divergence vs
    // MAME (attract pre-coin @250, mid-sequence @400, just-entered-select @500).
    if (core.vcnt == 9'd150) begin
        if (sprdump_cur == 250 && !wdone250) begin
            wdone250 = 1'b1; wdump_fd = $fopen("sim_wram_250.hex","w");
            for (sprdump_i=0; sprdump_i<16'h8000; sprdump_i=sprdump_i+1)
                $fwrite(wdump_fd, "%04x\n", core.work_ram.mem[sprdump_i]);
            $fclose(wdump_fd); $display("[wramdump] sim_wram_250.hex");
        end
        if (sprdump_cur == 400 && !wdone400) begin
            wdone400 = 1'b1; wdump_fd = $fopen("sim_wram_400.hex","w");
            for (sprdump_i=0; sprdump_i<16'h8000; sprdump_i=sprdump_i+1)
                $fwrite(wdump_fd, "%04x\n", core.work_ram.mem[sprdump_i]);
            $fclose(wdump_fd); $display("[wramdump] sim_wram_400.hex");
        end
        if (sprdump_cur == 500 && !wdone500) begin
            wdone500 = 1'b1; wdump_fd = $fopen("sim_wram_500.hex","w");
            for (sprdump_i=0; sprdump_i<16'h8000; sprdump_i=sprdump_i+1)
                $fwrite(wdump_fd, "%04x\n", core.work_ram.mem[sprdump_i]);
            $fclose(wdump_fd); $display("[wramdump] sim_wram_500.hex");
        end
    end
end

// Monitor every V60 write to char-select object[8] (0x2005a0, wram_a 0x2d0-0x2d7)
// with the V60 PC + data. MAME spawns it at frame 436 via 0x063DB5 (word0=0x8000)
// and 0x063DBB (handler=0x64200, PC-relative). This shows whether our V60 reaches
// those spawn stores or diverges — and with what data (sim reads back 0x56e0/0x20).
integer obj8_fd = 0;
initial obj8_fd = $fopen("sim_obj8_writes.txt", "w");
always @(posedge clk_sys) begin
    if (core.m_req && core.m_we && core.sel_wram &&
        core.wram_a >= 16'h02d0 && core.wram_a <= 16'h02d7) begin
        $fwrite(obj8_fd, "frame=%0d pc=%08x wa=%04x data=%04x be=%b\n",
            sprdump_cur, core.v60.dbg_pc, core.wram_a, core.m_wdata, core.m_be);
        $fflush(obj8_fd);
    end
end

// +LOFF=<hex>: force tm_layer_off to isolate which layer draws the arabfgt
// select "swirl". bits {5:BITMAP,4:NBG3,3:NBG2,2:NBG1,1:NBG0,0:TEXT} (1=off).
integer loff_force;
always @(posedge clk_sys) if ($value$plusargs("LOFF=%h", loff_force))
    force core.tilemap.r1ff8e = {10'b0, loff_force[5:0]};

// +REGTRACE: log every CPU write to $1FF00 (word 0xff80) and $1FF02 (0xff81)
// with frame + value, to see if/when the game disables the bitmap (r1ff02[5]).
integer regtrace;
initial if (!$value$plusargs("REGTRACE=%d", regtrace)) regtrace = 0;
always @(posedge clk_ram) if (regtrace &&
        core.vram.cpu_we && (core.vram.cpu_addr == 16'hff80 || core.vram.cpu_addr == 16'hff81))
    $display("[regw] f=%0d addr=%04x data=%04x be=%b pc=%08x -> r1ff%02x",
        cur_frame, core.vram.cpu_addr, core.vram.cpu_wdata, core.vram.cpu_be,
        core.v60.dbg_pc,
        (core.vram.cpu_addr[0] ? 8'h02 : 8'h00));
reg vb_d, hb_d;
// +OVLOG=1: dump tilemap line-render overrun + sprite-fb underrun counters per frame
integer ovlog;
initial if (!$value$plusargs("OVLOG=%d", ovlog)) ovlog = 0;
// +SPRLOG=1: per-frame sprite-render telemetry (pixels written, FSM state at
// frame boundary = did the render finish?, and the displayed buffer). Diagnoses
// the arabfgt period-2 sprite flicker (render truncation / buffer divergence).
integer sprlog;
initial if (!$value$plusargs("SPRLOG=%d", sprlog)) sprlog = 0;
reg [31:0] spr_px_cnt, spr_px_latch;
reg [31:0] spr_draw_seen;            // fb_wr_start pulses this frame (# runs)
always @(posedge clk_ram) begin
    if (core.sprite.fb_wr_valid) spr_px_cnt <= spr_px_cnt + 1'd1;
    if (core.sprite.fb_wr_start) spr_draw_seen <= spr_draw_seen + 1'd1;
end
integer cur_frame = 0;
always @(posedge clk_sys) begin
    vb_d <= vb;
    if (vb & ~vb_d) begin              // end of visible field
        cur_frame = cur_frame + 1;
        // +OVLOG=1: per-frame tilemap line-overrun + sprite-fb underrun telemetry
        if (ovlog) $display("[ov] f=%0d tile_overrun sticky=%b cnt=%0d  fb_underrun sticky=%b cnt=%0d",
            cur_frame, core.tm_line_overrun_sticky, core.tm_line_overrun_count,
            core.fb_rd_underrun_sticky, core.fb_rd_underrun_count);
        // +SPRLOG: sprite render telemetry. rs = FSM state at frame boundary
        // (0=R_IDLE means render finished; 5..23 = still walking list = overran).
        if (sprlog) $display("[spr] f=%0d disp_buf=%0d rs=%0d px=%0d runs=%0d",
            cur_frame, core.sprite.disp_buf, core.sprite.rs, spr_px_cnt, spr_draw_seen);
        spr_px_latch <= spr_px_cnt;
        spr_px_cnt   <= 0;
        spr_draw_seen <= 0;
        if (dumping) begin
            // pad short frames so the PPM is always complete
            while (dump_y < 224) begin
                for (dump_x = 0; dump_x < 416; dump_x = dump_x + 1)
                    $fwrite(dump_fd, "0 0 0\n");
                dump_y = dump_y + 1;
            end
            $fclose(dump_fd);
            dumping = 0;
            $display("[dump] wrote frame %0d", cur_frame-1);
        end
        if (dump_at >= 0 && cur_frame >= dump_at &&
            ((cur_frame - dump_at) % dump_every == 0) &&
            ((cur_frame - dump_at) / dump_every < dump_n)) begin
            dump_fd = $fopen($sformatf("dump%0d.ppm", cur_frame), "w");
            // 52*8=416 wide, 224 high fixed header (PPM allows trailing slack)
            $fwrite(dump_fd, "P3\n416 224\n255\n");
            dumping = 1; dump_x = 0; dump_y = 0;
        end
    end
    hb_d <= hb;
    if (dumping && hb & ~hb_d && dump_x != 0) begin
        // pad/truncate each line to exactly 416 pixels
        while (dump_x < 416) begin
            $fwrite(dump_fd, "0 0 0\n");
            dump_x = dump_x + 1;
        end
        dump_x = 0;
        dump_y = dump_y + 1;
    end
    if (dumping && ce_pix && !hb && !vb && dump_y < 224) begin
        if (dump_x < 416) begin
            $fwrite(dump_fd, "%0d %0d %0d\n", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
            dump_x = dump_x + 1;
        end
    end
end

// instruction trace window (+TRLO/+TRHI plusargs): pc, opcode, key regs
integer tr_lo, tr_hi, tr_at, tr_n = 0;
initial begin
    if (!$value$plusargs("TRLO=%h", tr_lo)) tr_lo = -1;
    if (!$value$plusargs("TRHI=%h", tr_hi)) tr_hi = -1;
    if (!$value$plusargs("TRAT=%d", tr_at)) tr_at = 0;
end
always @(posedge clk_sys) if (ce_cpu) begin
    if (cur_frame >= tr_at && core.v60.st == 7'd3 && core.v60.pc >= tr_lo &&
        core.v60.pc < tr_hi && tr_n < 400) begin
        tr_n = tr_n + 1;
        $display("[tr] pc=%08x op=%02x r0=%08x r1=%08x r3=%08x r4=%08x r5=%08x r6=%08x z=%b",
            core.v60.pc, core.v60.opcode, core.v60.r[0], core.v60.r[1],
            core.v60.r[3], core.v60.r[4], core.v60.r[5], core.v60.r[6], core.v60.f_z);
    end
end

// GA2 object-list investigation trace.  Enable with +OBJTRAT=<frame> and
// optionally +OBJTRMAX=<n>.  It follows only the transition initializer
// (0x130600-0x130680) and object-list builder (0x132900-0x1329B0), recording
// the raw fetch bytes/registers at decode plus accepted non-ROM data cycles.
// This stays out of production RTL and is inert unless the plusarg is used.
integer obj_tr_at, obj_tr_max, obj_i_n = 0, obj_bus_n = 0;
initial begin
    if (!$value$plusargs("OBJTRAT=%d", obj_tr_at)) obj_tr_at = -1;
    if (!$value$plusargs("OBJTRMAX=%d", obj_tr_max)) obj_tr_max = 2000;
end
wire obj_pc_range = ((core.v60.pc >= 32'h00130600 && core.v60.pc < 32'h00130680) ||
                     (core.v60.pc >= 32'h00132900 && core.v60.pc < 32'h001329b0));
wire obj_dbgpc_range = ((core.v60.dbg_pc >= 32'h00130600 && core.v60.dbg_pc < 32'h00130680) ||
                        (core.v60.dbg_pc >= 32'h00132900 && core.v60.dbg_pc < 32'h001329b0));
always @(posedge clk_sys) if (ce_cpu) begin
    if (obj_tr_at >= 0 && cur_frame >= obj_tr_at && obj_pc_range &&
        core.v60.st == 7'd3 && obj_i_n < obj_tr_max) begin
        obj_i_n = obj_i_n + 1;
        $display("[obji] f=%0d pc=%08x b=%02x%02x%02x%02x%02x%02x%02x%02x r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x r7=%08x r8=%08x r9=%08x r10=%08x r11=%08x sp=%08x z=%b s=%b cy=%b",
            cur_frame, core.v60.pc,
            core.v60.fb[0], core.v60.fb[1], core.v60.fb[2], core.v60.fb[3],
            core.v60.fb[4], core.v60.fb[5], core.v60.fb[6], core.v60.fb[7],
            core.v60.r[0], core.v60.r[1], core.v60.r[2], core.v60.r[3],
            core.v60.r[4], core.v60.r[5], core.v60.r[6], core.v60.r[7],
            core.v60.r[8], core.v60.r[9], core.v60.r[10], core.v60.r[11],
            core.v60.r[31], core.v60.f_z, core.v60.f_s, core.v60.f_cy);
    end
end
always @(posedge clk_sys) begin
    if (obj_tr_at >= 0 && cur_frame >= obj_tr_at && obj_dbgpc_range &&
        core.m_req && core.m_ack && !core.ack_d &&
        core.A[23:20] >= 4'h2 && core.A[23:20] < 4'hf &&
        obj_bus_n < obj_tr_max) begin
        obj_bus_n = obj_bus_n + 1;
        if (core.m_we)
            $display("[objbus] f=%0d pc=%08x W [%06x] data=%04x be=%b",
                cur_frame, core.v60.dbg_pc, core.A[23:0], core.m_wdata, core.m_be);
        else
            $display("[objbus] f=%0d pc=%08x R [%06x] data=%04x be=%b",
                cur_frame, core.v60.dbg_pc, core.A[23:0], core.m_rdata, core.m_be);
    end
end

// io-chip write log + EEPROM pin trace (holo boot loop diagnosis)
integer io_log_n = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        core.A[23:16] == 8'hC0 && io_log_n < 120) begin
        io_log_n = io_log_n + 1;
        $display("[io] pc=%08x wr [%06x] = %04x be=%b",
            core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
    end
end
integer eep_log_n = 0, eep_skip;
reg [3:0] eep_prev = 0;
initial if (!$value$plusargs("EEPSKIP=%d", eep_skip)) eep_skip = 0;
always @(posedge clk_sys) begin
    if ({core.eeprom.cs, core.eeprom.sk, core.eeprom.di, core.eeprom.dout} != eep_prev) begin
        eep_log_n = eep_log_n + 1;
        if (eep_log_n >= eep_skip && eep_log_n < eep_skip + 30000)
            $display("[eep] cs=%b sk=%b di=%b do=%b es=%0d bitcnt=%0d",
                core.eeprom.cs, core.eeprom.sk, core.eeprom.di, core.eeprom.dout,
                core.eeprom.es, core.eeprom.bitcnt);
        eep_prev = {core.eeprom.cs, core.eeprom.sk, core.eeprom.di, core.eeprom.dout};
    end
end

// intc write log: what vectors/mask does the game program?
integer intc_log_n = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        core.A[23:16] == 8'hD0 && intc_log_n < 40) begin
        intc_log_n = intc_log_n + 1;
        $display("[intc] pc=%08x wr [%06x] = %04x be=%b",
            core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
    end
end

// log LDPR executions: which privileged register gets which value?
integer ldpr_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.st == 7'd10 && core.v60.cur_op == 8'h12 && ldpr_n < 16) begin
        ldpr_n = ldpr_n + 1;
        $display("[ldpr] pc=%08x op1=%08x op2=%08x", core.v60.dbg_pc, core.v60.op1, core.v60.op2);
    end
end

// privileged-register visibility: log every SBR change (LDPR target check)
reg [31:0] sbr_prev = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.sbr != sbr_prev) begin
        $display("[sbr] pc=%08x sbr %08x -> %08x", core.v60.dbg_pc, sbr_prev, core.v60.sbr);
        sbr_prev = core.v60.sbr;
    end
end

// IRQ/exception entry detail: vector, base register, stack, fetched handler
integer exc_log_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.st == 7'd79 && core.v60.bus_ack &&
        (exc_log_n < 12 || core.v60.exc_vector < 8'h40)) begin
        exc_log_n = exc_log_n + 1;
        $display("[exc] vec=%02x sbr=%08x sp=%08x retpc=%08x handler=[%08x]=%08x cur_op=%02x",
            core.v60.exc_vector, core.v60.sbr, core.v60.r[31], core.v60.exc_retpc,
            (core.v60.sbr & ~32'hfff) + {22'b0, core.v60.exc_vector, 2'b00},
            core.v60.bus_rdata, core.v60.cur_op);
    end
end

// derail trap: PC escaping the 24-bit bus space is always a wrong jump.
// Gate on !rst and on having booted into real code first: the V60 reset vector
// is 0xFFFFFFF0 (top byte 0xFF), which a 2-state simulator (Verilator) would
// otherwise flag as a derail during reset.  ModelSim's X-pessimism hid this.
reg derailed = 0;
reg booted = 0;
always @(posedge clk_sys) if (ce_cpu && !rst) begin
    if (core.v60.dbg_pc[31:24] == 8'h00) booted <= 1'b1;
    if (booted && !derailed && core.v60.dbg_pc[31:24] != 8'h00) begin
        derailed = 1;
        $display("[DERAIL] pc=%08x sp=%08x sbr=%08x psw=%08x", core.v60.dbg_pc,
            core.v60.r[31], core.v60.sbr, core.v60.psw);
        dump_trace;
        $display("ROMBOOT DONE");
        $finish;
    end
end

// jump trace: record discontinuous PC transitions (ring of 48)
reg [31:0] jt_from [0:47];
reg [31:0] jt_to   [0:47];
integer jt_n = 0;
reg [31:0] prev_pc = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.dbg_pc != prev_pc) begin
        if ((core.v60.dbg_pc > prev_pc + 24) || (core.v60.dbg_pc < prev_pc)) begin
            jt_from[jt_n % 48] <= prev_pc;
            jt_to[jt_n % 48]   <= core.v60.dbg_pc;
            jt_n = jt_n + 1;
        end
        prev_pc <= core.v60.dbg_pc;
    end
end

// watch one word address: log every write (who sets the polled flag?)
integer watch_a;
initial if (!$value$plusargs("WATCH=%h", watch_a)) watch_a = -1;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        {core.A[23:1],1'b0} == watch_a[23:0])
        $display("[watch] pc=%08x wr [%06x] = %04x be=%b",
            core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
end

// Optional write-range trace for semantic comparisons against MAME.  Frames
// are metadata only; compare the ordered PC/address/data/lane transactions.
integer trace_lo, trace_hi;
initial begin
    if (!$value$plusargs("TRACELO=%h", trace_lo)) trace_lo = -1;
    if (!$value$plusargs("TRACEHI=%h", trace_hi)) trace_hi = -1;
end
always @(posedge clk_sys) begin
    if (trace_lo >= 0 && trace_hi >= trace_lo &&
        core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        {core.A[23:1],1'b0} >= trace_lo[23:0] &&
        {core.A[23:1],1'b0} <= trace_hi[23:0]) begin
        $display("[memtrace] f=%0d pc=%08x a=%06x d=%04x be=%b op=%02x st=%0d",
            cur_frame, core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_wdata,
            core.m_be, core.v60.cur_op, core.v60.st);
    end
end

// ModelSim X-provenance aid for GA2's object-state setup.  The behavioural
// work RAM is zero-filled, so an unknown at these locations must have arrived
// on a CPU write.  Keep this diagnostic inert unless +XDIAG is requested.
integer xdiag_n = 0;
always @(posedge clk_sys) begin
    if ($test$plusargs("XDIAG") && core.m_req && core.m_ack && core.m_we &&
        !core.ack_d && ({core.A[23:1],1'b0} == 24'h20ad54 ||
                        {core.A[23:1],1'b0} == 24'h20ad56 ||
                        {core.A[23:1],1'b0} == 24'h20ac2c)) begin
        xdiag_n = xdiag_n + 1;
        $display("[xdiag] f=%0d pc=%08x W [%06x] data=%04x be=%b r0=%08x r1=%08x r26=%08x",
            cur_frame, core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_wdata,
            core.m_be, core.v60.r[0], core.v60.r[1], core.v60.r[26]);
    end
end

// +PALCMP: Multi 32 keeps a whole second 0x4000-entry palette RAM for screen B,
// which costs 32 M10Ks.  Sega gave each monitor its own so they *can* differ;
// whether a given twin-cabinet title ever makes them differ is an empirical
// question.  Sample both shadows every 10th frame and report the worst
// divergence seen, so a single-palette Multi 32 build can be justified or
// rejected on evidence rather than assumption.
`ifdef S32_TB_HAS_PAL1
integer palcmp_i, palcmp_diff, palcmp_worst = 0, palcmp_frames = 0;
reg palcmp_en = 1'b0, palcmp_vb_d = 1'b0;
integer palcmp_frame = 0;
initial palcmp_en = $test$plusargs("PALCMP");
always @(posedge clk_sys) begin
    palcmp_vb_d <= vb;
    if (palcmp_en && vb && !palcmp_vb_d) begin
        palcmp_frame = palcmp_frame + 1;
        if (palcmp_frame % 10 == 0) begin
            palcmp_diff = 0;
            for (palcmp_i = 0; palcmp_i < 16384; palcmp_i = palcmp_i + 1)
                if (core.pal0.sim_shadow[palcmp_i] !==
                    core.g_multi32_video.pal1.sim_shadow[palcmp_i])
                    palcmp_diff = palcmp_diff + 1;
            palcmp_frames = palcmp_frames + 1;
            if (palcmp_diff > palcmp_worst) palcmp_worst = palcmp_diff;
            $display("[palcmp] frame %0d: %0d/16384 entries differ (worst so far %0d)",
                palcmp_frame, palcmp_diff, palcmp_worst);
        end
    end
end
`endif

// bus-hang detector: a request that never acks is a core deadlock
integer hang_cnt = 0;
always @(posedge clk_sys) begin
    if (core.m_req && !core.m_ack) begin
        hang_cnt = hang_cnt + 1;
        if (hang_cnt == 20000)
// Profiles that select the MLAB ROM cache have no rom_filling / ic_hit nets:
// the cache keeps that state inside s32_ga_rom_cache.
`ifdef S32_GOLDENAXE_ONLY
 `define S32_TB_MLAB_ROM_CACHE 1
`endif
`ifdef S32_OUTRUNNERS_ONLY
 `define S32_TB_MLAB_ROM_CACHE 1
`endif
`ifdef S32_TB_MLAB_ROM_CACHE
            $display("[HANG] pc=%08x A=%06x we=%b be=%b st=%0d p0req=%b",
                core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_we, core.m_be,
                core.v60.st, p0_req);
`else
            $display("[HANG] pc=%08x A=%06x we=%b be=%b st=%0d rom_ready=%b rom_filling=%b ic_hit=%b p0req=%b",
                core.v60.dbg_pc, {core.A[23:1],1'b0}, core.m_we, core.m_be,
                core.v60.st, core.rom_ready, core.rom_filling, core.ic_hit, p0_req);
`endif
    end
    else hang_cnt = 0;
end

// region read counters (prot/shared visibility)
integer n_prot_rd = 0, n_sh_rd = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.m_we && !core.ack_d) begin
        if (core.A[23:20] == 4'hA) n_prot_rd = n_prot_rd + 1;
        if (core.A[23:20] == 4'h7) n_sh_rd = n_sh_rd + 1;
    end
end

// Optional CPU-side sprite-RAM write trace.  +SPRLOG=<n> enables at most n
// accepted writes; +SPRLOGAT=<frame> limits it to the state transition of
// interest.  Logging after m_ack proves both V60 execution and core address
// decode reached the physical sprite RAM write port.
integer spr_log_max, spr_log_at, spr_log_n = 0;
initial begin
    if (!$value$plusargs("SPRLOG=%d", spr_log_max)) spr_log_max = 0;
    if (!$value$plusargs("SPRLOGAT=%d", spr_log_at)) spr_log_at = 0;
end
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        core.A[23:17] == 7'b0100000 && cur_frame >= spr_log_at &&
        spr_log_n < spr_log_max) begin
        spr_log_n = spr_log_n + 1;
        $display("[sprw] f=%0d pc=%08x W [%06x] data=%04x be=%b r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x",
            cur_frame, core.v60.dbg_pc, core.A[23:0], core.m_wdata,
            core.m_be, core.v60.r[0], core.v60.r[1], core.v60.r[2],
            core.v60.r[3], core.v60.r[4], core.v60.r[5]);
    end
end

// Optional V25/MB8421 transaction trace.  +PROTLOG=<n> logs at most n
// accepted V60 accesses in 0xA00000-0xA00FFF; +PROTSKIP=<n> skips the first
// n accesses.  This is intentionally harness-only: it exposes whether the
// game merely reads the fixed bootstrap table, or later submits mailbox
// commands which require the real V25 to modify DPRAM asynchronously.
integer prot_log_max, prot_log_skip, prot_txn_n = 0, prot_log_n = 0;
initial begin
    if (!$value$plusargs("PROTLOG=%d", prot_log_max)) prot_log_max = 0;
    if (!$value$plusargs("PROTSKIP=%d", prot_log_skip)) prot_log_skip = 0;
end
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.ack_d &&
        core.A[23:12] == 12'hA00) begin
        if (prot_txn_n >= prot_log_skip && prot_log_n < prot_log_max) begin
            prot_log_n = prot_log_n + 1;
            if (core.m_we)
                $display("[prot] f=%0d n=%0d pc=%08x W [%06x] data=%04x be=%b",
                    cur_frame, prot_txn_n, core.v60.dbg_pc, core.A[23:0],
                    core.m_wdata, core.m_be);
            else
                $display("[prot] f=%0d n=%0d pc=%08x R [%06x] data=%04x be=%b",
                    cur_frame, prot_txn_n, core.v60.dbg_pc, core.A[23:0],
                    core.m_rdata, core.m_be);
        end
        prot_txn_n = prot_txn_n + 1;
    end
end

// non-ROM bus read log (ring of 24): what is the program polling?
reg [23:0] rd_a [0:23];
reg [15:0] rd_d [0:23];
reg [31:0] rd_pc [0:23];
integer rd_n = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.m_we && !core.ack_d &&
        core.A[23:20] >= 4'h2 && core.A[23:20] < 4'hF) begin
        rd_a[rd_n % 24]  <= core.A;
        rd_d[rd_n % 24]  <= core.m_rdata;
        rd_pc[rd_n % 24] <= core.v60.dbg_pc;
        rd_n = rd_n + 1;
    end
end

`ifdef FBDBG
// fetch-buffer inspection at a trouble PC
integer fbdbg_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h100551 && core.v60.st == 7'd3 && fbdbg_n < 4) begin
        fbdbg_n = fbdbg_n + 1;
        $display("[fbdbg] pc=%08x fb_base=%08x fb_valid=%0d fb=%02x %02x %02x %02x %02x %02x %02x %02x",
            core.v60.pc, core.v60.fb_base, core.v60.fb_valid,
            core.v60.fb[0], core.v60.fb[1], core.v60.fb[2], core.v60.fb[3],
            core.v60.fb[4], core.v60.fb[5], core.v60.fb[6], core.v60.fb[7]);
    end
    if (core.v60.pc == 32'h100551 && fbdbg_n == 1) begin
        $display("[cyc] st=%0d fb_base=%08x fb_valid=%0d fb3=%02x fb=%02x%02x%02x%02x%02x%02x%02x%02x ea_ofs=%0d ea_addr=%08x eamodm=%b mreg=%02x mtop=%0d fbatofs=%02x dim=%0d want=%b",
            core.v60.st, core.v60.fb_base, core.v60.fb_valid, core.v60.fb[3],
            core.v60.fb[0], core.v60.fb[1], core.v60.fb[2], core.v60.fb[3],
            core.v60.fb[4], core.v60.fb[5], core.v60.fb[6], core.v60.fb[7],
            core.v60.ea_ofs, core.v60.ea_addr, core.v60.ea_modm,
            core.v60.modreg, core.v60.modtop, core.v60.fb[core.v60.ea_ofs],
            core.v60.ea_dim, core.v60.ea_want_addr);
    end
    if (core.v60.pc == 32'h100551 && fbdbg_n > 0 && fbdbg_n < 3) begin
        if (core.v60.st == 7'd9)
            $display("[eadbg] EA_DONE tgt2=%b want=%b flag=%b ea_addr=%08x ea_out=%08x ea_len=%0d ret=%0d",
                core.v60.ea_target2, core.v60.ea_want_addr, core.v60.ea_flag,
                core.v60.ea_addr, core.v60.ea_out, core.v60.ea_len, core.v60.ea_ret);
        if (core.v60.st == 7'd10)
            $display("[eadbg] EXEC op=%02x op1=%08x op2=%08x flag1=%b flag2=%b",
                core.v60.cur_op, core.v60.op1, core.v60.op2, core.v60.flag1, core.v60.flag2);
        if (core.v60.st == 7'd14)
            $display("[eadbg] WB_MEM addr(op2)=%08x data(alu_r)=%08x", core.v60.op2, core.v60.alu_r);
    end
end
`endif

task dump_trace;
    integer k, idx;
    $display("--- last jumps (oldest first) ---");
    for (k = (jt_n > 48 ? jt_n - 48 : 0); k < jt_n; k = k + 1) begin
        idx = k % 48;
        $display("  %08x -> %08x", jt_from[idx], jt_to[idx]);
    end
    $display("--- last non-ROM reads (oldest first) ---");
    for (k = (rd_n > 24 ? rd_n - 24 : 0); k < rd_n; k = k + 1) begin
        idx = k % 24;
        $display("  pc=%08x rd [%06x] = %04x", rd_pc[idx], rd_a[idx], rd_d[idx]);
    end
endtask

// per-frame video liveness: nonblack pixels in the active window
integer nb_pix = 0;
always @(posedge clk_sys)
    if (ce_pix && !hb && !vb && rgb_out != 24'h0) nb_pix = nb_pix + 1;

// A compact whole-frame signature proves that active video remains known and
// continues changing after the game has accepted coin/start/player input.
reg [31:0] frame_sig = 32'h811c9dc5;
reg [31:0] prev_frame_sig = 0;
reg        frame_sig_seen = 0;
integer    frame_sig_samples = 0;
integer    frame_sig_changes = 0;
integer    frame_sig_x = 0;
always @(posedge clk_sys) begin
    if (rst) begin
        frame_sig <= 32'h811c9dc5;
        prev_frame_sig <= 0;
        frame_sig_seen <= 0;
        frame_sig_samples <= 0;
        frame_sig_changes <= 0;
        frame_sig_x <= 0;
    end
    else begin
        if (ce_pix && !hb && !vb)
            frame_sig <= {frame_sig[26:0], frame_sig[31:27]} ^
                         {8'h00, rgb_a} ^ {23'h0, core.hcnt[8:0]};
        if (vb && !vb_d) begin
            if (cur_frame >= 55) begin
                frame_sig_samples <= frame_sig_samples + 1;
                if (^frame_sig === 1'bx)
                    frame_sig_x <= frame_sig_x + 1;
                if (frame_sig_seen && frame_sig != prev_frame_sig)
                    frame_sig_changes <= frame_sig_changes + 1;
                prev_frame_sig <= frame_sig;
                frame_sig_seen <= 1'b1;
            end
            frame_sig <= 32'h811c9dc5 ^ cur_frame;
        end
    end
end
// prefetch/kick/mixer liveness
integer rdreq_cnt = 0, kick_cnt = 0, spr_opq_cnt = 0;
always @(posedge clk_sys) if (core.fb_rd_req) rdreq_cnt = rdreq_cnt + 1;
always @(posedge clk_ram) if (core.line_start_r) kick_cnt = kick_cnt + 1;
always @(posedge clk_sys) if (ce_pix && !hb && !vb && core.mix0.spr_opaque)
    spr_opq_cnt = spr_opq_cnt + 1;
// mixer register write log
integer mixw_n = 0;
always @(posedge clk_sys) begin
    if (core.mix0.reg_we && mixw_n < 80) begin
        mixw_n = mixw_n + 1;
        $display("[mixw] pc=%08x mreg[%02x] <= %04x (byte ofs %03x) busA=%06x",
            core.v60.dbg_pc, core.mix0.reg_addr, core.mix0.reg_wdata,
            {core.mix0.reg_addr, 1'b0}, {core.A[23:1],1'b0});
    end
end

// pixel-path trace at opaque sprite pixels (few per run)
integer pixlog_n = 0;
always @(posedge clk_sys) begin
    if (ce_pix && !hb && !vb && core.mix0.spr_opaque && cur_frame > 55 && pixlog_n < 10) begin
        pixlog_n = pixlog_n + 1;
        $display("[pix] f=%0d x=%0d y=%0d sprpix=%04x best=%0d idx=%04x palq=%04x rgb=%06x grp=%0d sprreg=%04x r4c=%04x",
            cur_frame, core.hcnt, core.vcnt, core.mix0.spr_pix,
            core.mix0.bestsel, core.mix0.pal_addr,
            core.pal0.sim_peek(core.mix0.pal_addr), rgb_a,
            core.mix0.spr_group, core.mix0.sprreg, core.mix0.r4c);
    end
end

integer frames, f, p1_ev;
reg playmagic = 0, playfight = 0;
initial begin
    if (!$value$plusargs("FRAMES=%d", frames)) frames = 3;
    playmagic = $test$plusargs("PLAYMAGIC");
    playfight = $test$plusargs("PLAYFIGHT");
    // Model the long board ROM-load reset: this fully flushes the production
    // jt12's 24-stage rings at its internally divided operator cadence.
    repeat (2048) @(posedge clk_sys);
    rst = 0;
    for (f = 0; f < frames; f = f + 1) begin
        in_p1a_r = 8'hff;
        in_portc_r = 8'hff;
        in_svc12_r = 8'hff;
        for (p1_ev = 0; p1_ev < 4; p1_ev = p1_ev + 1) begin
            if (p1_at[p1_ev] >= 0 && p1_len[p1_ev] > 0 &&
                f >= p1_at[p1_ev] && f < p1_at[p1_ev] + p1_len[p1_ev]) begin
                in_p1a_r = in_p1a_r & ~p1_mask[p1_ev][7:0];
                if (f == p1_at[p1_ev])
                    $display("[input] frames %0d..%0d: P1A mask %02x low",
                        p1_at[p1_ev], p1_at[p1_ev] + p1_len[p1_ev] - 1,
                        p1_mask[p1_ev][7:0]);
            end
        end
        if (coin_at >= 0 && coin_len > 0 &&
            f >= coin_at && f < coin_at + coin_len) begin
            in_svc12_r[2] = 1'b0;
            if (f == coin_at)
                $display("[input] frames %0d..%0d: P1 coin low (port E bit 2)",
                    coin_at, coin_at + coin_len - 1);
        end
        if (start_at >= 0 && start_len > 0 &&
            f >= start_at && f < start_at + start_len) begin
            in_svc12_r[4] = 1'b0;
            if (f == start_at)
                $display("[input] frames %0d..%0d: P1 start low (port E bit 4)",
                    start_at, start_at + start_len - 1);
        end
        // MAME's Sonic driver exposes the same coin/start actions on the
        // player-3 service bits used by its three-player join path.
        if (b2 == 1) begin
            in_svc12_r[6] = in_svc12_r[2];  // Coin 3
            in_svc12_r[7] = in_svc12_r[4];  // 3 Players Start
        end
        // +PLAYMAGIC gameplay autopilot: after coin+start, repeatedly tap
        // Button1 (0x01) to confirm the char select, then in gameplay hold Right
        // (0x40) toward the scripted rocks-flame and run a magic (Button3 0x04)
        // charge/release duty cycle to cast the fire spell. Both are the flame
        // triggers the user reports killing all sprites (#3).
        if (playmagic || playfight) begin
            // Char-select confirm (user tip): tap START + ATTACK a few times, then
            // STOP and let the select screen TIME OUT into the level. Taps at
            // 470/510/550/590, then quiet 600..660 so the timeout fires.
            if (f >= 470 && f < 600 && (f % 40) < 6) begin
                in_p1a_r[0]  = 1'b0;   // Button1 (attack)
                in_svc12_r[4] = 1'b0;  // Start
            end
            // gameplay: hold Right from 680 (advance toward enemies / rocks)
            if (f >= 680) in_p1a_r[6] = 1'b0;                            // Right
        end
        if (playmagic) begin
            // magic charge(45)/release(20) cycle from 700 -> casts fire on release
            if (f >= 700 && ((f - 700) % 65) < 45) in_p1a_r[2] = 1'b0;   // Button3
        end
        if (playfight) begin
            // #2 enemy-AI observation: NO magic (so enemies survive to be seen);
            // tap Attack (Button1) every 25 frames during gameplay to engage them
            if (f >= 700 && (f % 25) < 5) in_p1a_r[0] = 1'b0;           // Button1 attack
        end
        repeat (804000) @(posedge clk_sys);
        $display("frame %0d: pc=%08x halted=%0d | wram=%0d vram=%0d pal=%0d spr=%0d io=%0d intc=%0d | irq=%0d exc=%0d vs=%0d sprpx=%0d stuck=%0d protrd=%0d shrd=%0d den=%b nb=%0d v02=%04x v8e=%04x v00=%04x loff=%b",
            f, core.v60.dbg_pc, core.v60.dbg_halted,
            n_wram_wr, n_vram_wr, n_pal_wr, n_spr_wr, n_io_wr, n_intc_wr,
            n_irq, n_exc, vs_count, spr_px, same_pc, n_prot_rd, n_sh_rd,
            core.io0_cnt1, nb_pix,
            core.r1ff02, core.tilemap.r1ff8e, core.r1ff00, core.tilemap.layer_off);
        $display("   mix: txt=%04x n0=%04x bg=%04x spr0=%04x pxt=%04x den=%b | wbuf=%0d rbuf=%0d disp=%0d wr_pix=%04x rd_pix=%04x",
            core.mix0.mreg[6'h10], core.mix0.mreg[6'h11],
            core.mix0.mreg[6'h16], core.mix0.mreg[6'h00],
            core.mix0.px_text, core.mix0.display_en,
            fbw_buf, fbr_buf_l, core.disp_buf, fbw_pix, fbr_pix);
        $display("   pal: alias_lo/hi=%0d/%0d bank_lo/hi=%0d/%0d",
            n_pal_alias_lo, n_pal_alias_hi, n_pal_bank_lo, n_pal_bank_hi);
        $display("   vid: m416=%b rdreq/frame=%0d kick/frame=%0d wr_y_last=%0d rd_y=%0d spr_cmd=%0d srom=%0d spr_opq=%0d inrd=%0d/%0d p1a=%0d",
            core.mode_416, rdreq_cnt, kick_cnt, fbw_y, fbr_y_l,
            spr_cmd_cnt, srom_req_cnt, spr_opq_cnt, coin_rd_cnt, start_rd_cnt,
            p1a_rd_cnt);
        // coin-credit gate flags (V60 work RAM; word=A[15:1], addrs from the
        // MAME disassembly of the 0x600A7 credit routine):
        //   credits 0x20AC81, test-mode 0x20B1D0, free-play 0x20AC7A,
        //   coin raw 0x20AC40 / old 0x20AC41 / release-edge 0x20AC43
        $display("   coin: cr(ac81)=%02x test(b1d0)=%02x fp(ac7a)=%02x raw40=%02x old41=%02x reledge43=%02x",
            core.work_ram.mem['h5640][15:8], core.work_ram.mem['h58e8][7:0],
            core.work_ram.mem['h563d][7:0], core.work_ram.mem['h5620][7:0],
            core.work_ram.mem['h5620][15:8], core.work_ram.mem['h5621][15:8]);
        // char-select object-spawn probe (work RAM 0x2005a0.. block). MAME shows
        // this all-zero at attract and populated (word 0x2d0 hi=0x84 etc.) once
        // the PLAYER SELECT character object is created. objsig = OR of the block
        // so any nonzero proves the game spawned the character-select object.
        $display("   objblk: w2d0=%04x w2d3=%04x w2d8=%04x w2e8=%04x objsig=%0d",
            core.work_ram.mem['h2d0], core.work_ram.mem['h2d3],
            core.work_ram.mem['h2d8], core.work_ram.mem['h2e8],
            (|core.work_ram.mem['h2d0]) | (|core.work_ram.mem['h2d3]) |
            (|core.work_ram.mem['h2d8]) | (|core.work_ram.mem['h2e8]) |
            (|core.work_ram.mem['h2e0]) | (|core.work_ram.mem['h2e9]));
        $display("   snd: rom=%0d op=%0d bank=%0d/%0d(%03x) fm=%0d/%0d rf=%0d/%0d irqctl=%0d audio=%0d/%0d x=%0d",
            snd_rom_reqs, snd_opcodes, snd_bank_lo, snd_bank_hi,
            core.sound.sound_bank, snd_fm1, snd_fm2, snd_rfreg, snd_rfram,
            snd_irqctl, audio_l, audio_r, snd_audio_x);
        // NBG0/1 zoom+scroll probe (arabfgt select-screen swirl investigation)
        $display("   tmap: nbg0 zx=%04x zy=%04x sx=%04x sy=%04x | nbg1 zx=%04x zy=%04x sx=%04x sy=%04x",
            core.tm_zoomx[0], core.tm_zoomy[0], core.tm_scrollx[0], core.tm_scrolly[0],
            core.tm_zoomx[1], core.tm_zoomy[1], core.tm_scrollx[1], core.tm_scrolly[1]);
        $display("   tpage: F40=%04x F42=%04x F44=%04x F46=%04x F5c=%04x r00=%04x",
            core.tm_pages[0], core.tm_pages[1], core.tm_pages[2], core.tm_pages[3],
            core.tilemap.r1ff5c, core.tm_r1ff00);
        rdreq_cnt = 0; kick_cnt = 0; spr_cmd_cnt = 0; srom_req_cnt = 0; spr_opq_cnt = 0;
        p1a_rd_cnt = 0; coin_rd_cnt = 0; start_rd_cnt = 0;
    end
    dump_trace;
    if ($test$plusargs("SPRDUMP")) begin
        $display("--- sprite list entries 0..3 ---");
        for (int sd = 0; sd < 32; sd = sd + 1)
            $display("  spr[%04x]=%04x", sd, core.sprite_ram.sim_peek(sd));
        $display("--- sprite list entries 0x800..0x803 ---");
        for (int sd = 16'h4000; sd < 16'h4020; sd = sd + 1)
            $display("  spr[%04x]=%04x", sd, core.sprite_ram.sim_peek(sd));
    end
    if (fbr_accepts == 0)
        $fatal(1, "ROMBOOT framebuffer read handshake never accepted a line");
    if (coin_at >= 0 || start_at >= 0 || p1_event_count > 0)
        $display("[input-summary] active CPU samples: coin=%0d start=%0d p1a=%0d",
            coin_active_samples, start_active_samples, p1a_active_samples);
    if (coin_at >= 0 && coin_active_samples == 0)
        $fatal(1, "ROMBOOT P1 coin was never returned on SERVICE12 bit 2");
    if (start_at >= 0 && start_active_samples == 0)
        $fatal(1, "ROMBOOT P1 start was never returned on SERVICE12 bit 4");
    if (p1_event_count > 0 && p1a_active_samples == 0)
        $fatal(1, "ROMBOOT P1 digital event was never returned on P1A");
`ifdef S32_REAL_FB_SIM
    if (fb_deadline_fail)
        $fatal(1, "ROMBOOT production framebuffer reported a service deadline failure");
    if (fb_ddr_reads == 0)
        $fatal(1, "ROMBOOT DDR read traffic missing");
    if (b0 == 8'h22 && fb_ddr_writes == 0)
        $fatal(1, "GA2 DDR write traffic missing: writes=%0d reads=%0d",
               fb_ddr_writes, fb_ddr_reads);
    if (fb_line_acks < frames * 128)
        $fatal(1, "ROMBOOT framebuffer line service too sparse: acks=%0d frames=%0d",
               fb_line_acks, frames);
    if (b0 == 8'h22 && b2 != 1 && frames >= 70 && spr_px == 0)
        $fatal(1, "GA2 reached gameplay window without any sprite pixels");
    if (frame_sig_x != 0)
        $fatal(1, "ROMBOOT active-video signature contained X on %0d frames",
               frame_sig_x);
    if (b0 == 8'h22 && b2 != 1 && frames >= 70 && frame_sig_samples < 10)
        $fatal(1, "GA2 active-video signature window was not exercised");
    if (b0 == 8'h22 && b2 != 1 && frames >= 90 && frame_sig_changes < 3)
        $fatal(1, "GA2 active video stopped changing: samples=%0d changes=%0d",
               frame_sig_samples, frame_sig_changes);
    if (b0 == 8'h22)
        $display("GA2 DDR QUALIFICATION PASS writes=%0d reads=%0d line_acks=%0d max_wr=%0d max_rd=%0d max_er=%0d sig_samples=%0d sig_changes=%0d",
            fb_ddr_writes, fb_ddr_reads, fb_line_acks,
            fb_max_wr_wait, fb_max_rd_wait, fb_max_er_wait,
            frame_sig_samples, frame_sig_changes);
    else
        $display("ROMBOOT DDR PASS writes=%0d reads=%0d line_acks=%0d max_wr=%0d max_rd=%0d max_er=%0d",
            fb_ddr_writes, fb_ddr_reads, fb_line_acks,
            fb_max_wr_wait, fb_max_rd_wait, fb_max_er_wait);
`endif
    $display("ROMBOOT DONE");
    $finish;
end

// ---------------------------------------------------------------------------
// +PCHIST=<frame> [+PCHISTLEN=<n>]: over a window, measure the vblank PERIOD
// (clk_sys cycles between vs edges — is video timing stable?) and build a V60
// PC histogram (is the V60 spinning in a wait-loop, or doing real work?).
// ---------------------------------------------------------------------------
integer pchist_at, pchist_len;
integer pc_hist [int];
integer st_hist [int];
integer pc_samples = 0;
integer instr_count = 0;
// WORK-only CPI: excludes the ga2 attract frame-sync spin loop (test1 #0,flag at
// 0x133505 / bne at 0x13350b) so the per-frame WORK throughput can be compared to
// the authentic V60 band (~4.6-8 cyc/instr; IPSJ 1990 paper: 3.5 MIPS@16MHz peak).
integer work_cyc = 0;
integer work_instr = 0;
integer st_prev = 0;
integer vbl_cyc = 0;
reg     pchist_done = 0;
reg     vs_pe;
initial begin
    if (!$value$plusargs("PCHIST=%d", pchist_at)) pchist_at = -1;
    if (!$value$plusargs("PCHISTLEN=%d", pchist_len)) pchist_len = 40;
end
always @(posedge clk_sys) begin
    vbl_cyc <= vbl_cyc + 1;
    vs_pe <= vs;
    if (vs & ~vs_pe) begin
        if (pchist_at >= 0 && cur_frame >= pchist_at && cur_frame < pchist_at + pchist_len)
            $display("[vblper] fr=%0d vblank_period_cycles=%0d", cur_frame, vbl_cyc);
        vbl_cyc <= 0;
    end
    if (ce_cpu && pchist_at >= 0 && cur_frame >= pchist_at && cur_frame < pchist_at + pchist_len) begin
        pc_hist[core.v60.dbg_pc] = pc_hist[core.v60.dbg_pc] + 1;
        st_hist[core.v60.st] = st_hist[core.v60.st] + 1;
        pc_samples = pc_samples + 1;
        // count instructions = FSM entering S_DECODE (one per fetched opcode)
        if (core.v60.st == 3 /*S_DECODE*/ && st_prev != 3) instr_count = instr_count + 1;
        // WORK-only tally: same cycles/instrs but excluding the idle frame-sync spin
        if (core.v60.dbg_pc != 32'h0013_3505 && core.v60.dbg_pc != 32'h0013_350b) begin
            work_cyc = work_cyc + 1;
            if (core.v60.st == 3 && st_prev != 3) work_instr = work_instr + 1;
        end
        st_prev = core.v60.st;
    end
    if (pchist_at >= 0 && !pchist_done && cur_frame >= pchist_at + pchist_len && pc_samples > 0) begin
        pchist_done <= 1'b1;
        $display("[pchist] %0d ce_cpu cycles, %0d instrs over frames %0d..%0d => %0d.%02d cyc/instr",
                 pc_samples, instr_count, pchist_at, pchist_at + pchist_len - 1,
                 instr_count ? pc_samples/instr_count : 0,
                 instr_count ? (100*pc_samples/instr_count)%100 : 0);
        $display("[pchist] WORK-only (excl idle spin 0x133505/0x13350b): %0d cyc, %0d instrs => %0d.%02d cyc/instr  (authentic V60 band ~4.6-8)",
                 work_cyc, work_instr,
                 work_instr ? work_cyc/work_instr : 0,
                 work_instr ? (100*work_cyc/work_instr)%100 : 0);
        foreach (pc_hist[k])
            if (pc_hist[k] * 100 > pc_samples)
                $display("[pchist] pc=%08x count=%0d pct=%0d", k, pc_hist[k],
                         (pc_hist[k] * 100) / pc_samples);
        $display("[sthist] FSM state cycle distribution (>1%%):");
        foreach (st_hist[k])
            if (st_hist[k] * 100 > pc_samples)
                $display("[sthist] st=%0d count=%0d pct=%0d", k, st_hist[k],
                         (st_hist[k] * 100) / pc_samples);
    end
end

endmodule
