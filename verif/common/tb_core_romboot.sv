//============================================================================
//  Real-ROM boot harness: runs an actual game image (built by
//  tools/make_sim_images.py) on s32_core with full-size memory models.
//
//  Plusargs:
//    +IMG=<dir>     image directory (maincpu.hex/soundcpu.hex/tiles.hex/
//                   sprites.hex expected inside)
//    +DESC=<file>   the real 64-byte board descriptor as ASCII hex, i.e. the
//                   desc.txt that make_sim_images.py writes beside the image.
//                   This is what an MRA delivers on ioctl index 0; use it.
//    +B0=<hex>      override descriptor byte 0 (device-presence flags)
//    +B1=<hex>      override descriptor byte 1: board and analog-profile flags
//    +B2=<hex>      override the protection selector (PROT_*)
//    +SBM=<hex>     override the physical sprite-ROM bank mask (0/1/3)
//                   Without +DESC and without overrides the descriptor is all
//                   zeroes with a four-bank sprite mask.
//    +FRAMES=<n>    frames to run (804k clk_sys each), default 3
//    +REQUIRE_VERILATOR_SCREENSHOT  require +DUMPAT to produce a non-black
//                   PPM from this same full-core Verilator run
//    +DUMP5         write companion native RGB5 P6 PPM files (maxval=31)
//    +NATIVE5ONLY   write only native RGB5 files, omitting the diagnostic PPM
//    +REQUIRE_VERILATOR_NATIVE5 require a completed native RGB5 capture
//    +COINAT=<n>     assert P1 coin active-low starting at harness frame n
//    +COINLEN=<n>    coin assertion length in frames, default 1
//    +COIN2AT/LEN    optional second deterministic coin pulse
//    +STARTAT=<n>    assert P1 start active-low starting at harness frame n
//    +STARTLEN=<n>   start assertion length in frames, default 1
//    +START2AT/LEN   optional second deterministic start pulse
//    +P1AT<n>=<f>    start P1 digital event slot n (0..3) at frame f
//    +P1LEN<n>=<n>   event length in frames, default 1
//    +P1MASK<n>=<h>  P1A bits to pull low: L/R/U/D=80/40/20/10,
//                    B3/B2/B1 (Magic/Jump/Attack)=04/02/01
//    +GUNP1X/Y=<h>   positional-gun ADC coordinates (default 80)
//    +GUNP2X/Y=<h>   for descriptor-selected Alien 3/Jurassic Park runs
//    +ARABPERFAT=<f>  first Arabian Fight frame-boundary performance sample
//    +ARABPERFN=<n>   consecutive samples; each must be at FE4244/FE4248
//    +ARABHEAVYAT=<f> first field in the heavy-sprite recurrence window
//    +ARABHEAVYN=<n>  consecutive fields to inspect (default 6)
//    +ARABHEAVYMIN=<n> required fields with >=1400 sprite draw runs (default 3)
//    +ARABENTRY       replay Arabian Fight through the level-1 neutral entrance;
//                     pass when the player advances >=20 pixels between two
//                     NBG1 scene markers matched to the MAME reference
//    +QUIET           suppress routine per-frame diagnostics
//
//  This is a diagnostic, not a pass/fail tier: it reports boot progress
//  (PC movement, RAM/VRAM/palette/sprite/io write counts, IRQs taken,
//  exceptions, framebuffer pixels) and flags a stuck PC.
//============================================================================
`timescale 1ns/1ps

module tb_core_romboot (
`ifdef S32_EXTERNAL_CLOCKS
    input wire clk_sys,
    input wire clk_ram
`endif
);

import s32_pkg::*;

initial $display({
    "[audio] comparison unavailable: romboot uses the T80 and JT12 simulation stubs; ",
    "validate production sound with the mixed-language sound regressions"});

`ifndef S32_EXTERNAL_CLOCKS
reg clk_sys = 0, clk_ram = 0;
`endif
reg rst = 1;
reg clk_v25 = 0;
`ifndef S32_EXTERNAL_CLOCKS
always #10.35 clk_sys = ~clk_sys;
always #5.175 clk_ram = ~clk_ram;
`endif
always @(posedge clk_sys) clk_v25 <= ~clk_v25;

// clock enables
// +CPUDIV=<1..3> is a simulation-only cause-isolation control. The production
// System 32 cadence is 3; 2/1 deliberately overclock the V60 to prove whether
// a visible failure is caused by missed CPU-side frame work rather than video.
reg ce_cpu = 0;  reg [1:0] cdiv = 0;
integer cpu_div;
initial begin
    if (!$value$plusargs("CPUDIV=%d", cpu_div)) cpu_div = 3;
    if (cpu_div < 1 || cpu_div > 3)
        $fatal(1, "ROMBOOT CPUDIV must be 1..3, got %0d", cpu_div);
end
always @(posedge clk_sys) begin
    cdiv <= (cdiv == cpu_div - 1) ? 2'd0 : cdiv + 1'd1;
    ce_cpu <= (cdiv == 0);
end
reg ce_z80 = 0;  reg [2:0] zdiv = 0;
always @(posedge clk_sys) begin
    zdiv <= (zdiv == 5) ? 3'd0 : zdiv + 1'd1;
    ce_z80 <= (zdiv == 0);
end
reg ce_fm = 0; reg [31:0] fm_acc = 0;
always @(posedge clk_sys) begin
    logic [32:0] fm_sum;
    // Mirror the production free-running FM NCO, including while rst is high.
    fm_sum = {1'b0,fm_acc} + 33'd715924818;
    ce_fm <= fm_sum[32];
    fm_acc <= fm_sum[31:0];
end
reg ce_pcm = 0;  reg [31:0] pcm_acc = 0;
always @(posedge clk_sys) begin
    logic [32:0] pcm_sum;
    if (rst) begin
        pcm_acc <= 32'd0;
        ce_pcm <= 1'b0;
    end
    else begin
        // 12.5 MHz / 48.317307 MHz, identical to the production top-level NCO.
        pcm_sum = {1'b0,pcm_acc} + 33'd1111135834;
        ce_pcm <= pcm_sum[32];
        pcm_acc <= pcm_sum[31:0];
    end
end

// ---------------------------------------------------------------------------
// Board descriptor.
//
// +DESC=<file> reads the real descriptor that tools/make_sim_images.py writes
// beside the ROM image (desc.txt), which is byte-identical to the 64 bytes an
// MRA delivers on ioctl index 0.  Prefer it: hand-maintained per-game bytes in
// a runner script drift from the shipped MRA, and a descriptor that does not
// match the MRA means the harness is simulating a different machine than the
// core ships -- wrong device presence, wrong protection selector, wrong sprite
// bank mask.
//
// The +B0/+B1/+B2/+SBM plusargs remain as explicit per-field overrides for
// directed descriptor-variation tests, and win over the file when given.  Only
// a plusarg that is actually present overrides; absence is not zero.
//
// The field/bit assignment below mirrors s32_rom_loader.sv's descriptor decode
// exactly.  Keep the two in step: a divergence here silently invalidates every
// run made through this harness.
// ---------------------------------------------------------------------------
board_desc_t board;
reg [7:0] desc_bytes [0:15];
string    desc_path;
integer   desc_fd, desc_c, desc_i, desc_nib, desc_hi, desc_eof;
integer b0;
integer b1;
integer b2;
integer sbm;
integer ga2_qualification;

function automatic integer hex_nibble(input integer c);
    if      (c >= "0" && c <= "9") hex_nibble = c - "0";
    else if (c >= "a" && c <= "f") hex_nibble = 10 + (c - "a");
    else if (c >= "A" && c <= "F") hex_nibble = 10 + (c - "A");
    else                           hex_nibble = -1;   // whitespace/newline/junk
endfunction

initial begin
    for (desc_i = 0; desc_i < 16; desc_i = desc_i + 1) desc_bytes[desc_i] = 8'h00;

    if ($value$plusargs("DESC=%s", desc_path)) begin
        desc_fd = $fopen(desc_path, "r");
        if (desc_fd == 0) begin
            $display("[desc] FATAL: cannot open %0s", desc_path);
            $fatal(1);
        end
        // desc.txt is one line of ASCII hex.  Consume nibble pairs, ignoring
        // any separator, until the 16 bytes the loader inspects are filled.
        desc_i = 0; desc_hi = -1; desc_eof = 0;
        while (desc_i < 16 && desc_eof == 0) begin
            desc_c = $fgetc(desc_fd);
            if (desc_c < 0) desc_eof = 1;
            else begin
                desc_nib = hex_nibble(desc_c);
                if (desc_nib >= 0) begin
                    if (desc_hi < 0) desc_hi = desc_nib;
                    else begin
                        desc_bytes[desc_i] = 8'((desc_hi << 4) | desc_nib);
                        desc_i  = desc_i + 1;
                        desc_hi = -1;
                    end
                end
            end
        end
        $fclose(desc_fd);
        if (desc_i < 4) begin
            $display("[desc] FATAL: %0s held only %0d descriptor bytes",
                     desc_path, desc_i);
            $fatal(1);
        end
        $display("[desc] %0s -> %02x %02x %02x %02x",
                 desc_path, desc_bytes[0], desc_bytes[1],
                 desc_bytes[2], desc_bytes[3]);
    end

    b0  = desc_bytes[0];
    b1  = desc_bytes[1];
    b2  = desc_bytes[2];
    sbm = desc_bytes[3][7] ? desc_bytes[3][1:0] : 3;
    // Explicit overrides.  $value$plusargs leaves its argument untouched when
    // the plusarg is absent, so each read is conditional rather than defaulted.
    void'($value$plusargs("B0=%h",  b0));
    void'($value$plusargs("B1=%h",  b1));
    void'($value$plusargs("B2=%h",  b2));
    void'($value$plusargs("SBM=%h", sbm));
    // Keep the Golden Axe-only qualification anchored to the raw descriptor
    // flags.  The protection selector in b2 is unrelated, and using the
    // packed board struct in a late final block made the generated Verilator
    // model vulnerable to an incorrect qualification on standard descriptors.
    ga2_qualification = ((b0 & 8'h06) == 8'h02);

    board = '0;
    board.multi32     = b0[0];
    // b0[1] (was has_v25) and b0[2] (was v25_table) are reserved: V25/
    // protection were removed, OutRunners never sets them.
    board.has_adc     = b0[3];
    board.has_ppi     = b0[5];
    board.has_motor_hle = b0[6];
    board.dual_pcb    = b1[0];
    board.flip_y      = b1[1];
    board.gun_aim     = b1[2];
    board.coin_swap   = b1[3];
    board.analog_profile = b1[5:4];
    board.dual_comm_ff = b1[6];
    board.comm_link_hle = b2[7];
    // b2[6:0] (was prot_sel) is reserved.
    board.sprite_bank_valid = 1'b1;
    board.sprite_bank_mask  = sbm[1:0];
    $display("[desc] board: multi32=%0d ga2=%0d adc=%0d ppi=%0d motor=%0d dual=%0d flip_y=%0d gun=%0d coin_swap=%0d analog=%0d sbm=%0d",
             board.multi32,
             ga2_qualification, board.has_adc, board.has_ppi,
             board.has_motor_hle, board.dual_pcb,
             board.flip_y, board.gun_aim, board.coin_swap,
             board.analog_profile,
             board.sprite_bank_mask);
end

// ---------------------------------------------------------------------------
// memory models (SDRAM layout per s32_pkg bases)
// ---------------------------------------------------------------------------
reg [15:0]  mc  [0:1048575];    // maincpu   base 0x000000, 2MB
reg [15:0]  sc  [0:2097151];    // soundcpu  base 0x200000, 4MB
reg [63:0]  tl  [0:524287];     // tiles     base 0x600000, 4MB
reg [127:0] sp  [0:1048575];    // sprites   base 0x1000000, 16MB
reg [7:0] mcu_raw [0:65535];
reg [7:0] mcu_ext [0:65535];
reg [15:0] eep_img [0:63];
integer mcu_fd, mcu_got, mcu_i;
integer eep_fd;
reg images_loaded = 1'b0;
reg eep_present = 1'b0;

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
    eep_fd = $fopen({imgdir, "/eeprom.hex"}, "r");
    if (eep_fd != 0) begin
        $fclose(eep_fd);
        $readmemh({imgdir, "/eeprom.hex"}, eep_img);
        eep_present = 1'b1;
    end
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
    images_loaded = 1'b1;
end

// p0: V60 program (clk_sys single-cycle toggle ack)
wire        p0_req;
wire        p0_burst;
wire [24:1] p0_addr;
reg  [63:0] p0_dout;
reg         p0_ack = 0;
always @(posedge clk_sys) begin
    p0_ack  <= p0_req & ~p0_ack;
    if (p0_burst)
        p0_dout <= {mc[{p0_addr[20:3],2'b11}], mc[{p0_addr[20:3],2'b10}],
                    mc[{p0_addr[20:3],2'b01}], mc[{p0_addr[20:3],2'b00}]};
    else
        p0_dout <= {48'd0, mc[p0_addr[20:1]]};
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
wire  [1:0] fbw_buf, fbe_buf, fbr_buf;
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
wire [15:0] fbr_pix_new = fbmem[fbr_buf_l][fbr_y_l][fbr_x];
assign fbr_pix = fbr_pix_new;
`endif
integer spr_px = 0;
always @(posedge clk_ram) if (fbw_valid) spr_px = spr_px + 1;
// Renderer liveness: accepted sprite-ROM bursts and valid draw commands.
// These are harness-only probes; scale_start is asserted once per decoded
// non-clip/non-end sprite command.
integer spr_cmd_cnt = 0, srom_req_cnt = 0;
reg [15:0] spr_jump_prev [0:1];
reg        spr_jump_seen [0:1];
reg        spr_list_log;
localparam logic [4:0] SPR_R_DECODE = 5'd8;
initial begin
    spr_list_log = $test$plusargs("SPRLIST");
    spr_jump_seen[0] = 1'b0;
    spr_jump_seen[1] = 1'b0;
end
always @(posedge clk_ram) begin
    if (core.sprite.scale_start) spr_cmd_cnt = spr_cmd_cnt + 1;
    if (p2_req && !p2_ack)       srom_req_cnt = srom_req_cnt + 1;
    // Report a command-list jump only when it changes for that framebuffer
    // parity.  This keeps long real-ROM runs concise while exposing the exact
    // list target consumed after each sprite-update pulse.
    if (spr_list_log && core.sprite.rs == SPR_R_DECODE &&
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
// P1A is C00000; MAME system32_generic puts start on port E bit 4 and P1 coin
// on bit 2.
integer p1a_rd_cnt = 0, coin_rd_cnt = 0, start_rd_cnt = 0;
localparam integer p1_coin_bit = 2;
integer p1a_active_samples = 0;
integer coin_active_samples = 0, start_active_samples = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && !core.m_we && !core.ack_d) begin
        if ({core.A[23:1], 1'b0} == 24'hc00000) begin
            p1a_rd_cnt = p1a_rd_cnt + 1;
            if (core.m_rdata[7:0] != 8'hff) begin
                p1a_active_samples = p1a_active_samples + 1;
                $display("[input-sampled] frame %0d: P1A read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.pc);
            end
        end
        if ({core.A[23:1], 1'b0} == 24'hc00008) begin
            coin_rd_cnt = coin_rd_cnt + 1;
            start_rd_cnt = start_rd_cnt + 1;
            if (!core.m_rdata[2]) begin
                coin_active_samples = coin_active_samples + 1;
                $display("[input-sampled] frame %0d: P1 coin read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.pc);
            end
            if (!core.m_rdata[4]) begin
                start_active_samples = start_active_samples + 1;
                $display("[input-sampled] frame %0d: P1 start read=%04x pc=%08x",
                    cur_frame, core.m_rdata, core.v60.pc);
            end
        end
    end
end

// input stubs
reg  [7:0] in_p1a_r = 8'hff;
reg  [7:0] in_portc_r = 8'hff;
reg  [7:0] in_svc12_r = 8'hff;
integer coin_at, coin_len, coin2_at, coin2_len;
integer start_at, start_len, start2_at, start2_len;
integer accel_at, accel_len, accel_value;
integer p1_at [0:3];
integer p1_len [0:3];
integer p1_mask [0:3];
integer p1_event_count;
// Optional live input bridge used by the native visual viewer. The low byte
// is the active-low P1A mask; bit 8 is coin and bit 9 is start. The viewer
// atomically replaces this one-line file between frame boundaries, so the
// simulation never samples a partially written control word.
string input_path;
integer input_fd, input_scan, input_mask_value;
integer cur_frame = 0;
initial begin
    if (!$value$plusargs("COINAT=%d", coin_at)) coin_at = -1;
    if (!$value$plusargs("COINLEN=%d", coin_len)) coin_len = 1;
    if (!$value$plusargs("COIN2AT=%d", coin2_at)) coin2_at = -1;
    if (!$value$plusargs("COIN2LEN=%d", coin2_len)) coin2_len = 1;
    if (!$value$plusargs("STARTAT=%d", start_at)) start_at = -1;
    if (!$value$plusargs("STARTLEN=%d", start_len)) start_len = 1;
    if (!$value$plusargs("START2AT=%d", start2_at)) start2_at = -1;
    if (!$value$plusargs("START2LEN=%d", start2_len)) start2_len = 1;
    if (!$value$plusargs("ACCELAT=%d", accel_at)) accel_at = -1;
    if (!$value$plusargs("ACCELLEN=%d", accel_len)) accel_len = 1;
    if (!$value$plusargs("ACCELVALUE=%h", accel_value)) accel_value = 8'hff;
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
    if (!$value$plusargs("INPUTFILE=%s", input_path)) input_path = "";
    if (input_path != "")
        $display("[input] live keyboard bridge: %0s", input_path);
    p1_event_count = (p1_at[0] >= 0) + (p1_at[1] >= 0) +
                     (p1_at[2] >= 0) + (p1_at[3] >= 0);
end
wire [7:0] adc_a [0:7];
// MAME's no-input PADDLE default is not always the nominal 0x80.  The
// retained Rad Rally reference trace reports 0x75, so allow a bounded
// diagnostic override while keeping the normal deterministic board defaults.
integer adc0_override;
initial if (!$value$plusargs("ADC0=%h", adc0_override)) adc0_override = -1;
integer gun_p1_x, gun_p1_y, gun_p2_x, gun_p2_y;
initial begin
    if (!$value$plusargs("GUNP1X=%h", gun_p1_x)) gun_p1_x = 8'h80;
    if (!$value$plusargs("GUNP1Y=%h", gun_p1_y)) gun_p1_y = 8'h80;
    if (!$value$plusargs("GUNP2X=%h", gun_p2_x)) gun_p2_x = 8'h80;
    if (!$value$plusargs("GUNP2Y=%h", gun_p2_y)) gun_p2_y = 8'h80;
end
wire [7:0] sim_gun_p1_x, sim_gun_p1_y, sim_gun_p2_x, sim_gun_p2_y;
// GUNP* values are cabinet ADC coordinates for both gun titles. Alien 3 now
// shares Jurassic Park's direct mapping instead of a title-specific curve.
assign sim_gun_p1_x = gun_p1_x[7:0];
assign sim_gun_p1_y = gun_p1_y[7:0];
assign sim_gun_p2_x = gun_p2_x[7:0];
assign sim_gun_p2_y = gun_p2_y[7:0];
assign adc_a[0] = board.gun_aim ? sim_gun_p1_x :
                  (adc0_override >= 0) ? adc0_override[7:0] :
                  (board.analog_profile == ANALOG_ALL_FF) ? 8'hff : 8'h80;
assign adc_a[1] = board.gun_aim ? sim_gun_p1_y :
                  (board.analog_profile == ANALOG_ALL_FF) ? 8'hff :
                  (board.analog_profile == ANALOG_DRIVING) ?
                  (((((accel_at >= 0 && cur_frame >= accel_at &&
                     cur_frame < accel_at + accel_len) || input_mask_value[10]) &&
                    !input_mask_value[12])) ?
                   accel_value[7:0] : 8'h00) : 8'h80;
assign adc_a[2] = board.gun_aim ? sim_gun_p2_x :
                  (board.analog_profile == ANALOG_ALL_FF) ? 8'hff :
                  (board.analog_profile == ANALOG_DRIVING) ? 8'h00 : 8'h80;
assign adc_a[3] = board.gun_aim ? sim_gun_p2_y :
                  (board.analog_profile == ANALOG_ALL_FF) ? 8'hff : 8'h80;
generate
    for (genvar gi = 4; gi < 8; gi = gi + 1)
        assign adc_a[gi] = (board.analog_profile == ANALOG_ALL_FF) ? 8'hff : 8'h80;
endgenerate

wire hs, vs, hb, vb;
wire [23:0] rgb_a;
wire        ce_pix;
wire signed [15:0] audio_l, audio_r;
reg        eep_ld_wr = 1'b0;
reg  [5:0] eep_ld_addr = 6'd0;
reg [15:0] eep_ld_data = 16'hffff;

// Reproduce the live loader's index-2 default transfer before reset releases.
// eeprom.hex contains the little-endian packing presented by WIDE hps_io; the
// index-2 loader swaps each raw big-endian 93C46 cell before storing it.
integer eep_load_i;
`ifndef S32_EXTERNAL_CLOCKS
initial begin
    wait (images_loaded);
    if (eep_present) begin
        repeat (2) @(posedge clk_sys);
        for (eep_load_i = 0; eep_load_i < 64; eep_load_i = eep_load_i + 1) begin
            eep_ld_addr = eep_load_i[5:0];
            eep_ld_data = {eep_img[eep_load_i][7:0], eep_img[eep_load_i][15:8]};
            eep_ld_wr = 1'b1;
            @(posedge clk_sys);
        end
        eep_ld_wr = 1'b0;
        $display("[eep] loaded %0s/eeprom.hex", imgdir);
    end
end
`else
integer eep_load_state = 0;
always @(posedge clk_sys) begin
    if (eep_load_state == 0 && images_loaded)
        eep_load_state = eep_present ? 1 : 67;
    else if (eep_load_state >= 1 && eep_load_state <= 64) begin
        eep_ld_addr = eep_load_state - 1;
        eep_ld_data = {eep_img[eep_load_state - 1][7:0],
                       eep_img[eep_load_state - 1][15:8]};
        eep_ld_wr = 1'b1;
        eep_load_state = eep_load_state + 1;
    end
    else if (eep_load_state == 65) begin
        eep_ld_wr = 1'b0;
        eep_load_state = 66;
        $display("[eep] loaded %0s/eeprom.hex", imgdir);
    end
end
`endif

// +FASTV60 selects the production wide instruction-fetch transport for a
// boot run; default keeps the shared-bus PCB path so both transports can be
// A/B'd against the same ROM image.
reg        test_fast_v60 = 1'b0;
initial test_fast_v60 = $test$plusargs("FASTV60");

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
`ifdef S32_UNIVERSAL
    .clk_v25(clk_v25),
`endif
    .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm), .pause(1'b0),
    .fast_v60(test_fast_v60),
    .sdr_p0_req(p0_req), .sdr_p0_burst(p0_burst), .sdr_p0_addr(p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(p1_req), .sdr_p1_addr(p1_addr), .sdr_p1_dout(p1_dout), .sdr_p1_ack(p1_ack),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr), .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_p3_req(p3_req), .sdr_p3_addr(p3_addr), .sdr_p3_dout(p3_dout), .sdr_p3_ack(p3_ack),
    .sdr_p4_req(), .sdr_p4_addr(), .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_wr_busy(fbw_busy),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(fbr_buf),
    .fb_rd_y(fbr_y), .fb_rd_ack(fbr_ack),
    .fb_rd_x(fbr_x), .fb_rd_pix(fbr_pix),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
    .eep_ld_wr(eep_ld_wr), .eep_ld_addr(eep_ld_addr), .eep_ld_data(eep_ld_data),
    .eep_rd_addr(6'h0),
    .eep_rd_data(), .eep_upload(1'b0), .eep_modified(),
    .in_p1a(in_p1a_r), .in_p2a(8'hff), .in_portc(in_portc_r),
    .in_svc12(in_svc12_r), .in_svc34(8'hff),
    .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
    .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_a),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(rgb_a), .rgb_b(), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r), .out_lamps()
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
`ifdef S32_EXTERNAL_CLOCKS
// Savable visual lane. All progression is explicit clocked state; no timing
// coroutine remains in the model, so Verilator can serialize it safely.
integer visual_reset_cycles = 0;
integer visual_frame_cycles = 0;
integer visual_p1_ev;
initial begin
    if (!$value$plusargs("FRAMES=%d", frames)) frames = 3;
    quiet = $test$plusargs("QUIET");
    playmagic = $test$plusargs("PLAYMAGIC");
    playfight = $test$plusargs("PLAYFIGHT");
    arabentry = $test$plusargs("ARABENTRY");
end
always @(posedge clk_sys) begin
    if (rst) begin
        visual_reset_cycles = visual_reset_cycles + 1;
        if (visual_reset_cycles >= 2048) begin
            rst = 1'b0;
            visual_frame_cycles = 0;
            cur_frame = 0;
        end
    end
    else begin
        if (visual_frame_cycles == 0) begin
            in_p1a_r = 8'hff;
            in_portc_r = 8'hff;
            in_svc12_r = 8'hff;
            if (input_path != "") begin
                input_mask_value = 0;
                input_fd = $fopen(input_path, "r");
                if (input_fd != 0) begin
                    input_scan = $fscanf(input_fd, "%h", input_mask_value);
                    $fclose(input_fd);
                    if (input_scan == 1) begin
                        in_p1a_r = in_p1a_r & ~input_mask_value[7:0];
                        if (input_mask_value[8]) in_svc12_r[p1_coin_bit] = 1'b0;
                        if (input_mask_value[9]) in_svc12_r[4] = 1'b0;
                    end
                end
            end
            for (visual_p1_ev = 0; visual_p1_ev < 4; visual_p1_ev = visual_p1_ev + 1)
                if (!input_mask_value[13] &&
                    p1_at[visual_p1_ev] >= 0 && p1_len[visual_p1_ev] > 0 &&
                    cur_frame >= p1_at[visual_p1_ev] &&
                    cur_frame < p1_at[visual_p1_ev] + p1_len[visual_p1_ev])
                    in_p1a_r = in_p1a_r & ~p1_mask[visual_p1_ev][7:0];

            gear_pressed = ~in_p1a_r[0];
            if (board.gear_toggle) begin
                if (gear_pressed && !gear_pressed_d)
                    gear_latched = ~gear_latched;
                gear_pressed_d = gear_pressed;
                in_p1a_r[0] = ~gear_latched;
            end
            else begin
                gear_latched = 1'b0;
                gear_pressed_d = 1'b0;
            end
            if (coin_at >= 0 && coin_len > 0 && cur_frame >= coin_at &&
                cur_frame < coin_at + coin_len)
                in_svc12_r[p1_coin_bit] = 1'b0;
            if (coin2_at >= 0 && coin2_len > 0 && cur_frame >= coin2_at &&
                cur_frame < coin2_at + coin2_len)
                in_svc12_r[p1_coin_bit] = 1'b0;
            if (start_at >= 0 && start_len > 0 && cur_frame >= start_at &&
                cur_frame < start_at + start_len)
                in_svc12_r[4] = 1'b0;
            if (start2_at >= 0 && start2_len > 0 && cur_frame >= start2_at &&
                cur_frame < start2_at + start2_len)
                in_svc12_r[4] = 1'b0;

            // Keep the external-clock visual lane on the same deterministic
            // Arabian Fight replay as the timing-based harness.  This lane is
            // also the savable/checkpointable frontend, so divergence runs
            // must not silently use a different input sequence.
            if (playmagic || playfight || arabentry) begin
                if (cur_frame >= 470 && cur_frame < 600 &&
                    (cur_frame % 40) < 6) begin
                    in_p1a_r[0] = 1'b0;
                    in_svc12_r[4] = 1'b0;
                end
                if (!arabentry && cur_frame >= 680)
                    in_p1a_r[6] = 1'b0;
            end
            if (arabentry) begin
                if (cur_frame >= 1200 && cur_frame < 1450 &&
                    (cur_frame % 20) < 5)
                    in_p1a_r[1] = 1'b0;
                if (cur_frame >= 1670 && cur_frame < 1675)
                    in_p1a_r[1] = 1'b0;
            end
            if (playmagic && cur_frame >= 700 &&
                ((cur_frame - 700) % 65) < 45)
                in_p1a_r[2] = 1'b0;
            if (playfight && cur_frame >= 700 && (cur_frame % 25) < 5)
                in_p1a_r[0] = 1'b0;
        end

        if (visual_frame_cycles == 803999) begin
            visual_frame_cycles = 0;
            if (quiet && (cur_frame % 100) == 0) begin
                $display("[progress] frame %0d", cur_frame);
                $fflush();
            end
            rdreq_cnt = 0; kick_cnt = 0; spr_cmd_cnt = 0;
            srom_req_cnt = 0; spr_opq_cnt = 0;
            p1a_rd_cnt = 0; coin_rd_cnt = 0; start_rd_cnt = 0;
            tm_req_cnt = 0; tm_lb_cnt = 0; tm_opaque_cnt = 0;
            // Scene-tagged Arabian Fight entry barrier for the external-clock
            // lane.  The two NBG1 scroll markers are stable across MAME and
            // RTL frame-rate differences; compare the player object position
            // between them rather than trusting an absolute frame number.
            if (arabentry && !arab_entry_started &&
                core.tm_zoomx[1] == 16'h0400 &&
                core.tm_scrollx[1] >= 16'h0271 &&
                core.tm_scrollx[1] < 16'h0300) begin
                integer arab_jump_x2;
                integer arab_raw_x2;
                arab_jump_x2 = $signed({{20{core.sprite_ram.mem[16'h0002][11]}},
                                        core.sprite_ram.mem[16'h0002][11:0]});
                arab_raw_x2 = $signed({{20{core.sprite_ram.mem[16'h0065][11]}},
                                       core.sprite_ram.mem[16'h0065][11:0]});
                arab_entry_x0 = arab_jump_x2 + arab_raw_x2;
                arab_entry_f0 = cur_frame;
                arab_entry_started = 1'b1;
                $display("[arab-entry] start f=%0d n1sx=%04x x=%0d jump=%0d raw=%0d",
                    cur_frame, core.tm_scrollx[1], arab_entry_x0,
                    arab_jump_x2, arab_raw_x2);
            end
            if (arabentry && arab_entry_started && !arab_entry_done &&
                core.tm_zoomx[1] == 16'h0400 &&
                core.tm_scrollx[1] >= 16'h0659) begin
                integer arab_jump_x3;
                integer arab_raw_x3;
                arab_jump_x3 = $signed({{20{core.sprite_ram.mem[16'h0002][11]}},
                                        core.sprite_ram.mem[16'h0002][11:0]});
                arab_raw_x3 = $signed({{20{core.sprite_ram.mem[16'h0065][11]}},
                                       core.sprite_ram.mem[16'h0065][11:0]});
                arab_entry_x1 = arab_jump_x3 + arab_raw_x3;
                arab_entry_f1 = cur_frame;
                arab_entry_dx = arab_entry_x1 - arab_entry_x0;
                arab_entry_done = 1'b1;
                $display("[arab-entry] end f=%0d n1sx=%04x x=%0d dx=%0d jump=%0d raw=%0d",
                    cur_frame, core.tm_scrollx[1], arab_entry_x1,
                    arab_entry_dx, arab_jump_x3, arab_raw_x3);
                if (arab_entry_dx < 20) begin
                    arab_entry_failed = 1'b1;
                    $display("ARABIAN FIGHT ENTRY FAIL: neutral-input player advanced only %0d pixels between scene markers (need >=20)",
                        arab_entry_dx);
                end
                else
                    $display("ARABIAN FIGHT ENTRY PASS: neutral-input player advanced %0d pixels between scene markers",
                        arab_entry_dx);
            end
            // cur_frame is owned by the native VBlank block below.  The
            // external-clock scheduler only refreshes cabinet stimulus and
            // provides a bounded stop check; incrementing here as well makes
            // frame labels/input timing drift and can skip live-capture
            // cadence values.
            if (cur_frame >= frames) begin
                if (arabentry && !arab_entry_done)
                    $fatal(1, "ARABIAN FIGHT ENTRY window was not completed");
                if (arabentry && arab_entry_failed)
                    $fatal(1, "ARABIAN FIGHT ENTRY regression failed: neutral-input dx=%0d",
                        arab_entry_dx);
                $display("ROMBOOT DONE");
                $finish;
            end
        end
        else
            visual_frame_cycles = visual_frame_cycles + 1;
    end
end
`endif

// ---------------------------------------------------------------------------
// progress instrumentation
// ---------------------------------------------------------------------------
integer n_vram_wr = 0, n_pal_wr = 0, n_spr_wr = 0, n_io_wr = 0;
integer n_intc_wr = 0, n_wram_wr = 0, n_exc = 0, n_irq = 0;
integer n_pal_alias_lo = 0, n_pal_alias_hi = 0;
integer n_pal_bank_lo = 0, n_pal_bank_hi = 0;
integer vs_count = 0;
// +IOLOG=<n>: bounded read-only trace of System 32 I/O writes.  This is used
// to distinguish a missing CNT1 write from a decode/byte-lane loss without
// changing the core's functional signals.
integer iolog = 0, iolog_n = 0;
initial if (!$value$plusargs("IOLOG=%d", iolog)) iolog = 0;
always @(posedge clk_sys) begin
    if (iolog && iolog_n < iolog && core.m_req && core.m_we &&
        core.A[23:20] == 4'hc && core.A[6:5] == 2'b00 && core.m_be[0]) begin
        iolog_n = iolog_n + 1;
        $display("[iow] f=%0d pc=%08x A=%06x addr=%02x data=%04x be=%b cnt=%b/%b/%b",
            cur_frame, core.v60.pc, core.A, core.A[5:1], core.m_wdata,
            core.m_be, core.io0_cnt2, core.io0_cnt1, core.io0.cnt0);
    end
end
// +ADCLOG=<n>: reconstruct bounded, accepted MSM6253 samples exactly as the
// V60 receives them. Unlike IOLOG, this ignores held request cycles and logs
// only the load transaction plus eight acknowledged D7 reads.
integer adclog = 0, adclog_n = 0;
integer adc_trace_bits = 0;
reg [1:0] adc_trace_channel = 2'd0;
reg [7:0] adc_trace_shift = 8'd0;
initial if (!$value$plusargs("ADCLOG=%d", adclog)) adclog = 0;
always @(posedge clk_sys) begin
    if (adclog && adclog_n < adclog && core.m_req && core.m_ack &&
        !core.ack_d && core.sel_adc && core.m_be[0]) begin
        if (core.m_we) begin
            adc_trace_channel = core.A[2:1];
            adc_trace_bits = 0;
            adc_trace_shift = 8'd0;
            $display("[adc-select] f=%0d pc=%08x ch=%0d source=%02x",
                cur_frame, core.v60.pc, core.A[2:1],
                adc_a[core.A[2:1]]);
        end
        else begin
            adc_trace_shift = {adc_trace_shift[6:0], core.m_rdata[7]};
            adc_trace_bits = adc_trace_bits + 1;
            if (adc_trace_bits == 8) begin
                adclog_n = adclog_n + 1;
                $display("[adc-sample] n=%0d f=%0d pc=%08x ch=%0d value=%02x",
                    adclog_n, cur_frame, core.v60.pc, adc_trace_channel,
                    adc_trace_shift);
            end
        end
    end
end
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

// exception / irq counters (state-entry edges).  Use numeric state values
// rather than hierarchical enum-item refs, which trip a Verilator
// EnumItemRef elaboration fault.  The optional FP states occupy five enum
// slots, so keep both production variants synchronized with s32_v60.sv.
// Keep the harness probes tied to the current V60 enum layout.  The state
// type is intentionally private to the CPU, so these mirrors are conditional
// only where the optional FP states move the exception tail.
localparam [6:0] S_DECODE_V  = 7'd3;  // == s32_v60 st_t S_DECODE
localparam [6:0] S_EA_VAL_V  = 7'd8;  // == s32_v60 st_t S_EA_VAL
localparam [6:0] S_EXEC_V    = 7'd9;  // == s32_v60 st_t S_EXEC
localparam [6:0] S_WB_MEM_V  = 7'd13; // == s32_v60 st_t S_WB_MEM
localparam [6:0] S_NEXT_V    = 7'd15; // == s32_v60 st_t S_NEXT
localparam [6:0] S_RSR_V     = 7'd38; // == s32_v60 st_t S_RSR
`ifdef S32_V60_NO_FP
localparam [6:0] S_EXC_PUSH1_V = 7'd69;   // == s32_v60 st_t S_EXC_PUSH1
localparam [6:0] S_EXC_VEC_V   = 7'd73;   // == s32_v60 st_t S_EXC_VEC
`else
localparam [6:0] S_EXC_PUSH1_V = 7'd74;   // == s32_v60 st_t S_EXC_PUSH1
localparam [6:0] S_EXC_VEC_V   = 7'd78;   // == s32_v60 st_t S_EXC_VEC
`endif
reg exc_d, irq_d;
always @(posedge clk_sys) begin
    exc_d <= (core.v60.st == S_EXC_PUSH1_V);
    if ((core.v60.st == S_EXC_PUSH1_V) && !exc_d) begin
        if (core.v60.exc_vector >= 8'h40) n_irq = n_irq + 1;
        else n_exc = n_exc + 1;
    end
end

// Narrow Spider-Man fetch/PC diagnostic.  The ROM branch at 0x062174 is
// encoded 62 C2; its only legal successors are 0x062136 and 0x062176.
// Keep this opt-in and observation-only so normal boot runs are unchanged.
always @(posedge clk_sys) begin
    if ($test$plusargs("PFTRACE") && core.v60.ce &&
        core.v60.pc == 32'h0006_2168) begin
        $display("[pfretire] pc=%08x st=%0d flags=%02x len=%0d/%0d ealen=%0d flag=%0d/%0d total=%0d execlen=%0d op=%02x b1=%02x b2=%02x",
                 core.v60.pc, core.v60.st, core.v60.instflags,
                 core.v60.len1, core.v60.len2, core.v60.ea_len,
                 core.v60.flag1, core.v60.flag2, core.v60.total_len,
                 core.v60.exec_retire_len, core.v60.opcode,
                 core.v60.fb[1], core.v60.fb[2]);
    end
    if ($test$plusargs("PFTRACE") && core.v60.ce &&
        core.v60.st == S_DECODE_V &&
        ((core.v60.pc >= 32'h0006_2110 && core.v60.pc < 32'h0006_2190) ||
         core.v60.opcode == 8'hc2)) begin
        $display("[pftrace] pc=%08x st=%0d op=%02x b1=%02x base=%08x valid=%0d wr=%0d pfbusy=%0d pfaddr=%08x epoch=%0d/%0d owner=%0d req=%0d ack=%0d irqn=%0d ie=%0d",
                 core.v60.pc, core.v60.st, core.v60.opcode, core.v60.fb[1],
                 core.v60.fb_base, core.v60.fb_valid, core.v60.fb_wr,
                 core.v60.pf_busy, core.v60.pf_addr, core.v60.pf_epoch,
                 core.v60.pf_iss_epoch, core.v60.bus_owner, core.v60.bus_req,
                 core.v60.bus_ack, core.v60.irq_n, core.v60.psw_ie);
        if ($test$plusargs("STOPPF") && core.v60.pc == 32'h0006_216b)
            $finish;
        if ($test$plusargs("STOPPF") && core.v60.pc == 32'h0006_2175)
            $fatal(1, "Spider-Man instruction boundary regressed to operand byte 0x62175");
    end
end

// Bounded Spider-Man boot-reentry diagnostic.  The first accepted write to
// 0x200000 is the normal cold-boot clear; a second one means software has
// re-entered that routine.  Preserve the preceding retired instruction
// boundaries so the re-entry producer can be compared with a read-only MAME
// tap without changing core behavior.
reg [31:0] spid_boot_pc [0:31];
reg  [7:0] spid_boot_op [0:31];
integer spid_boot_wr = 0;
integer spid_boot_pos = 0;
integer spid_boot_i;
reg [6:0] spid_boot_st_d = 0;
reg [6:0] spid_boot_ce_st_d = 0;
reg spid_boot_left_reset = 0;
reg [31:0] spid_boot_decode_pc_d = 0;
reg  [7:0] spid_boot_decode_op_d = 0;
reg  [6:0] spid_boot_decode_from_st_d = 0;
integer spid_boot_low_xfer = 0;
reg spid_boot_seq_on = 0;
integer spid_boot_seq = 0;
integer spid_boot_loop_read = 0;
always @(posedge clk_sys) begin
    spid_boot_st_d <= core.v60.st;
    if (core.v60.st != 0)
        spid_boot_left_reset <= 1'b1;
    if ($test$plusargs("SPIDBOOTTRACE") && spid_boot_left_reset &&
        core.v60.st == 0 && spid_boot_st_d != 0)
        $display("[spidreset] f=%0d prev_st=%0d pc=%08x rst=%b",
                 cur_frame, spid_boot_st_d, core.v60.pc, rst);
    if (core.v60.ce) begin
        if ($test$plusargs("SPIDBOOTTRACE") &&
            core.v60.st == S_DECODE_V && spid_boot_ce_st_d != S_DECODE_V) begin
            if ($test$plusargs("SPIDSEQTRACE") && spid_boot_seq_on &&
                spid_boot_seq < 200000) begin
                spid_boot_seq = spid_boot_seq + 1;
                $display("[spidseq] ordinal=%0d pc=%08x op=%02x",
                         spid_boot_seq, core.v60.pc, core.v60.opcode);
            end
            if (spid_boot_decode_pc_d >= 32'h0006_0000 &&
                core.v60.pc < 32'h0000_1000) begin
                spid_boot_low_xfer = spid_boot_low_xfer + 1;
                $display("[spidlow] ordinal=%0d prev_pc=%08x prev_op=%02x prev_from_st=%0d pc=%08x op=%02x from_st=%0d sp=%08x psw=%08x",
                         spid_boot_low_xfer,
                         spid_boot_decode_pc_d, spid_boot_decode_op_d,
                         spid_boot_decode_from_st_d, core.v60.pc,
                         core.v60.opcode, spid_boot_ce_st_d,
                         core.v60.r[31], core.v60.psw);
            end
            spid_boot_pc[spid_boot_pos & 31] <= core.v60.pc;
            spid_boot_op[spid_boot_pos & 31] <= core.v60.opcode;
            spid_boot_pos = spid_boot_pos + 1;
            spid_boot_decode_pc_d <= core.v60.pc;
            spid_boot_decode_op_d <= core.v60.opcode;
            spid_boot_decode_from_st_d <= spid_boot_ce_st_d;
        end
        spid_boot_ce_st_d <= core.v60.st;
    end
    if ($test$plusargs("SPIDBOOTTRACE") && core.m_req && core.m_ack &&
        core.m_we && !core.ack_d && core.m_be == 2'b11 &&
        {core.A[23:1], 1'b0} == 24'h200000) begin
        spid_boot_wr = spid_boot_wr + 1;
        if (spid_boot_wr == 1)
            spid_boot_seq_on <= 1'b1;
        $display("[spidclear] ordinal=%0d f=%0d pc=%08x sp=%08x sbr=%08x ie=%b irq_n=%b cnt=%b%b ppi=%02x rst=%b",
                 spid_boot_wr, cur_frame, core.v60.pc, core.v60.r[31],
                 core.v60.sbr, core.v60.psw_ie, core.irq_n,
                 core.io0_cnt1, core.io0_cnt2, core.ppi_q, rst);
        if (spid_boot_wr == 2)
            for (spid_boot_i = 0; spid_boot_i < 32; spid_boot_i = spid_boot_i + 1)
                $display("[spidhist] back=%0d pc=%08x op=%02x",
                         31-spid_boot_i,
                         spid_boot_pc[(spid_boot_pos + spid_boot_i) & 31],
                         spid_boot_op[(spid_boot_pos + spid_boot_i) & 31]);
    end
    if ($test$plusargs("SPIDBOOTTRACE") && core.v60.ce &&
        core.v60.st == S_RSR_V && core.v60.dack) begin
        $display("[spidrsr] pc=%08x sp=%08x pop=%08x pfbusy=%b pffast=%b fetchack=%b pfaddr=%08x epoch=%0d/%0d fbbase=%08x valid=%0d fb0=%02x",
                 core.v60.pc, core.v60.r[31], core.v60.bus_rdata,
                 core.v60.pf_busy, core.v60.pf_fast, core.v60.fetch_ack,
                 core.v60.pf_addr, core.v60.pf_epoch,
                 core.v60.pf_iss_epoch, core.v60.fb_base,
                 core.v60.fb_valid, core.v60.fb[0]);
    end
    if ($test$plusargs("SPIDBOOTTRACE") && core.m_req && core.m_ack &&
        !core.m_we && !core.ack_d && core.v60.pc == 32'h0008_9532) begin
        spid_boot_loop_read = spid_boot_loop_read + 1;
        $display("[spidloopread] ordinal=%0d f=%0d pc=%08x r0=%08x r2=%08x r12=%08x addr=%06x data=%04x be=%b do=%b es=%0d bit=%0d pd=%02x",
                 spid_boot_loop_read, cur_frame, core.v60.pc,
                 core.v60.r[0], core.v60.r[2], core.v60.r[12],
                 {core.A[23:1], 1'b0}, core.m_rdata, core.m_be,
                 core.eep_do, core.eeprom.es, core.eeprom.bitcnt,
                 core.io0_pd);
    end
end

reg [31:0] last_pc = 0;
integer same_pc = 0;
reg dumped = 0, resumed = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == last_pc) same_pc = same_pc + 1;
    else begin same_pc = 0; last_pc = core.v60.pc; end
    if (same_pc == 500000 && !dumped) begin
        dumped = 1;
        $display("[FROZEN] pc=%08x st=%0d cur_op=%02x subop=%02x cls=%0d",
            core.v60.pc, core.v60.st, core.v60.cur_op, core.v60.subop, core.v60.cls);
        $display("[FROZEN] str_cnt=%08x str_src=%08x str_dst=%08x bit_len=%08x",
            core.v60.str_cnt, core.v60.str_src, core.v60.str_dst, core.v60.bit_len);
        $display("[FROZEN] op1=%08x op2=%08x r0=%08x r1=%08x r3=%08x r26=%08x sp=%08x",
            core.v60.op1, core.v60.op2, core.v60.r[0], core.v60.r[1],
            core.v60.r[3], core.v60.r[26], core.v60.r[31]);
    end
    if (dumped && !resumed && same_pc == 0) begin
        resumed = 1;
        $display("[UNFROZEN] pc=%08x resumed after stuck-PC watchdog", core.v60.pc);
    end
end

// frame capture: with +DUMPAT=<frame#> (+DUMPN=<count>, default 1) write
// active-video pixels of those frames as PPM files (dump<frame>.ppm in cwd).
// +DUMP5 adds dump<frame>.rgb5.ppm, whose P6 samples are the native 5-bit
// channels before 8-bit presentation expansion; this is the canonical video
// comparison surface, while the 8-bit PPM remains diagnostic preview output.
integer dump_at, dump_n, dump_fd = 0, dump_x, dump_y, dump_every, live_every;
reg dumping = 0;
integer dump_nonblack = 0;
integer dump_frame = -1;
string live_ppm_path;
string live_ready_path;
string live_work_path;
reg live_ppm = 1'b0;
integer live_slot = 0, live_write_slot = 0, live_meta_fd = 0;
reg dump_complete = 0;
reg dump_nonblack_seen = 0;
reg require_verilator_screenshot = 0;
integer native5_fd = 0, native5_x = 0, native5_y = 0;
integer native5_nonblack = 0;
integer native5_frame = -1;
reg native5_enabled = 0, native5_only = 0, native5_dumping = 0;
reg native5_complete = 0, native5_nonblack_seen = 0;
reg require_verilator_native5 = 0;
initial require_verilator_screenshot = $test$plusargs("REQUIRE_VERILATOR_SCREENSHOT");
initial begin
    native5_enabled = $test$plusargs("DUMP5") || $test$plusargs("NATIVE5ONLY") ||
                       $test$plusargs("REQUIRE_VERILATOR_NATIVE5");
    native5_only = $test$plusargs("NATIVE5ONLY");
    require_verilator_native5 = $test$plusargs("REQUIRE_VERILATOR_NATIVE5");
end
initial begin
    if (!$value$plusargs("DUMPAT=%d", dump_at)) dump_at = -1;
    if (!$value$plusargs("DUMPN=%d", dump_n)) dump_n = 1;
    // +DUMPEVERY=<n>: dump every n-th frame (stride) — maps the attract cycle
    if (!$value$plusargs("DUMPEVERY=%d", dump_every)) dump_every = 1;
    if (!$value$plusargs("LIVEEVERY=%d", live_every)) live_every = 1;
    if (live_every < 1) $fatal(1, "LIVEEVERY must be >= 1");
    if (!$value$plusargs("LIVEPPM=%s", live_ppm_path)) live_ppm_path = "";
    live_ppm = (live_ppm_path != "");
    if (live_ppm) live_ready_path = {live_ppm_path, ".ready"};
end

// +DUMPSPRAT=<frame>: dump the V60-written sprite command RAM (0x400000, the
// display list) to sim_spriteram.hex so it can be diffed against MAME's list.
integer sprdump_at, sprdump_at2, sprdump_fd, sprdump_i;
reg vb_d2 = 0, sprdump_done = 0, sprdump2_wdone = 0;
integer sprdump_last = -1;
integer wdump_fd;
reg wdone250 = 0, wdone400 = 0, wdone500 = 0;
initial begin
    if (!$value$plusargs("DUMPSPRAT=%d", sprdump_at)) sprdump_at = -1;
    if (!$value$plusargs("DUMPSPRAT2=%d", sprdump_at2)) sprdump_at2 = -1;
end
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
    if (sprdump_at2 >= 0 && sprdump_cur >= sprdump_at2 && sprdump_cur <= sprdump_at2+2
        && core.vcnt == 9'd150 && sprdump_last != sprdump_cur) begin
        sprdump_last = sprdump_cur;
        sprdump_fd = $fopen($sformatf("sim_spr_%0d.hex", sprdump_cur), "w");
        for (sprdump_i = 0; sprdump_i < 65536; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.sprite_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[sprdump] wrote sim_spr_%0d.hex", sprdump_cur);
    end
    if (sprdump_at2 >= 0 && sprdump_cur == sprdump_at2 && !sprdump2_wdone
        && core.vcnt == 9'd150) begin
        sprdump2_wdone = 1'b1;
        sprdump_fd = $fopen($sformatf("sim_wram_%0d.hex", sprdump_cur), "w");
        for (sprdump_i = 0; sprdump_i < 16'h8000; sprdump_i = sprdump_i + 1)
            $fwrite(sprdump_fd, "%04x\n", core.work_ram.mem[sprdump_i]);
        $fclose(sprdump_fd);
        $display("[wramdump] wrote second synchronized work-RAM snapshot");
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
// +QUEUETRACE=1: accepted V60 work-RAM reads/writes around the GA2 vblank
// queue (0x20b120..0x20b180, word indices 0x5890..0x58c0).  Diagnostic only.
integer queue_trace;
initial if (!$value$plusargs("QUEUETRACE=%d", queue_trace)) queue_trace = 0;
integer obj8_fd = 0;
initial obj8_fd = $fopen("sim_obj8_writes.txt", "w");
integer arab_obj_fd = 0;
initial arab_obj_fd = $fopen("arab_player_object_writes.txt", "w");
always @(posedge clk_sys) begin
    if (sprdump_cur >= 1550 && sprdump_cur <= 1680 &&
        core.v60.pc == 32'h00ff7351) begin
        $fwrite(arab_obj_fd,
            "PHYS frame=%0d out=%04x p30=%08x p34=%08x p7a=%08x a=%04x c=%04x c2=%04x ba=%04x scale=%04x r24=%08x\n",
            sprdump_cur, core.work_ram.mem[16'h0304],
            {core.work_ram.mem[16'h030d], core.work_ram.mem[16'h030c]},
            {core.work_ram.mem[16'h030f], core.work_ram.mem[16'h030e]},
            {core.work_ram.mem[16'h0332], core.work_ram.mem[16'h0331]},
            core.work_ram.mem[16'h02f9], core.work_ram.mem[16'h02fa],
            core.work_ram.mem[16'h0355], core.work_ram.mem[16'h0351],
            core.work_ram.mem[16'h4253], core.v60.r[24]);
        $fflush(arab_obj_fd);
    end
    if (sprdump_cur >= 1550 && sprdump_cur <= 1680 &&
        core.m_req && core.m_we && core.sel_wram &&
        core.wram_a >= 16'h02f4 && core.wram_a <= 16'h0307) begin
        $fwrite(arab_obj_fd, "frame=%0d pc=%08x wa=%04x data=%04x be=%b r24=%08x\n",
            sprdump_cur, core.v60.pc, core.wram_a, core.m_wdata, core.m_be,
            core.v60.r[24]);
        $fflush(arab_obj_fd);
    end
    if (core.m_req && core.m_we && core.sel_wram &&
        core.wram_a >= 16'h02d0 && core.wram_a <= 16'h02d7) begin
        $fwrite(obj8_fd, "frame=%0d pc=%08x wa=%04x data=%04x be=%b\n",
            sprdump_cur, core.v60.pc, core.wram_a, core.m_wdata, core.m_be);
        $fflush(obj8_fd);
    end
    if (queue_trace && core.m_req && core.sel_wram &&
        core.wram_a >= 16'h5890 && core.wram_a <= 16'h58c0) begin
        $display("[queue] f=%0d %s pc=%08x wa=%04x data=%04x be=%b",
            cur_frame, core.m_we ? "W" : "R", core.v60.pc, core.wram_a,
            core.m_we ? core.m_wdata : core.m_rdata, core.m_be);
    end
end

// +LOFF=<hex>: force tm_layer_off to isolate which layer draws the arabfgt
// select "swirl". bits {5:BITMAP,4:NBG3,3:NBG2,2:NBG1,1:NBG0,0:TEXT} (1=off).
integer loff_force;
`ifndef S32_EXTERNAL_CLOCKS
always @(posedge clk_sys) if ($value$plusargs("LOFF=%h", loff_force))
    force core.tilemap.r1ff8e = {10'b0, loff_force[5:0]};
`endif

// +REGTRACE: log every CPU write to $1FF00 (word 0xff80) and $1FF02 (0xff81)
// with frame + value, to see if/when the game disables the bitmap (r1ff02[5]).
integer regtrace;
initial if (!$value$plusargs("REGTRACE=%d", regtrace)) regtrace = 0;
always @(posedge clk_ram) if (regtrace &&
        core.vram.cpu_we && (core.vram.cpu_addr == 16'hff80 || core.vram.cpu_addr == 16'hff81))
    $display("[regw] f=%0d addr=%04x data=%04x be=%b pc=%08x -> r1ff%02x",
        cur_frame, core.vram.cpu_addr, core.vram.cpu_wdata, core.vram.cpu_be,
        core.v60.pc,
        (core.vram.cpu_addr[0] ? 8'h02 : 8'h00));
reg vb_d, hb_d;
// +SPRLOG=1: per-frame sprite-render telemetry (pixels written, FSM state at
// frame boundary = did the render finish?, and the displayed buffer). Diagnoses
// the arabfgt period-2 sprite flicker (render truncation / buffer divergence).
integer sprlog;
initial if (!$value$plusargs("SPRLOG=%d", sprlog)) sprlog = 0;
// +TMLOG=1: per-frame tile renderer progress.  Rad Mobile reaches the
// display-enabled loop before its background is visible; keep this probe
// separate from the normal frame report so the broad regression stays quiet.
integer tmlog;
initial if (!$value$plusargs("TMLOG=%d", tmlog)) tmlog = 0;
integer tm_req_cnt = 0, tm_lb_cnt = 0, tm_opaque_cnt = 0;
always @(posedge clk_ram) begin
    if (core.sdr_p1_req) tm_req_cnt = tm_req_cnt + 1;
    if (core.tm_lb_we) begin
        tm_lb_cnt = tm_lb_cnt + 1;
        if (core.tm_lb_pix[13]) tm_opaque_cnt = tm_opaque_cnt + 1;
    end
end
reg [31:0] spr_px_cnt, spr_px_latch;
reg [31:0] spr_draw_seen;            // fb_wr_start pulses this frame (# runs)
integer arab_heavy_at, arab_heavy_n, arab_heavy_min;
integer arab_heavy_samples = 0, arab_heavy_count = 0;
reg arab_heavy_done = 0;
initial begin
    if (!$value$plusargs("ARABHEAVYAT=%d", arab_heavy_at)) arab_heavy_at = -1;
    if (!$value$plusargs("ARABHEAVYN=%d", arab_heavy_n)) arab_heavy_n = 6;
    if (!$value$plusargs("ARABHEAVYMIN=%d", arab_heavy_min)) arab_heavy_min = 3;
end
always @(posedge clk_ram) begin
    if (core.sprite.fb_wr_valid) spr_px_cnt <= spr_px_cnt + 1'd1;
    if (core.sprite.fb_wr_start) spr_draw_seen <= spr_draw_seen + 1'd1;
end
// Scoped, one-off diagnostic for palette write-both
// investigation: n_pal_wr/n_vram_wr are running totals (never reset), so
// print their per-frame delta alongside mixer $4E only across the narrow
// window the level-load burst falls in.  Safe to leave in: dead weight
// outside that frame range, and the harness has no other +BURSTLOG use.
integer burst_pal_prev = 0, burst_vram_prev = 0;
always @(posedge clk_sys) begin
    vb_d <= vb;
    if (vb & ~vb_d) begin              // end of visible field
        cur_frame = cur_frame + 1;
        if ($test$plusargs("BURSTLOG") && cur_frame >= 940 && cur_frame <= 965) begin
            $display("[burst] f=%0d dpal=%0d dvram=%0d mreg27=%04x",
                cur_frame, n_pal_wr - burst_pal_prev, n_vram_wr - burst_vram_prev,
                core.mix0.mreg[6'h27]);
            burst_pal_prev = n_pal_wr;
            burst_vram_prev = n_vram_wr;
        end
        // +SPRLOG: sprite render telemetry. rs = FSM state at frame boundary
        // (0=R_IDLE means render finished; 5..23 = still walking list = overran).
        if (sprlog) $display("[spr] f=%0d disp_buf=%0d rs=%0d px=%0d runs=%0d",
            cur_frame, core.sprite.disp_buf, core.sprite.rs, spr_px_cnt, spr_draw_seen);
        if (tmlog) $display("[tm] f=%0d req=%0d lb=%0d opaque=%0d tst=%0d lay=%0d x=%0d name=%04x row=%016x addr=%05x off=%02x",
            cur_frame, tm_req_cnt, tm_lb_cnt, tm_opaque_cnt,
            core.tilemap.tst, core.tilemap.lay, core.tilemap.x,
            core.tilemap.name, core.tilemap.row, core.tilemap.tile_addr,
            core.tm_layer_off);
        if (arab_heavy_at >= 0 && cur_frame >= arab_heavy_at &&
            cur_frame < arab_heavy_at + arab_heavy_n) begin
            arab_heavy_samples = arab_heavy_samples + 1;
            if (spr_draw_seen >= 1400) arab_heavy_count = arab_heavy_count + 1;
            $display("[arab-heavy] f=%0d runs=%0d heavy=%0d count=%0d",
                cur_frame, spr_draw_seen, spr_draw_seen >= 1400,
                arab_heavy_count);
            if (cur_frame == arab_heavy_at + arab_heavy_n - 1) begin
                arab_heavy_done = 1'b1;
                if (arab_heavy_count < arab_heavy_min)
                    $fatal(1, "ARABIAN FIGHT HEAVY FAIL: only %0d/%0d fields reached 1400 runs (need %0d)",
                        arab_heavy_count, arab_heavy_samples, arab_heavy_min);
                else
                    $display("ARABIAN FIGHT HEAVY PASS: %0d/%0d fields reached 1400 runs (need %0d)",
                        arab_heavy_count, arab_heavy_samples, arab_heavy_min);
            end
        end
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
            if (live_ppm) begin
                // Publish only after the completed file is closed. The
                // double-buffered paths let the viewer consume the previous
                // frame while the simulator writes the next one.
                live_meta_fd = $fopen(live_ready_path, "w");
                if (live_meta_fd != 0) begin
                    $fwrite(live_meta_fd, "%0d %0d\n", cur_frame - 1, live_write_slot);
                    $fclose(live_meta_fd);
                end
                live_slot = live_slot ^ 1;
            end
            dumping = 0;
            dump_complete = 1'b1;
            if (dump_nonblack != 0) dump_nonblack_seen = 1'b1;
            $display("[dump] wrote frame %0d nonblack=%0d", cur_frame-1, dump_nonblack);
        end
        if ((live_ppm && (cur_frame % live_every == 0)) ||
            (dump_at >= 0 && cur_frame >= dump_at &&
            ((cur_frame - dump_at) % dump_every == 0) &&
            ((cur_frame - dump_at) / dump_every < dump_n))) begin
            if (live_ppm) begin
                live_write_slot = live_slot;
                live_work_path = $sformatf("%0s.%0d", live_ppm_path, live_write_slot);
                dump_fd = $fopen(live_work_path, "w");
            end
            else
                dump_fd = $fopen($sformatf("dump%0d.ppm", cur_frame), "w");
            if (dump_fd == 0)
                $fatal(1, "VERILATOR SCREENSHOT FAIL: cannot create live/frame PPM at frame %0d", cur_frame);
            // 52*8=416 wide, 224 high fixed header (PPM allows trailing slack)
            $fwrite(dump_fd, "P3\n416 224\n255\n");
            // Every capture owns a fresh raster cursor.  Without these resets,
            // dump_y remains 224 after the first file and later multi-frame
            // captures contain only a PPM header while still reporting done.
            dump_x = 0;
            dump_y = 0;
            dump_nonblack = 0;
            dump_complete = 1'b0;
            dumping = 1;
            dump_frame = cur_frame;
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
            $fwrite(dump_fd, "%0d %0d %0d\n", rgb_a[23:16], rgb_a[15:8], rgb_a[7:0]);
            if (rgb_a != 24'h000000) dump_nonblack = dump_nonblack + 1;
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
    if (cur_frame >= tr_at && core.v60.st == S_DECODE_V && core.v60.pc >= tr_lo &&
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
wire obj_dbgpc_range = ((core.v60.pc >= 32'h00130600 && core.v60.pc < 32'h00130680) ||
                        (core.v60.pc >= 32'h00132900 && core.v60.pc < 32'h001329b0));
always @(posedge clk_sys) if (ce_cpu) begin
    if (obj_tr_at >= 0 && cur_frame >= obj_tr_at && obj_pc_range &&
        core.v60.st == S_DECODE_V && obj_i_n < obj_tr_max) begin
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
                cur_frame, core.v60.pc, core.A[23:0], core.m_wdata, core.m_be);
        else
            $display("[objbus] f=%0d pc=%08x R [%06x] data=%04x be=%b",
                cur_frame, core.v60.pc, core.A[23:0], core.m_rdata, core.m_be);
    end
end

// io-chip write log + EEPROM pin trace (holo boot loop diagnosis)
integer io_log_n = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        core.A[23:16] == 8'hC0 && io_log_n < 120) begin
        io_log_n = io_log_n + 1;
        if (!quiet)
            $display("[io] pc=%08x wr [%06x] = %04x be=%b",
                core.v60.pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
    end
end

// +SPIDEEP: accepted 315-5296 port-D transfers with the serial EEPROM state.
// Observation-only; used to align Spider-Man's boot EEPROM transaction with
// the pinned MAME port trace.
integer spideep_n = 0;
always @(posedge clk_sys) begin
    if ($test$plusargs("SPIDEEP") && core.m_req && core.m_ack && !core.ack_d &&
        (core.A[23:0] == 24'hc00006 || core.A[23:0] == 24'hc0000a) &&
        spideep_n < 256) begin
        spideep_n = spideep_n + 1;
        $display("[spideep] n=%0d f=%0d pc=%08x rw=%s data=%04x be=%b pd=%02x cs/sk/di=%b%b%b do=%b es=%0d bit=%0d skd=%b",
            spideep_n, cur_frame, core.v60.pc, core.m_we ? "W" : "R",
            core.m_we ? core.m_wdata : core.m_rdata, core.m_be, core.io0_pd,
            core.io0_pd[5], core.io0_pd[6], core.io0_pd[7], core.eep_do,
            core.eeprom.es, core.eeprom.bitcnt, core.eeprom.sk_d);
    end
end
// intc write log: what vectors/mask does the game program?
integer intc_log_n = 0;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        core.A[23:16] == 8'hD0 && intc_log_n < 40) begin
        intc_log_n = intc_log_n + 1;
        if (!quiet)
            $display("[intc] pc=%08x wr [%06x] = %04x be=%b",
                core.v60.pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
    end
end

// log LDPR executions: which privileged register gets which value?
integer ldpr_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.st == S_EXEC_V && core.v60.cur_op == 8'h12 && ldpr_n < 16) begin
        ldpr_n = ldpr_n + 1;
        if (!quiet)
            $display("[ldpr] pc=%08x op1=%08x op2=%08x", core.v60.pc, core.v60.op1, core.v60.op2);
    end
end

// privileged-register visibility: log every SBR change (LDPR target check)
reg [31:0] sbr_prev = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.sbr != sbr_prev) begin
        if (!quiet)
            $display("[sbr] pc=%08x sbr %08x -> %08x", core.v60.pc, sbr_prev, core.v60.sbr);
        sbr_prev = core.v60.sbr;
    end
end

// IRQ/exception entry detail: vector, base register, stack, fetched handler
integer exc_log_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.st == S_EXC_VEC_V && core.v60.bus_req && core.v60.bus_ack &&
        exc_log_n < 12) begin
        exc_log_n = exc_log_n + 1;
        if (!quiet)
            $display("[exc] vec=%02x sbr=%08x sp=%08x retpc=%08x handler=[%08x]=%08x cur_op=%02x bus=%b/%b addr=%08x rdata=%08x cdata=%08x m=%b/%b/%04x",
                core.v60.exc_vector, core.v60.sbr, core.v60.r[31], core.v60.exc_retpc,
                (core.v60.sbr & ~32'hfff) + {22'b0, core.v60.exc_vector, 2'b00},
                core.v60.bus_rdata, core.v60.cur_op, core.v60.bus_req,
                core.v60.bus_ack, core.v60.bus_addr, core.v60.bus_rdata,
                core.c_rdata, core.m_req, core.m_ack, core.m_rdata);
    end
end

// derail trap: PC escaping the 24-bit bus space is always a wrong jump.
// Gate on !rst and on having booted into real code first: the V60 reset vector
// is 0xFFFFFFF0 (top byte 0xFF), which a 2-state simulator (Verilator) would
// otherwise flag as a derail during reset.  ModelSim's X-pessimism hid this.
reg derailed = 0;
reg booted = 0;
always @(posedge clk_sys) if (ce_cpu && !rst) begin
    // Raw pc is still zero on the first post-reset CE before the V60 loads its
    // architectural reset vector.  Do not arm on that transient: the first
    // real System 32 instruction must be fetched from the top 1 MiB ROM.
    if (core.v60.pc >= 32'h00f0_0000 && core.v60.pc <= 32'h00ff_ffff)
        booted <= 1'b1;
    if (booted && !derailed && core.v60.pc[31:24] != 8'h00) begin
        derailed = 1;
        $display("[DERAIL] pc=%08x sp=%08x sbr=%08x psw=%08x", core.v60.pc,
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
    if (core.v60.pc != prev_pc) begin
        if ((core.v60.pc > prev_pc + 24) || (core.v60.pc < prev_pc)) begin
            jt_from[jt_n % 48] <= prev_pc;
            jt_to[jt_n % 48]   <= core.v60.pc;
            jt_n = jt_n + 1;
        end
        prev_pc <= core.v60.pc;
    end
end

// watch one word address: log every write (who sets the polled flag?)
integer watch_a;
initial if (!$value$plusargs("WATCH=%h", watch_a)) watch_a = -1;
always @(posedge clk_sys) begin
    if (core.m_req && core.m_ack && core.m_we && !core.ack_d &&
        {core.A[23:1],1'b0} == watch_a[23:0])
        $display("[watch] pc=%08x wr [%06x] = %04x be=%b",
            core.v60.pc, {core.A[23:1],1'b0}, core.m_wdata, core.m_be);
end

// DIAGNOSTIC (radm/radr goal): find the caller of 0x070dca (the object-walk
// entry reached right after the 511-iter clear loop returns) by reading the
// stack the moment it's entered, same technique as before -- to trace one
// level further up the call chain toward whatever never reaches 0x070492.
integer callerstack2_n = 0;
reg [31:0] callerstack2_prev_pc = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h070dca && callerstack2_prev_pc != 32'h070dca && callerstack2_n < 20) begin
        $display("[callerstack2] f=%0d pc=070dca sp=%08x ret_hi=%04x ret_lo=%04x",
            cur_frame, core.v60.r[31],
            core.work_ram.mem[core.v60.r[31][15:1] + 1],
            core.work_ram.mem[core.v60.r[31][15:1]]);
        callerstack2_n = callerstack2_n + 1;
    end
    callerstack2_prev_pc <= core.v60.pc;
end

// DIAGNOSTIC (radm/radr goal): the REAL master init sequence at ROM 0x0661c0
// calls 7f8c0,67ee5,7f6df,66256,67c10,67cc8,71092,7046e,705cd,6814a,70dc4,
// 75fa7,702aa(x3),... -- supersedes the earlier (wrong) assumption that
// 0x070492 was next after 0x0705cd. Bisect these instead.
localparam int NUM_BISECT2 = 8;
localparam logic [31:0] BISECT2_ADDR [0:NUM_BISECT2-1] = '{
    32'h07f8c0, 32'h067ee5, 32'h07f6df, 32'h06814a, 32'h070dc4,
    32'h075fa7, 32'h0702aa, 32'h066217
};
reg bisect2_seen [0:NUM_BISECT2-1];
initial for (int bj = 0; bj < NUM_BISECT2; bj++) bisect2_seen[bj] = 1'b0;
always @(posedge clk_sys) if (ce_cpu) begin
    for (int bj = 0; bj < NUM_BISECT2; bj++) begin
        if (!bisect2_seen[bj] && core.v60.pc == BISECT2_ADDR[bj]) begin
            bisect2_seen[bj] <= 1'b1;
            $display("[bisect2] f=%0d REACHED pc=%08x", cur_frame, BISECT2_ADDR[bj]);
        end
    end
end

// DIAGNOSTIC (radm/radr goal): 0x066253 is an indirect jsr through a 4-entry
// jump table indexed by work-RAM 0x20f515 & 3 (0x066245-24d). Log the index,
// the resolved target, and whether/where it lands, to see if this is where
// progress actually stops after the (now-confirmed-complete) 0x0661c0 init
// chain.
integer jt515_n = 0;
reg [31:0] jt515_prev_pc = 0;
reg jt515_armed = 1'b0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h066253 && jt515_prev_pc != 32'h066253 && jt515_n < 20) begin
        $display("[jt515] f=%0d AT pc=066253 r0=%08x", cur_frame, core.v60.r[0]);
        jt515_armed <= 1'b1;
        jt515_n = jt515_n + 1;
    end
    else if (jt515_armed && core.v60.pc != jt515_prev_pc) begin
        $display("[jt515] f=%0d LANDED pc=%08x", cur_frame, core.v60.pc);
        jt515_armed <= 1'b0;
    end
    jt515_prev_pc <= core.v60.pc;
end

// DIAGNOSTIC (radm/radr goal): the outer retry loop at 0x068205-068243 has
// several branch targets (68279, 682a0, 68236->681f6 loop-back, 068243
// fall-through-to-success). Bisect all of them plus a few instructions
// downstream of the "success" path to see which one the RTL actually takes,
// and whether it ever reaches the success path at all.
localparam int NUM_BISECT3 = 9;
localparam logic [31:0] BISECT3_ADDR [0:NUM_BISECT3-1] = '{
    32'h068217, 32'h068236, 32'h068243, 32'h068279, 32'h0682a0, 32'h068251,
    32'h068219, 32'h0707f4, 32'h070a6b
};
reg bisect3_seen [0:NUM_BISECT3-1];
initial for (int bk = 0; bk < NUM_BISECT3; bk++) bisect3_seen[bk] = 1'b0;
always @(posedge clk_sys) if (ce_cpu) begin
    for (int bk = 0; bk < NUM_BISECT3; bk++) begin
        if (!bisect3_seen[bk] && core.v60.pc == BISECT3_ADDR[bk]) begin
            bisect3_seen[bk] <= 1'b1;
            $display("[bisect3] f=%0d REACHED pc=%08x", cur_frame, BISECT3_ADDR[bk]);
        end
    end
end

// DIAGNOSTIC (radm/radr goal): count total (not one-shot) visits to the
// retry-loop re-entry point 0x068236, printing every 200th, to see the
// long-run retry rate and whether it ever reaches the success path 0x068243
// (also counted) instead.
integer retrycnt_236 = 0;
integer retrycnt_243 = 0;
reg [31:0] retry_prev_pc = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h068236 && retry_prev_pc != 32'h068236) begin
        retrycnt_236 = retrycnt_236 + 1;
        if (retrycnt_236 % 200 == 1)
            $display("[retrycnt] f=%0d visits236=%0d visits243=%0d", cur_frame, retrycnt_236, retrycnt_243);
    end
    if (core.v60.pc == 32'h068243 && retry_prev_pc != 32'h068243) begin
        retrycnt_243 = retrycnt_243 + 1;
        $display("[retrycnt] f=%0d SUCCESS pc=068243 count=%0d", cur_frame, retrycnt_243);
    end
    retry_prev_pc <= core.v60.pc;
end

// DIAGNOSTIC (radm/radr goal): the table-gen write at 0x067faa
// ("mov.h R0,[R11+]") stores a byte-swapped value (0x5345 vs MAME's
// 0x4553) into work-RAM 0x20f500. Capture R0's value the instant PC
// reaches 0x067fa8 (the instruction immediately before the write) to see
// whether R0 itself is already wrong (ALU/register bug upstream) or only
// the write to memory swaps it (bus/write-path bug).
integer r0check_n = 0;
reg [31:0] r0check_prev_pc = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h067fa8 && r0check_prev_pc != 32'h067fa8 && r0check_n < 5) begin
        $display("[r0check] f=%0d pc=067fa8 r0=%08x r11=%08x", cur_frame, core.v60.r[0], core.v60.r[11]);
        r0check_n = r0check_n + 1;
    end
    r0check_prev_pc <= core.v60.pc;
end

// DIAGNOSTIC: has the CPU ever reached a specific PC, and with which registers?
// docs/radm-radr-bringup.md: confirm/deny whether radm's demo-object
// allocator (MAME PC 0x070dbc/0x070dfc, first hit at MAME frame 897) ever
// executes in the RTL.
integer pcwatch_a;
integer pcwatch_n = 0;
integer pcwatch_max;
initial if (!$value$plusargs("PCWATCH=%h", pcwatch_a)) pcwatch_a = -1;
initial if (!$value$plusargs("PCWATCHMAX=%d", pcwatch_max)) pcwatch_max = 20;
integer pcwatch_last_frame = -1;
always @(posedge clk_sys) if (ce_cpu) begin
    if (pcwatch_a >= 0 && core.v60.pc == pcwatch_a[31:0] &&
        cur_frame != pcwatch_last_frame && pcwatch_n < pcwatch_max) begin
        $display("[pcwatch] HIT f=%0d pc=%08x r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r25=%08x",
            cur_frame, core.v60.pc, core.v60.r[0], core.v60.r[1], core.v60.r[2],
            core.v60.r[3], core.v60.r[4], core.v60.r[5], core.v60.r[25]);
        pcwatch_n = pcwatch_n + 1;
        pcwatch_last_frame = cur_frame;
    end
end

// DIAGNOSTIC (radm/radr goal): does the V60 ever actually take an interrupt?
// Logs psw_ie's first 0->1 edge and every irq_n toggle, bounded by IRQPROBE.
integer irqprobe_max;
initial if (!$value$plusargs("IRQPROBE=%d", irqprobe_max)) irqprobe_max = 0;
integer irqprobe_n = 0;
reg irq_n_d = 1'b1;
reg psw_ie_d = 1'b0;
reg psw_ie_seen = 1'b0;
reg exc_is_interrupt_d = 1'b0;
always @(posedge clk_sys) begin
    if (irqprobe_max > 0 && irqprobe_n < irqprobe_max) begin
        irq_n_d  <= core.irq_n;
        psw_ie_d <= core.v60.psw_ie;
        if (core.irq_n !== irq_n_d) begin
            $display("[irqp] f=%0d pc=%08x irq_n: %b->%b psw_ie=%b vec=%02x st=%0d",
                cur_frame, core.v60.pc, irq_n_d, core.irq_n, core.v60.psw_ie,
                core.irq_vector, core.v60.st);
            irqprobe_n = irqprobe_n + 1;
        end
        if (core.v60.psw_ie && !psw_ie_seen) begin
            psw_ie_seen <= 1'b1;
            $display("[irqp] f=%0d pc=%08x psw_ie first-set irq_n=%b",
                cur_frame, core.v60.pc, core.irq_n);
            irqprobe_n = irqprobe_n + 1;
        end
        if (core.v60.exc_is_interrupt && !exc_is_interrupt_d) begin
            $display("[irqp] f=%0d pc=%08x ENTERING EXC/IRQ frame vec=%02x",
                cur_frame, core.v60.pc, core.v60.exc_vector);
            irqprobe_n = irqprobe_n + 1;
        end
        exc_is_interrupt_d <= core.v60.exc_is_interrupt;
    end
end

// Diagnostic-only exception-vector bus probe.  This does not alter the core;
// it records the exact vector address/data presented by the real V60 bus.
integer veclog_max;
initial if (!$value$plusargs("VECLOG=%d", veclog_max)) veclog_max = 0;
integer veclog_n = 0;
always @(posedge clk_sys) begin
    if (veclog_max > 0 && veclog_n < veclog_max &&
        core.v60.st == S_EXC_VEC_V && core.v60.bus_req && core.v60.bus_ack) begin
        $display("[veclog] f=%0d pc=%08x addr=%08x size=%0d req=%b ack=%b rdata=%08x",
            cur_frame, core.v60.pc, core.v60.bus_addr, core.v60.bus_size,
            core.v60.bus_req, core.v60.bus_ack, core.v60.bus_rdata);
        veclog_n = veclog_n + 1;
    end
end

// Diagnostic-only handler operand probe for the first causal GA2 IRQ write.
integer hlog_max;
initial if (!$value$plusargs("HLOG=%d", hlog_max)) hlog_max = 0;
integer hlog_n = 0;
always @(posedge clk_sys) begin
    if (hlog_max > 0 && hlog_n < hlog_max &&
        (core.v60.pc == 32'h001006e2 || core.v60.pc == 32'h001006ec) &&
        (core.m_req || core.A == 24'hc0001c)) begin
        $display("[hlog] f=%0d pc=%08x st=%0d r25=%08x A=%06x req=%b we=%b ack=%b mrd=%04x mwd=%04x",
            cur_frame, core.v60.pc, core.v60.st, core.v60.r[25],
            core.A, core.m_req, core.m_we, core.m_ack, core.m_rdata, core.m_wdata);
        hlog_n = hlog_n + 1;
    end
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
            cur_frame, core.v60.pc, {core.A[23:1],1'b0}, core.m_wdata,
            core.m_be, core.v60.cur_op, core.v60.st);
    end
end

// Diagnostic-only proof that an accepted CPU VRAM write reaches the backing
// dual-port RAM with the requested byte lanes.  This is deliberately generic:
// it can distinguish a CPU/write-path fault from a renderer fault without
// introducing game-specific production behaviour.  The check is delayed one
// clock so the RAM's nonblocking write has committed before it is inspected.
integer vramverify_first, vramverify_last, vramverify_n = 0;
reg        vramverify_pending = 1'b0;
reg [15:0] vramverify_addr;
reg [15:0] vramverify_expect;
reg [31:0] vramverify_pc;
initial begin
    if (!$value$plusargs("VRAMVERIFYFIRST=%d", vramverify_first))
        vramverify_first = 0;
    if (!$value$plusargs("VRAMVERIFYLAST=%d", vramverify_last))
        vramverify_last = 32'h7fff_ffff;
end
always @(posedge clk_sys) begin : vram_backing_verify
    reg [15:0] old_word;
    if ($test$plusargs("VRAMVERIFY")) begin
        if (vramverify_pending) begin
            if (core.vram.video_ram.mem[vramverify_addr] !== vramverify_expect) begin
                $display("[vramverify] FAIL f=%0d pc=%08x a=%04x expect=%04x got=%04x",
                    cur_frame, vramverify_pc, vramverify_addr, vramverify_expect,
                    core.vram.video_ram.mem[vramverify_addr]);
                $fatal(1, "accepted VRAM write did not reach backing RAM");
            end
            vramverify_n = vramverify_n + 1;
        end
        vramverify_pending <= 1'b0;
        if (cur_frame >= vramverify_first && cur_frame <= vramverify_last &&
            core.vram.cpu_we) begin
            old_word = core.vram.video_ram.mem[core.vram.cpu_addr];
            vramverify_addr <= core.vram.cpu_addr;
            vramverify_expect <= {
                core.vram.cpu_be[1] ? core.vram.cpu_wdata[15:8] : old_word[15:8],
                core.vram.cpu_be[0] ? core.vram.cpu_wdata[7:0]  : old_word[7:0]
            };
            vramverify_pc <= core.v60.pc;
            vramverify_pending <= 1'b1;
        end
    end
end

// +RADMPC: compact instruction-path trace around Rad Mobile's frame wait and
// state-table dispatcher.  Emit only PC changes so a short comparison remains
// readable; this is inert for normal regressions and all other games.
reg [31:0] radm_pc_prev = 32'hffff_ffff;
always @(posedge clk_sys) begin
    if ($test$plusargs("RADMPC") && ce_cpu &&
        core.v60.pc != radm_pc_prev &&
        ((core.v60.pc >= 32'h0006_6080 &&
          core.v60.pc <  32'h0006_6230) ||
         (core.v60.pc >= 32'h0007_0270 &&
          core.v60.pc <  32'h0007_02b0))) begin
        $display("[radmpc] f=%0d pc=%08x op=%02x st=%0d r0=%08x r25=%08x f007=%02x",
            cur_frame, core.v60.pc, core.v60.cur_op, core.v60.st,
            core.v60.r[0], core.v60.r[25],
            core.work_ram.mem[16'h7803][15:8]);
        radm_pc_prev <= core.v60.pc;
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
            cur_frame, core.v60.pc, {core.A[23:1],1'b0}, core.m_wdata,
            core.m_be, core.v60.r[0], core.v60.r[1], core.v60.r[26]);
    end
end

// bus-hang detector: a request that never acks is a core deadlock
integer hang_cnt = 0;
always @(posedge clk_sys) begin
    if (core.m_req && !core.m_ack) begin
        hang_cnt = hang_cnt + 1;
        if (hang_cnt == 20000)
`ifdef S32_UNIVERSAL
            $display("[HANG] pc=%08x A=%06x we=%b be=%b st=%0d p0req=%b",
                core.v60.pc, {core.A[23:1],1'b0}, core.m_we, core.m_be,
                core.v60.st, p0_req);
`else
            $display("[HANG] pc=%08x A=%06x we=%b be=%b st=%0d p0req=%b",
                core.v60.pc, {core.A[23:1],1'b0}, core.m_we, core.m_be,
                core.v60.st, p0_req);
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
            cur_frame, core.v60.pc, core.A[23:0], core.m_wdata,
            core.m_be, core.v60.r[0], core.v60.r[1], core.v60.r[2],
            core.v60.r[3], core.v60.r[4], core.v60.r[5]);
    end
end

// Optional V25/MB8421 transaction trace.  +PROTLOG=<n> logs at most n
// accepted V60 accesses in 0xA00000-0xA00FFF; +PROTSKIP=<n> skips the first
// n accesses.  This is intentionally harness-only: it exposes whether the
// game merely reads the fixed bootstrap table, or later submits mailbox
// commands which require the real V25 to modify DPRAM asynchronously.
integer rom_log_max = 0, rom_log_n = 0;
integer vec_log_max = 0, vec_log_n = 0;
reg p0_req_d = 1'b0, p0_ack_d = 1'b0;
initial if (!$value$plusargs("ROMLOG=%d", rom_log_max)) rom_log_max = 0;
initial if (!$value$plusargs("VECLOG=%d", vec_log_max)) vec_log_max = 0;
always @(posedge clk_sys) begin
    p0_req_d <= p0_req;
    p0_ack_d <= p0_ack;
    if (rom_log_max > 0 && p0_req && !p0_req_d && rom_log_n < rom_log_max) begin
        rom_log_n = rom_log_n + 1;
        $display("[rom-p0-req] n=%0d a=%06x", rom_log_n, p0_addr);
    end
    if (rom_log_max > 0 && p0_ack && !p0_ack_d && rom_log_n < rom_log_max) begin
        rom_log_n = rom_log_n + 1;
        $display("[rom-p0-ack] n=%0d a=%06x d=%016x", rom_log_n, p0_addr, p0_dout);
    end
    if (rom_log_max > 0 && core.m_req && core.m_ack && !core.m_we &&
        core.A[23:20] == 4'hf && rom_log_n < rom_log_max) begin
        rom_log_n = rom_log_n + 1;
        $display("[rom-cpu-rd] n=%0d pc=%08x a=%06x d=%04x", rom_log_n,
            core.v60.pc, core.A, core.m_rdata);
    end
    if (vec_log_max > 0 && p0_req && !p0_req_d &&
        p0_addr[20:1] == 20'h7f880 && vec_log_n < vec_log_max) begin
        vec_log_n = vec_log_n + 1;
        $display("[vec-p0-req] n=%0d a=%06x", vec_log_n, p0_addr);
    end
    if (vec_log_max > 0 && p0_ack && !p0_ack_d &&
        p0_addr[20:1] == 20'h7f880 && vec_log_n < vec_log_max) begin
        vec_log_n = vec_log_n + 1;
        $display("[vec-p0-ack] n=%0d a=%06x d=%016x", vec_log_n, p0_addr, p0_dout);
    end
    if (vec_log_max > 0 && core.m_req && core.m_ack && !core.m_we &&
        (core.A[19:0] == 20'hff100 || core.A[19:0] == 20'hff102 ||
         core.A[19:0] == 20'hff104) &&
        vec_log_n < vec_log_max) begin
        vec_log_n = vec_log_n + 1;
        $display("[vec-cpu-rd] n=%0d pc=%08x a=%06x d=%04x", vec_log_n,
            core.v60.pc, core.A, core.m_rdata);
    end
end
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
                    cur_frame, prot_txn_n, core.v60.pc, core.A[23:0],
                    core.m_wdata, core.m_be);
            else
                $display("[prot] f=%0d n=%0d pc=%08x R [%06x] data=%04x be=%b",
                    cur_frame, prot_txn_n, core.v60.pc, core.A[23:0],
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
        rd_pc[rd_n % 24] <= core.v60.pc;
        rd_n = rd_n + 1;
    end
end

`ifdef FBDBG
// fetch-buffer inspection at a trouble PC
integer fbdbg_n = 0;
always @(posedge clk_sys) if (ce_cpu) begin
    if (core.v60.pc == 32'h100551 && core.v60.st == S_DECODE_V && fbdbg_n < 4) begin
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
        if (core.v60.st == S_EA_VAL_V)
            $display("[eadbg] EA_VAL tgt2=%b want=%b flag=%b ea_addr=%08x ea_out=%08x ea_len=%0d ret=%0d",
                core.v60.ea_target2, core.v60.ea_want_addr, core.v60.ea_flag,
                core.v60.ea_addr, core.v60.ea_out, core.v60.ea_len, core.v60.ea_ret);
        if (core.v60.st == S_EXEC_V)
            $display("[eadbg] EXEC op=%02x op1=%08x op2=%08x flag1=%b flag2=%b",
                core.v60.cur_op, core.v60.op1, core.v60.op2, core.v60.flag1, core.v60.flag2);
        if (core.v60.st == S_WB_MEM_V)
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
    if (ce_pix && !hb && !vb && rgb_a != 24'h0) nb_pix = nb_pix + 1;

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
// Mixer register write log.  The default remains deliberately small for broad
// boot sweeps; focused differential runs can raise it with +MIXWMAX=<count>.
integer mixw_n = 0;
integer mixw_max = 80;
initial if (!$value$plusargs("MIXWMAX=%d", mixw_max)) mixw_max = 80;
always @(posedge clk_sys) begin
    if (core.mix0.reg_we && mixw_n < mixw_max) begin
        mixw_n = mixw_n + 1;
        if (!quiet)
            $display("[mixw] f=%0d pc=%08x mreg[%02x] <= %04x (byte ofs %03x) busA=%06x",
                cur_frame, core.v60.pc, core.mix0.reg_addr, core.mix0.reg_wdata,
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

// Bounded tile/palette-path diagnostic for real-game black frames.  Sprite-only
// logging cannot localize a title screen rendered entirely by NBG/text layers.
// Keep this behind plusargs so the normal sweep has zero extra output and the
// probe cannot mask a timing or liveness failure.
integer layerlog_n = 0;
integer layerlog_max = 0;
integer layerlog_frame = 300;
initial begin
    if (!$value$plusargs("LAYERLOG=%d", layerlog_max)) layerlog_max = 0;
    if (!$value$plusargs("LAYERFRAME=%d", layerlog_frame)) layerlog_frame = 300;
end
always @(posedge clk_sys) begin
    if (layerlog_max > 0 && layerlog_n < layerlog_max &&
        ce_pix && !hb && !vb && cur_frame >= layerlog_frame &&
        (core.mix0.px_text[13] || core.mix0.px_nbg0[13] ||
         core.mix0.px_nbg1[13] || core.mix0.px_nbg2[13] ||
         core.mix0.px_nbg3[13] || core.mix0.px_bmp[13] ||
         core.mix0.spr_opaque)) begin
        layerlog_n = layerlog_n + 1;
        $display("[layer] f=%0d x=%0d y=%0d txt=%04x n0=%04x n1=%04x n2=%04x n3=%04x bmp=%04x spr=%04x best=%0d best2=%0d idxw=%04x idx2=%04x paladdr=%04x palq=%04x rgb=%06x loff=%b",
            cur_frame, core.hcnt, core.vcnt,
            core.mix0.px_text, core.mix0.px_nbg0, core.mix0.px_nbg1,
            core.mix0.px_nbg2, core.mix0.px_nbg3, core.mix0.px_bmp,
            core.mix0.spr_pix, core.mix0.bestsel, core.mix0.best2sel,
            core.mix0.idx_winner, core.mix0.idx_runner, core.mix0.pal_addr,
            core.pal0.sim_peek(core.mix0.pal_addr), rgb_a,
            core.tilemap.layer_off);
    end
end

integer frames, f, p1_ev;
reg gear_latched = 1'b0;
reg gear_pressed_d = 1'b0;
reg gear_pressed;
integer arab_perf_at, arab_perf_n;
integer arab_perf_samples = 0, arab_perf_misses = 0;
reg arab_perf_done = 0;
reg playmagic = 0, playfight = 0, arabentry = 0, quiet = 0;
integer arab_entry_x0 = 0, arab_entry_x1 = 0;
integer arab_entry_dx = 0;
integer arab_entry_f0 = -1, arab_entry_f1 = -1;
reg arab_entry_started = 0;
reg arab_entry_done = 0, arab_entry_failed = 0;
`ifndef S32_EXTERNAL_CLOCKS
initial begin
    if (!$value$plusargs("FRAMES=%d", frames)) frames = 3;
    if (!$value$plusargs("ARABPERFAT=%d", arab_perf_at)) arab_perf_at = -1;
    if (!$value$plusargs("ARABPERFN=%d", arab_perf_n)) arab_perf_n = 13;
    playmagic = $test$plusargs("PLAYMAGIC");
    playfight = $test$plusargs("PLAYFIGHT");
    arabentry = $test$plusargs("ARABENTRY");
    quiet = $test$plusargs("QUIET");
    // Model the long board ROM-load reset: this fully flushes the production
    // jt12's 24-stage rings at its internally divided operator cadence.
    repeat (2048) @(posedge clk_sys);
    rst = 0;
    for (f = 0; f < frames; f = f + 1) begin
        in_p1a_r = 8'hff;
        in_portc_r = 8'hff;
        in_svc12_r = 8'hff;
        if (input_path != "") begin
            input_mask_value = 0;
            input_fd = $fopen(input_path, "r");
            if (input_fd != 0) begin
                input_scan = $fscanf(input_fd, "%h", input_mask_value);
                $fclose(input_fd);
                if (input_scan == 1) begin
                    in_p1a_r = in_p1a_r & ~input_mask_value[7:0];
                    if (input_mask_value[8]) in_svc12_r[p1_coin_bit] = 1'b0;
                    if (input_mask_value[9]) in_svc12_r[4] = 1'b0;
                end
            end
        end
        for (p1_ev = 0; p1_ev < 4; p1_ev = p1_ev + 1) begin
            if (!input_mask_value[13] &&
                p1_at[p1_ev] >= 0 && p1_len[p1_ev] > 0 &&
                f >= p1_at[p1_ev] && f < p1_at[p1_ev] + p1_len[p1_ev]) begin
                in_p1a_r = in_p1a_r & ~p1_mask[p1_ev][7:0];
                if (f == p1_at[p1_ev])
                    $display("[input] frames %0d..%0d: P1A mask %02x low",
                        p1_at[p1_ev], p1_at[p1_ev] + p1_len[p1_ev] - 1,
                        p1_mask[p1_ev][7:0]);
            end
        end
        // The production emu top edge-latches descriptor-selected cabinet
        // Gear Change inputs (Slip Stream/Rad Rally). Mirror that shared
        // board behavior in the direct-core harness; feeding P1A bit 0 as a
        // momentary level leaves the Slip Stream mode selector undecidable.
        gear_pressed = ~in_p1a_r[0];
        if (board.gear_toggle) begin
            if (gear_pressed && !gear_pressed_d)
                gear_latched = ~gear_latched;
            gear_pressed_d = gear_pressed;
            in_p1a_r[0] = ~gear_latched;
        end
        else begin
            gear_latched = 1'b0;
            gear_pressed_d = 1'b0;
        end
        if (coin_at >= 0 && coin_len > 0 &&
            f >= coin_at && f < coin_at + coin_len) begin
            in_svc12_r[p1_coin_bit] = 1'b0;
            if (f == coin_at)
                $display("[input] frames %0d..%0d: P1 coin low (port E bit %0d)",
                    coin_at, coin_at + coin_len - 1, p1_coin_bit);
        end
        if (coin2_at >= 0 && coin2_len > 0 &&
            f >= coin2_at && f < coin2_at + coin2_len)
            in_svc12_r[p1_coin_bit] = 1'b0;
        if (start_at >= 0 && start_len > 0 &&
            f >= start_at && f < start_at + start_len) begin
            in_svc12_r[4] = 1'b0;
            if (f == start_at)
                $display("[input] frames %0d..%0d: P1 start low (port E bit 4)",
                    start_at, start_at + start_len - 1);
        end
        if (start2_at >= 0 && start2_len > 0 &&
            f >= start2_at && f < start2_at + start2_len)
            in_svc12_r[4] = 1'b0;
        // +PLAYMAGIC gameplay autopilot: after coin+start, repeatedly tap
        // Button1 (0x01) to confirm the char select, then in gameplay hold Right
        // (0x40) toward the scripted rocks-flame and run a magic (Button3 0x04)
        // charge/release duty cycle to cast the fire spell. Both are the flame
        // triggers the user reports killing all sprites (#3).
        if (playmagic || playfight || arabentry) begin
            // Char-select confirm (user tip): tap START + ATTACK a few times, then
            // STOP and let the select screen TIME OUT into the level. Taps at
            // 470/510/550/590, then quiet 600..660 so the timeout fires.
            if (f >= 470 && f < 600 && (f % 40) < 6) begin
                in_p1a_r[0]  = 1'b0;   // Button1 (attack)
                in_svc12_r[4] = 1'b0;  // Start
            end
            // GA2 gameplay: hold Right from 680 (advance toward enemies / rocks)
            if (!arabentry && f >= 680) in_p1a_r[6] = 1'b0;              // Right
        end
        if (arabentry) begin
            // Arabian Fight reference replay: Button2 taps advance the
            // noninteractive ship dialogue, then stop before level 1.  No
            // direction is supplied: the player entrance must be autonomous.
            if (f >= 1200 && f < 1450 && (f % 20) < 5)
                in_p1a_r[1] = 1'b0;
            // Exercise the reported magic close-up only after the autonomous
            // entry motion has been measured, so it cannot affect that check.
            if (f >= 1670 && f < 1675)
                in_p1a_r[1] = 1'b0;
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
        @(posedge clk_sys);
        repeat (803999) @(posedge clk_sys);
        // Synchronise to the game scene rather than an absolute emulator frame.
        // In the matched MAME replay, NBG1 is at 4.0x zoom and scroll X advances
        // from 0x0271 to 0x0659 while the neutral-input player walks in.  Absolute
        // frame numbers differ with CPU implementation speed, but these video
        // registers and sprite-list positions describe the same game state.
        if (arabentry && !arab_entry_started &&
            core.tm_zoomx[1] == 16'h0400 &&
            core.tm_scrollx[1] >= 16'h0271 && core.tm_scrollx[1] < 16'h0300) begin
            integer arab_jump_x;
            integer arab_raw_x;
            arab_jump_x = $signed({{20{core.sprite_ram.mem[16'h0002][11]}},
                                    core.sprite_ram.mem[16'h0002][11:0]});
            arab_raw_x = $signed({{20{core.sprite_ram.mem[16'h0065][11]}},
                                   core.sprite_ram.mem[16'h0065][11:0]});
            arab_entry_x0 = arab_jump_x + arab_raw_x;
            arab_entry_f0 = f;
            arab_entry_started = 1'b1;
            $display("[arab-entry] start f=%0d n1sx=%04x x=%0d jump=%0d raw=%0d",
                f, core.tm_scrollx[1], arab_entry_x0, arab_jump_x, arab_raw_x);
            $display("[arab-entry-state] f=%0d w2005f6=%04x w2005f8=%04x",
                f, core.work_ram.mem[16'h02fb], core.work_ram.mem[16'h02fc]);
            $fflush();
        end
        if (arabentry && arab_entry_started && !arab_entry_done &&
            core.tm_zoomx[1] == 16'h0400 && core.tm_scrollx[1] >= 16'h0659) begin
            integer arab_jump_x;
            integer arab_raw_x;
            arab_jump_x = $signed({{20{core.sprite_ram.mem[16'h0002][11]}},
                                    core.sprite_ram.mem[16'h0002][11:0]});
            arab_raw_x = $signed({{20{core.sprite_ram.mem[16'h0065][11]}},
                                   core.sprite_ram.mem[16'h0065][11:0]});
            arab_entry_x1 = arab_jump_x + arab_raw_x;
            arab_entry_f1 = f;
            arab_entry_dx = arab_entry_x1 - arab_entry_x0;
            arab_entry_done = 1'b1;
            $display("[arab-entry] end f=%0d n1sx=%04x x=%0d dx=%0d jump=%0d raw=%0d",
                f, core.tm_scrollx[1], arab_entry_x1, arab_entry_dx,
                arab_jump_x, arab_raw_x);
            $display("[arab-entry-state] f=%0d w2005f6=%04x w2005f8=%04x",
                f, core.work_ram.mem[16'h02fb], core.work_ram.mem[16'h02fc]);
            if (arab_entry_dx < 20) begin
                arab_entry_failed = 1'b1;
                $display("ARABIAN FIGHT ENTRY FAIL: neutral-input player advanced only %0d pixels between scene markers (need >=20)",
                    arab_entry_dx);
            end
            else
                $display("ARABIAN FIGHT ENTRY PASS: neutral-input player advanced %0d pixels between scene markers",
                    arab_entry_dx);
            $fflush();
        end
        if (arab_perf_at >= 0 && f >= arab_perf_at &&
            f < arab_perf_at + arab_perf_n) begin
            arab_perf_samples = arab_perf_samples + 1;
            if (core.v60.pc != 32'h00fe4244 &&
                core.v60.pc != 32'h00fe4248)
                arab_perf_misses = arab_perf_misses + 1;
            $display("[arab-perf] f=%0d pc=%08x idle=%0d misses=%0d",
                f, core.v60.pc,
                core.v60.pc == 32'h00fe4244 ||
                core.v60.pc == 32'h00fe4248,
                arab_perf_misses);
            if (f == arab_perf_at + arab_perf_n - 1) begin
                arab_perf_done = 1'b1;
                if (arab_perf_misses != 0)
                    $fatal(1, "ARABIAN FIGHT PERF FAIL: %0d/%0d frame markers missed the idle loop",
                        arab_perf_misses, arab_perf_samples);
                else
                    $display("ARABIAN FIGHT PERF PASS: %0d/%0d frame markers reached the idle loop",
                        arab_perf_samples, arab_perf_samples);
            end
        end
        if (!quiet) begin
        $display("frame %0d: pc=%08x halted=%0d | wram=%0d vram=%0d pal=%0d spr=%0d io=%0d intc=%0d | irq=%0d exc=%0d vs=%0d sprpx=%0d stuck=%0d protrd=%0d shrd=%0d den=%b nb=%0d v02=%04x v8e=%04x v00=%04x loff=%b",
            f, core.v60.pc, core.v60.halted,
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
        end
        if (quiet && (f % 100) == 0) begin
            $display("[progress] frame %0d", f);
            $fflush();
        end
        rdreq_cnt = 0; kick_cnt = 0; spr_cmd_cnt = 0; srom_req_cnt = 0; spr_opq_cnt = 0;
        p1a_rd_cnt = 0; coin_rd_cnt = 0; start_rd_cnt = 0;
        tm_req_cnt = 0; tm_lb_cnt = 0; tm_opaque_cnt = 0;
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
    if (require_verilator_screenshot) begin
        if (dump_at < 0)
            $fatal(1, "VERILATOR SCREENSHOT FAIL: +DUMPAT=<frame> is required");
        if (!dump_complete)
            $fatal(1, "VERILATOR SCREENSHOT FAIL: requested PPM frame was not completed");
        if (!dump_nonblack_seen)
            $fatal(1, "VERILATOR SCREENSHOT FAIL: completed PPM frame is entirely black");
        $display("VERILATOR SCREENSHOT PASS: frame=%0d nonblack=%0d", dump_frame, dump_nonblack);
    end
    if (coin_at >= 0 || coin2_at >= 0 || start_at >= 0 ||
        start2_at >= 0 || p1_event_count > 0)
        $display("[input-summary] active CPU samples: coin=%0d start=%0d p1a=%0d",
            coin_active_samples, start_active_samples, p1a_active_samples);
    if (coin_at >= 0 && coin_active_samples == 0)
        $fatal(1, "ROMBOOT physical P1 coin was never returned on SERVICE12");
    if (start_at >= 0 && start_active_samples == 0)
        $fatal(1, "ROMBOOT P1 start was never returned on SERVICE12 bit 4");
    if (p1_event_count > 0 && p1a_active_samples == 0)
        $fatal(1, "ROMBOOT P1 digital event was never returned on P1A");
    if (arab_perf_at >= 0 && !arab_perf_done)
        $fatal(1, "ARABIAN FIGHT PERF window was not completed: at=%0d frames=%0d samples=%0d",
            arab_perf_at, arab_perf_n, arab_perf_samples);
    if (arab_heavy_at >= 0 && !arab_heavy_done)
        $fatal(1, "ARABIAN FIGHT HEAVY window was not completed: at=%0d fields=%0d samples=%0d",
            arab_heavy_at, arab_heavy_n, arab_heavy_samples);
    if (arabentry && !arab_entry_done)
        $fatal(1, "ARABIAN FIGHT ENTRY window was not completed");
    if (arabentry && arab_entry_failed)
        $fatal(1, "ARABIAN FIGHT ENTRY regression failed: neutral-input dx=%0d", arab_entry_dx);
`ifdef S32_REAL_FB_SIM
    if (fb_deadline_fail)
        $fatal(1, "GA2 production framebuffer reported a service deadline failure");
    if (fb_ddr_writes == 0 || fb_ddr_reads == 0)
        $fatal(1, "GA2 DDR traffic missing: writes=%0d reads=%0d",
               fb_ddr_writes, fb_ddr_reads);
    if (fb_line_acks < frames * 128)
        $fatal(1, "GA2 framebuffer line service too sparse: acks=%0d frames=%0d",
               fb_line_acks, frames);
    // This is a Golden Axe-specific visual qualification.  b2 is the
    // protection selector, so it cannot identify GA2: several
    // standard-profile games also have b2=0.  ga2_qualification is derived
    // from the raw descriptor's V25/table flags above.
    if (ga2_qualification && frames >= 70 && spr_px == 0)
        $fatal(1, "GA2 reached gameplay window without any sprite pixels");
    if (frame_sig_x != 0)
        $fatal(1, "GA2 active-video signature contained X on %0d frames",
               frame_sig_x);
    if (ga2_qualification && frames >= 70 && frame_sig_samples < 10)
        $fatal(1, "GA2 active-video signature window was not exercised");
    if (ga2_qualification && frames >= 90 && frame_sig_changes < 3)
        $fatal(1, "GA2 active video stopped changing: samples=%0d changes=%0d",
               frame_sig_samples, frame_sig_changes);
    $display("GA2 DDR QUALIFICATION PASS writes=%0d reads=%0d line_acks=%0d max_wr=%0d max_rd=%0d max_er=%0d sig_samples=%0d sig_changes=%0d",
        fb_ddr_writes, fb_ddr_reads, fb_line_acks,
        fb_max_wr_wait, fb_max_rd_wait, fb_max_er_wait,
        frame_sig_samples, frame_sig_changes);
`endif
    $display("ROMBOOT DONE");
    $finish;
end
`endif

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
// Stage A (SEQ_DISPATCH) take-rate counters, work-only window.
integer seq_next_cyc = 0;
integer seq_shift_cnt = 0;
integer seq_disp_cnt = 0;
integer seq_long_cnt = 0;      // realigned but total_len > 4 (needs 2nd shift)
integer seq_shortwin_cnt = 0;  // realigned in one step but window too short
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
        pc_hist[core.v60.pc] = pc_hist[core.v60.pc] + 1;
        st_hist[core.v60.st] = st_hist[core.v60.st] + 1;
        pc_samples = pc_samples + 1;
        // count instructions = FSM entering S_DECODE (one per fetched opcode)
        if (core.v60.st == S_DECODE_V && st_prev != S_DECODE_V) instr_count = instr_count + 1;
        // WORK-only tally: same cycles/instrs but excluding the idle frame-sync spin
        if (core.v60.pc != 32'h0013_3505 && core.v60.pc != 32'h0013_350b) begin
            work_cyc = work_cyc + 1;
            if (core.v60.st == S_DECODE_V && st_prev != S_DECODE_V) work_instr = work_instr + 1;
            // Stage A take-rate: how often the S_NEXT fast path actually fires.
            // S_NEXT is the fast-path state.  seq_shift_ok = the realign moved into S_NEXT;
            // seq_dispatch_now = S_FILL skipped entirely.
            if (core.v60.st == S_NEXT_V) begin
                seq_next_cyc = seq_next_cyc + 1;
                if (core.v60.seq_shift_ok)     seq_shift_cnt = seq_shift_cnt + 1;
                if (core.v60.seq_dispatch_now) seq_disp_cnt  = seq_disp_cnt  + 1;
                // Partition the cases where the realign happened but S_FILL
                // could NOT be skipped.  The two causes need different fixes:
                //   long  = total_len > 4, so one 4-byte shift cannot align the
                //           window and S_FILL must run a second step.  Fixing
                //           this means an 8-byte shift, which widens the fb[]
                //           input mux 5:1 -> 9:1 and spends timing margin.
                //   short = window aligned in one step but not holding
                //           seq_need bytes.  Fixing this is a prefetch/window
                //           occupancy problem, not a shift-width one.
                if (core.v60.seq_shift_ok && !core.v60.seq_dispatch_now) begin
                    if (core.v60.total_len > 5'd4) seq_long_cnt = seq_long_cnt + 1;
                    else                           seq_shortwin_cnt = seq_shortwin_cnt + 1;
                end
            end
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
        $display("[seqdisp] S_NEXT cycles=%0d  realign-in-S_NEXT=%0d (%0d%%)  S_FILL-skipped=%0d (%0d%%)",
                 seq_next_cyc, seq_shift_cnt,
                 seq_next_cyc ? (100*seq_shift_cnt)/seq_next_cyc : 0,
                 seq_disp_cnt,
                 seq_next_cyc ? (100*seq_disp_cnt)/seq_next_cyc : 0);
        $display("[seqdisp] S_FILL still needed: total_len>4=%0d (%0d%%)  window-short=%0d (%0d%%)",
                 seq_long_cnt,
                 seq_next_cyc ? (100*seq_long_cnt)/seq_next_cyc : 0,
                 seq_shortwin_cnt,
                 seq_next_cyc ? (100*seq_shortwin_cnt)/seq_next_cyc : 0);
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
