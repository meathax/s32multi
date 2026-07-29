//============================================================================
//  Sega System 32 / Multi 32 — board top (DESIGN.md §3.1)
//  Wires: V60 + bus decode (Appendix A), video pipeline, sound subsystem,
//  I/O chips, interrupt controller, protection modules, SDRAM/DDR3.
//============================================================================

import s32_pkg::*;

// Dedicated single-game revisions share two area choices: the synchronous
// MLAB-backed V60 ROM cache instead of the generic asynchronous register/mux
// cache, and a hardwired "no protection ROM requester" on SDRAM p0.  Both are
// only legal when nothing else can contend for that port, which is exactly the
// case for the unprotected profiles.  Derive one macro so the guards below stay
// readable (Verilog `ifdef has no ||).
// +define+S32_NO_MLAB_ROM_CACHE forces the generic asynchronous cache back on
// for A/B testing: the MLAB lookup costs one extra raw clk_sys, which is inside
// one architectural interval for Golden Axe's 16.108 MHz V60 but can occasionally
// straddle a ce edge on OutRunners' 20 MHz V70.
`ifndef S32_NO_MLAB_ROM_CACHE
`ifdef S32_GOLDENAXE_ONLY
 `define S32_MLAB_ROM_CACHE 1
`endif
`ifdef S32_OUTRUNNERS_ONLY
 `define S32_MLAB_ROM_CACHE 1
`endif
`endif

module s32_core #(
`ifdef S32_OUTRUNNERS_ONLY
    // Dedicated Multi 32 profile takes precedence over the shared QSF's
    // System32-only default.
    parameter SYSTEM32_ONLY = 1'b0
`elsif S32_SYSTEM32_ONLY
    // The SegaS32 Quartus revision sets this macro so Cyclone V only pays for
    // hardware present on a single-screen System 32 board.  A future Multi 32
    // revision leaves the macro unset (or explicitly overrides the parameter).
    parameter SYSTEM32_ONLY = 1'b1
`else
    parameter SYSTEM32_ONLY = 1'b0
`endif
) (
    input             clk_sys,      // 48.317307 MHz
    input             clk_ram,      // 96.634615 MHz
`ifdef S32_REAL_V25
    input             clk_v25,      // ~24.158653 MHz (clk_sys/2): s80x86 compute domain
`endif
    input             rst,
    // Keep CRT timing alive while game logic is held in ROM-load reset.
    input             video_rst,

    input  board_desc_t board,

    // clock enables (from fractional CE generators in emu top)
    input             ce_cpu,       // 16.108 / 20 MHz
    input             ce_z80,       // 8.054 / 8.0
    input             ce_fm,
    input             ce_pcm,       // 12.5 / 10.0
    // OSD pause: the emu top zeroes ce_cpu/ce_z80/ce_pcm; the real V25 has
    // its own clk_v25-domain CE generator, so it must be told separately or
    // it keeps running against a frozen V60 (mailbox tear on ga2/arabfgt).
    input             pause,

    // SDRAM ports (to sdram.sv in emu top)
    output            sdr_p0_req,
    output     [24:1] sdr_p0_addr,
    input      [15:0] sdr_p0_dout,
    input             sdr_p0_ack,
    output            sdr_p1_req,
    output     [24:3] sdr_p1_addr,
    input      [63:0] sdr_p1_dout,
    input             sdr_p1_ack,
    output            sdr_p2_req,
    output     [24:4] sdr_p2_addr,
    input     [127:0] sdr_p2_dout,
    input             sdr_p2_ack,
    output            sdr_p3_req,
    output     [24:1] sdr_p3_addr,
    input      [15:0] sdr_p3_dout,
    input             sdr_p3_ack,
    output            sdr_p4_req,
    output     [24:1] sdr_p4_addr,
    input      [15:0] sdr_p4_dout,
    input             sdr_p4_ack,
    output            sdr_p5_req,
    output     [24:3] sdr_p5_addr,
    input      [63:0] sdr_p5_dout,
    input             sdr_p5_ack,

    // DDR3 framebuffer service (s32_fb_if lives in emu top)
    output            fb_wr_start,
    output      [1:0] fb_wr_buf,
    output      [8:0] fb_wr_x,
    output      [7:0] fb_wr_y,
    output            fb_wr_valid,
    output     [15:0] fb_wr_pix,
    output            fb_wr_end,
    output            fb_wr_shadow,   // run RMWs dest &= 0x7fff (V-10)
    input             fb_wr_busy,     // fb_if still flushing previous run
    output            fb_er_req,
    output      [1:0] fb_er_buf,
    output      [7:0] fb_er_y,
    input             fb_er_ack,
    output            fb_rd_req,
    output      [1:0] fb_rd_buf,
    output      [7:0] fb_rd_y,
    input             fb_rd_ack,
    output      [8:0] fb_rd_x,
    input      [15:0] fb_rd_pix,

    // V25 program load
    input             v25_prg_wr,
    input      [15:0] v25_prg_waddr,
    input       [7:0] v25_prg_wdata,

    // EEPROM NVRAM load/save
    input             eep_ld_wr,
    input       [5:0] eep_ld_addr,
    input      [15:0] eep_ld_data,
    output     [15:0] eep_rd_data,
    input       [5:0] eep_rd_addr,
    input             eep_upload,
    output            eep_modified,

    // inputs (already mapped per game class by emu top)
    input       [7:0] in_p1a, in_p2a, in_portc, in_svc12, in_svc34,
    input       [7:0] in_p1b, in_p2b, in_portc_b, in_svc12_b, in_svc34_b,
    input       [7:0] adc_ch [0:7],
    input             trk_dv [0:2],
    input signed [8:0] trk_dx [0:2],
    input signed [8:0] trk_dy [0:2],
    input       [7:0] trk_btn [0:2],
    input       [7:0] ppi_pa, ppi_pb, ppi_pc,

    // Multi 32 presents one of its two monitors at a time.  The sprite engine
    // uses this to retire descriptors belonging to the hidden monitor without
    // drawing them; the board still renders both palettes/mixers.
    input             screen_sel,

    // video out (screen A; screen B via second mixer on M32)
    output     [23:0] rgb_a,
    output     [23:0] rgb_b,
    output            ce_pix,
    output            hs, vs, hb, vb,

    output signed [15:0] audio_l,
    output signed [15:0] audio_r,

    output      [7:0] out_lamps,    // misc outputs (coin counters etc)

    // Hardware bring-up visibility. These signals are selected by the
    // top-level Debug Video option and do not alter the emulated board.
    output     [31:0] debug_pc,
    output            debug_halted,
    output     [23:0] debug_status,
    output     [15:0] debug_first_rom,
    output      [8:0] debug_hcnt,
    output      [8:0] debug_vcnt,
    output    [127:0] debug_sprite_desc,
    output            debug_sprite_desc_valid,
    output    [127:0] debug_sprite_last_desc,
    output    [127:0] debug_sprite_last_draw_desc,
    output     [23:0] debug_sprite_activity,
    output     [31:0] debug_sprite_state,
    output     [63:0] debug_sprite_counts,
    output            debug_sprite_rendering,
    output     [47:0] debug_sprram_cpu,
    output     [47:0] debug_pal_rd,    // clk_sys palette shadow {0x410,0x200,0x000}
    output     [23:0] debug_fb_underrun,// PF-6: {sticky?0xff:0, underrun_count[15:0]}
    output     [15:0] debug_cam,        // spidman world-camera {page, display_lo}
    output     [23:0] debug_v25,        // V25 bring-up: {ce[3:0],wake,mb!=0,unm,io,rd_cnt,mb_last}
    output     [89:0] debug_v25_img     // {sweep_done, first_valid, hash[23:0], first_line[63:0]}
);

`ifdef S32_OUTRUNNERS_ONLY
localparam GOLDENAXE_ONLY = 1'b0;
localparam OUTRUNNERS_ONLY = 1'b1;
localparam GAME_ONLY      = 1'b1;
`elsif S32_GOLDENAXE_ONLY
localparam GOLDENAXE_ONLY = 1'b1;
localparam OUTRUNNERS_ONLY = 1'b0;
localparam GAME_ONLY      = 1'b1;
`elsif S32_GA2_ONLY
localparam GOLDENAXE_ONLY = 1'b0;
localparam OUTRUNNERS_ONLY = 1'b0;
localparam GAME_ONLY      = 1'b1;
`elsif S32_HOLO_ONLY
localparam GOLDENAXE_ONLY = 1'b0;
localparam OUTRUNNERS_ONLY = 1'b0;
localparam GAME_ONLY      = 1'b1;
`elsif S32_JPARK_ONLY
localparam GOLDENAXE_ONLY = 1'b0;
localparam OUTRUNNERS_ONLY = 1'b0;
localparam GAME_ONLY      = 1'b1;
`else
localparam GOLDENAXE_ONLY = 1'b0;
localparam OUTRUNNERS_ONLY = 1'b0;
localparam GAME_ONLY      = 1'b0;
`endif

// Dedicated Golden Axe hardware constants. The MRA descriptor is still loaded
// and validated, but fixing these board straps at elaboration lets Quartus
// remove unrelated runtime-select muxes. Other profiles remain descriptor-led.
`ifdef S32_GOLDENAXE_ONLY
wire       cfg_multi32           = 1'b0;
wire       cfg_has_v25           = 1'b1;
wire       cfg_v25_table         = 1'b0;
wire       cfg_has_adc           = 1'b0;
wire       cfg_has_track         = 1'b0;
wire       cfg_has_ppi           = 1'b1;
wire       cfg_has_dsp_hle       = 1'b0;
wire       cfg_dual_pcb          = 1'b0;
wire [6:0] cfg_prot_sel          = PROT_NONE;
wire       cfg_sprite_bank_valid = 1'b1;
wire [1:0] cfg_sprite_bank_mask  = 2'b11;
wire       cfg_flip_y            = 1'b0;
`elsif S32_OUTRUNNERS_ONLY
wire       cfg_multi32           = 1'b1;
wire       cfg_has_v25           = 1'b0;
wire       cfg_v25_table         = 1'b0;
wire       cfg_has_adc           = 1'b1;
wire       cfg_has_track         = 1'b0;
wire       cfg_has_ppi           = 1'b0;
wire       cfg_has_dsp_hle       = 1'b0;
wire       cfg_dual_pcb          = 1'b0;
wire [6:0] cfg_prot_sel          = PROT_NONE;
wire       cfg_sprite_bank_valid = 1'b1;
wire [1:0] cfg_sprite_bank_mask  = 2'b11;
wire       cfg_flip_y            = 1'b0;
`else
wire       cfg_multi32           = board.multi32;
wire       cfg_has_v25           = board.has_v25;
wire       cfg_v25_table         = board.v25_table;
wire       cfg_has_adc           = board.has_adc;
wire       cfg_has_track         = board.has_track;
wire       cfg_has_ppi           = board.has_ppi;
wire       cfg_has_dsp_hle       = board.has_dsp_hle;
wire       cfg_dual_pcb          = board.dual_pcb;
wire [6:0] cfg_prot_sel          = board.prot_sel;
wire       cfg_sprite_bank_valid = board.sprite_bank_valid;
wire [1:0] cfg_sprite_bank_mask  = board.sprite_bank_mask;
wire       cfg_flip_y            = board.flip_y;
`endif
// A System32-only bitstream must not enter a Multi 32 runtime configuration if
// it is accidentally paired with a Multi 32 MRA.  The universal source build
// retains the descriptor-selected path when SYSTEM32_ONLY is false. System 32
// GAME_ONLY profiles force the single-screen configuration. The dedicated
// OutRunners profile is the explicit Multi 32 exception and fixes it high.
wire is_multi32 = OUTRUNNERS_ONLY ? 1'b1 :
                  (SYSTEM32_ONLY || GAME_ONLY) ? 1'b0 : cfg_multi32;

// ---------------------------------------------------------------------------
// CPU + bus adapter
// ---------------------------------------------------------------------------
wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;
wire        wr_stb;

wire        irq_n;
wire [7:0]  irq_vector;
wire [31:0] v60_debug_pc;
wire        v60_debug_halted;

// dedicated wide instruction-fetch port (FAST_IFETCH): the prefetch reads whole
// 8-byte ROM icache lines here at clk_sys latency, bypassing the ce-gated 16-bit
// data adapter that otherwise bottlenecks fetch bandwidth.
wire        if_req;
wire [23:0] if_addr;                 // frontier byte address (low 3 bits = intra-line
                                    // offset used to pre-align the returned line)
`ifdef S32_MLAB_ROM_CACHE
wire [63:0] if_data;
wire        if_served;
`else
reg  [63:0] if_data;
reg         if_served;
`endif
                                    // held while a fetch result is presented
wire        if_ack = if_served;     // held (not pulsed) so the ce-gated CPU never
                                    // misses it between its enable ticks

// FAST_IFETCH defaults on; override at build time (+define+FAST_IFETCH_EN=1'b0)
// to A/B-test the wide fetch path against the legacy ce-gated adapter fetch.
`ifndef FAST_IFETCH_EN
 `define FAST_IFETCH_EN 1'b1
`endif
s32_v60 #(.START_PC(32'hFFFFFFF0), .FAST_IFETCH(`FAST_IFETCH_EN)) v60 (   // MAME reset PC (audit R20 V60-21)
    .clk(clk_sys), .ce(ce_cpu), .rst(rst), .is_v70(is_multi32),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(),
    .nmi_n(1'b1),
    .dbg_pc(v60_debug_pc), .dbg_halted(v60_debug_halted)
);

assign debug_pc     = v60_debug_pc;
assign debug_halted = v60_debug_halted;

s32_v60_bus vbus (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// ---------------------------------------------------------------------------
// address decode (Appendix A) — 24-bit space
// ---------------------------------------------------------------------------
wire [23:0] A = {m_addr, 1'b0};
wire sel_rom    = (A < 24'h200000);
wire sel_wram   = (A[23:20] == 4'h2);
wire sel_vram   = (A[23:20] == 4'h3);
wire sel_sprram = (A[23:20] == 4'h4);
wire sel_sprctl = (A[23:20] == 4'h5);
wire sel_shared = (A[23:20] == 4'h7);
wire sel_comm   = (A[23:16] == 8'h80);
wire sel_dual   = (A[23:16] == 8'h81);
wire sel_prot_a = (A[23:20] == 4'hA);
wire sel_v25    = sel_prot_a && (A[19:12] == 8'h00); // 0xA00000-A00FFF
// MAME's I/O mirrors ignore A19:A7 (System 32) or A18:A7 (Multi 32).
// A6:A5 remain decoded: 00 selects the 5296 and A6 selects expansion I/O.
wire io0_area   = (A[23:20] == 4'hC) && (!is_multi32 || !A[19]);
wire sel_io0    = io0_area && (A[6:5] == 2'b00);
wire sel_ioex   = io0_area && A[6];
wire sel_io1    = is_multi32 && (A[23:20] == 4'hC) && A[19] &&
                  (A[6:5] == 2'b00);
wire sel_intc   = (A[23:20] == 4'hD) && !A[19];
wire sel_rand   = (A[23:20] == 4'hD) &&  A[19];
wire sel_romhi  = (A[23:20] == 4'hF);

// Palette/mixer windows are mirrored through bits 19:17 (System 32) or
// 18:17 (Multi 32); A16 alone distinguishes palette RAM from mixer regs.
wire pal_area   = (A[23:20] == 4'h6);
wire is_pal0    = pal_area && !A[16] && (!is_multi32 || !A[19]);
wire is_mix0    = pal_area &&  A[16] && (!is_multi32 || !A[19]);
wire is_pal1    = is_multi32 && pal_area && A[19] && !A[16];
wire is_mix1    = is_multi32 && pal_area && A[19] &&  A[16];

// ---------------------------------------------------------------------------
// work RAM — dual port (CPU + protection)
//
// System 32 has 64 KiB (32K x 16); Multi 32 has 128 KiB (64K x 16).  Keeping
// the depth elaboration-time constant lets Quartus remove 64 M10Ks from the
// SegaS32 revision instead of retaining the runtime-selectable maximum.
// ---------------------------------------------------------------------------
localparam integer WRAM_ADDR_WIDTH = SYSTEM32_ONLY ? 15 : 16;
localparam integer WRAM_WORDS      = SYSTEM32_ONLY ? 32768 : 65536;
wire [15:0] wram_q;
wire [WRAM_ADDR_WIDTH-1:0] wram_a = SYSTEM32_ONLY ? A[15:1] :
                                    (is_multi32 ? A[16:1] : {1'b0, A[15:1]});

// protection second port
wire        pr_req, pr_we;
wire [15:0] pr_addr;
wire [15:0] pr_wdata;
wire [1:0]  pr_be;
wire [15:0] pr_q;
reg         pr_ack;
wire [WRAM_ADDR_WIDTH-1:0] pr_wram_a = pr_addr[WRAM_ADDR_WIDTH-1:0];

s32_big_dpram #(
    .ADDR_WIDTH(WRAM_ADDR_WIDTH), .NUM_WORDS(WRAM_WORDS)
) work_ram (
    .clock_a(clk_sys), .address_a(wram_a),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b(pr_wram_a),
    .data_b(pr_wdata), .byteena_b(pr_be),
    .wren_b(pr_req && pr_we), .q_b(pr_q)
);

always @(posedge clk_sys)
    pr_ack <= pr_req;

// Venom/Scorpion trigger diagnostic (spidman): snoop the game's world-camera
// variable at 0x208032 (work-RAM word 0x4019).  Low byte 0x208032 sources the
// display scroll (correct on hardware); high byte 0x208033 is the page counter
// that scripted events gate on.  Capturing the last-written bytes lets a debug
// view show whether the core's page runs ahead of the display (the suspected
// low->high carry divergence).  Snoop only; no effect on operation.
reg [15:0] dbg_cam;
initial dbg_cam = 16'h0000;
always @(posedge clk_sys)
    if (m_req && m_we && sel_wram && wram_a == 'h4019) begin
        if (m_be[0]) dbg_cam[7:0]  <= m_wdata[7:0];   // 0x208032 (display low)
        if (m_be[1]) dbg_cam[15:8] <= m_wdata[15:8];  // 0x208033 (page/high)
    end
assign debug_cam = dbg_cam;

// ---------------------------------------------------------------------------
// video subsystem
// ---------------------------------------------------------------------------
wire [15:0] vram_cpu_q, vram_vid_q;
wire        io0_cnt1, io0_cnt2;
wire        io1_cnt1;              // Multi 32 screen-B display enable (io1 CNT1)
wire [15:0] vid_vaddr;
wire [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e;
wire [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e;
wire [15:0] w_scrollfracx [0:1];
wire [15:0] w_scrollfracy [0:1];
wire [15:0] w_scrollx [0:3];
wire [15:0] w_scrolly [0:3];
wire [15:0] w_offsx [0:3];
wire [15:0] w_offsy [0:3];
wire [15:0] w_pages [0:7];
wire [15:0] w_zoomx [0:1];
wire [15:0] w_zoomy [0:1];
wire [15:0] w_clips [0:19];

s32_vram vram (
    .clk(clk_sys), .vid_clk(clk_ram),
    .cpu_we(m_req && m_we && sel_vram),
    .cpu_addr(A[16:1]),
    .cpu_wdata(m_wdata), .cpu_be(m_be), .cpu_rdata(vram_cpu_q),
    .vid_addr(vid_vaddr), .vid_rdata(vram_vid_q),
    .reg_1ff00(r1ff00), .reg_1ff02(r1ff02), .reg_1ff04(r1ff04),
    .reg_1ff06(r1ff06),
    .reg_scrollfracx(w_scrollfracx), .reg_scrollfracy(w_scrollfracy),
    .reg_scrollx(w_scrollx), .reg_scrolly(w_scrolly),
    .reg_offsx(w_offsx), .reg_offsy(w_offsy),
    .reg_pages(w_pages), .reg_zoomx(w_zoomx), .reg_zoomy(w_zoomy),
    .reg_1ff5c(r1ff5c), .reg_1ff5e(r1ff5e), .reg_clips(w_clips),
    .reg_1ff88(r1ff88), .reg_1ff8a(r1ff8a), .reg_1ff8c(r1ff8c),
    .reg_1ff8e(r1ff8e)
);

// sprite RAM: CPU port + engine port
wire [15:0] sprram_q, sprlist_q;
wire [15:0] slist_addr;
s32_big_dpram #(
    .ADDR_WIDTH(16), .NUM_WORDS(65536), .MIXED_RDW_MODE("DONT_CARE")
) sprite_ram (
    .clock_a(clk_sys), .address_a(A[16:1]),
    .data_a(m_wdata), .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_sprram), .q_a(sprram_q),
    .clock_b(clk_ram), .address_b(slist_addr),
    .data_b(16'h0000), .byteena_b(2'b00),
    .wren_b(1'b0), .q_b(sprlist_q)
);

// Record completed CPU writes, not every cycle of a held V60 bus request.
// Packed output = {count, seen/BE/pad, last word address, last data}.
wire       debug_sprram_seen;
wire [7:0] debug_sprram_count;
wire [15:0] debug_sprram_addr;
wire [15:0] debug_sprram_data;
wire [1:0] debug_sprram_be;
s32_sprite_write_debug sprite_write_debug (
    .clk(clk_sys), .rst(rst),
    .wr_stb(wr_stb && m_we && sel_sprram),
    .wr_addr(A[16:1]), .wr_data(m_wdata), .wr_be(m_be),
    .seen(debug_sprram_seen), .count(debug_sprram_count),
    .last_addr(debug_sprram_addr), .last_data(debug_sprram_data),
    .last_be(debug_sprram_be)
);
assign debug_sprram_cpu = {debug_sprram_count,
                           debug_sprram_seen, debug_sprram_be, 5'b00000,
                           debug_sprram_addr, debug_sprram_data};

// CRT timing
wire mode_416;
wire mode_416_active;
wire vbl_start, vbl_end;
wire [8:0] hcnt, vcnt;
assign debug_hcnt = hcnt;
assign debug_vcnt = vcnt;
s32_video crt (
    .clk(clk_sys), .rst(video_rst), .mode_416(mode_416),
    .mode_active(mode_416_active),
    .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
    .vblank_start(vbl_start), .vblank_end(vbl_end)
);

// tilemap engine (clk_ram domain; registers quasi-static)
wire        tm_lb_we;
wire [2:0]  tm_lb_layer;
wire [8:0]  tm_lb_x;
wire [13:0] tm_lb_pix;
wire        line_start_r;
wire [8:0]  render_line;
wire        tm_lb_bank;
wire        tm_line_done;
wire        tm_line_busy;
wire        tm_line_overrun_sticky;
wire [15:0] tm_line_overrun_count;
wire [7:0]  io0_ph;
// Snapshot of CPU-domain video controls used for one complete rendered line.
// These registers are captured at the line-start boundary below.
reg        tm_mode_416;
reg  [7:0] tm_ext_tilebank;
reg [15:0] tm_r1ff00, tm_r1ff02, tm_r1ff04, tm_r1ff06;
reg [15:0] tm_r1ff5c, tm_r1ff5e, tm_r1ff88, tm_r1ff8a, tm_r1ff8c, tm_r1ff8e;
reg [15:0] tm_scrollfracx [0:1], tm_scrollfracy [0:1];
reg [15:0] tm_scrollx [0:3], tm_scrolly [0:3];
reg [15:0] tm_offsx [0:3], tm_offsy [0:3];
reg [15:0] tm_pages [0:7];
reg [15:0] tm_zoomx [0:1], tm_zoomy [0:1];
reg [15:0] tm_clips [0:19];
reg [15:0] tm_clips_cdc [0:19];
reg  [8:0] mix_disp_x_cdc;
reg [15:0] mix_bg_ctrl;
integer tm_init_i;
integer tm_cap_i;
integer tm_cdc_i;
initial begin
    tm_mode_416 = 1'b1;
    tm_ext_tilebank = 8'b0;
    tm_r1ff00 = 16'h8000;
    tm_r1ff02 = 0; tm_r1ff04 = 0; tm_r1ff06 = 0;
    tm_r1ff5c = 0; tm_r1ff5e = 0;
    mix_bg_ctrl = 0;
    tm_r1ff88 = 0; tm_r1ff8a = 0; tm_r1ff8c = 0; tm_r1ff8e = 0;
    for (tm_init_i = 0; tm_init_i < 4; tm_init_i = tm_init_i + 1) begin
        tm_scrollx[tm_init_i] = 0; tm_scrolly[tm_init_i] = 0;
        tm_offsx[tm_init_i] = 0; tm_offsy[tm_init_i] = 0;
    end
    for (tm_init_i = 0; tm_init_i < 8; tm_init_i = tm_init_i + 1) tm_pages[tm_init_i] = 0;
    for (tm_init_i = 0; tm_init_i < 2; tm_init_i = tm_init_i + 1) begin
        tm_scrollfracx[tm_init_i] = 0; tm_scrollfracy[tm_init_i] = 0;
        tm_zoomx[tm_init_i] = 16'h0200; tm_zoomy[tm_init_i] = 16'h0200; // neutral 1.0 zoom default
    end
    for (tm_init_i = 0; tm_init_i < 20; tm_init_i = tm_init_i + 1) begin
        tm_clips[tm_init_i] = 0;
        tm_clips_cdc[tm_init_i] = 0;
    end
    mix_disp_x_cdc = 0;
end

// hcnt is produced on the phase-aligned clk_sys rising edge. Register it on
// clk_ram's rising edge: the mixer consumes the previous value on that edge,
// giving its change-detect/enable cone a complete 96 MHz cycle. The line RAMs
// have already sampled the new hcnt by the time the mixer observes this copy,
// so their old one-clock launch wait can be folded into the transfer.
always @(posedge clk_ram)
    mix_disp_x_cdc <= hcnt;

// Quasi-static CPU controls retain the falling-edge capture so their normal
// rising-edge consumers have half a clk_ram cycle of setup/hold margin.
always @(negedge clk_ram) begin
    // These are sampling registers, not architectural state. They have
    // explicit power-up values and are overwritten on every falling edge, so
    // a reset mux only creates a long status[0] -> inverted-clk_ram half-cycle
    // path across all 329 bits.
    for (tm_cdc_i = 0; tm_cdc_i < 20; tm_cdc_i = tm_cdc_i + 1)
        tm_clips_cdc[tm_cdc_i] <= w_clips[tm_cdc_i];
end

// Launch at the start of the preceding scanline.  This gives the renderer a
// complete line period to fill the opposite parity buffer; the former hblank
// launch left only 90-96 pixel periods and routinely missed its deadline when
// SDRAM was contended by the V25.  ce_pix/hcnt are held for multiple clk_ram
// edges, so the scheduler performs the required event qualification.
wire tm_line_boundary = ce_pix && (hcnt == 9'd0);
wire [8:0] tm_next_line = (vcnt == 9'd261) ? 9'd0 : vcnt + 1'd1;
// Only kick the renderer for the visible lines 0-223 (tm_next_line ranges over
// 0..261; vcnt 261 pre-renders line 0).  Rendering the 38 vblank lines filled
// never-displayed parity banks and burned ~15% of frame SDRAM p1 bandwidth the
// V60/V25/sprite clients contend for (audit R20 TM-5).  The backdrop snapshot
// below keeps the ungated boundary so per-line line-color still updates.
wire tm_render_kick = tm_line_boundary && (tm_next_line <= 9'd223);
// Holosseum is mounted with ORIENTATION_FLIP_Y.  Keep timing and line-buffer
// parity in visible-screen order, but render the vertically mirrored source
// scanline into that bank.
wire [8:0] tm_source_line = (cfg_flip_y && render_line <= 9'd223)
                          ? (9'd223 - render_line) : render_line;
s32_tile_line_scheduler tile_line_scheduler (
    .clk(clk_ram), .rst(rst),
    .line_kick(tm_render_kick), .next_line(tm_next_line),
    .line_done(tm_line_done), .line_start(line_start_r),
    .render_line(render_line), .lb_bank(tm_lb_bank), .busy(tm_line_busy),
    .overrun_sticky(tm_line_overrun_sticky),
    .overrun_count(tm_line_overrun_count)
);

always @(posedge clk_ram) begin
    // The backdrop is generated by the mixer for the line currently being
    // scanned, while the tile renderer snapshots controls for the following
    // line.  Keep a separate current-line copy of VRAM $1FF5E so a mid-frame
    // write cannot tear one backdrop scanline or lead it by one line.
    if (rst)
        mix_bg_ctrl <= 16'h0000;
    else if (tm_line_boundary)
        mix_bg_ctrl <= r1ff5e;

    if (line_start_r) begin
        // Snapshot the CPU-domain register file once per line. The renderer
        // observes only this stable copy until line_done.  A missed boundary
        // cannot mutate the in-flight line, bank, or control state.
        tm_mode_416 <= mode_416_active;
        tm_ext_tilebank <= io0_ph;
        tm_r1ff00 <= r1ff00; tm_r1ff02 <= r1ff02;
        tm_r1ff04 <= r1ff04; tm_r1ff06 <= r1ff06;
        tm_r1ff5c <= r1ff5c; tm_r1ff5e <= r1ff5e;
        tm_r1ff88 <= r1ff88; tm_r1ff8a <= r1ff8a;
        tm_r1ff8c <= r1ff8c; tm_r1ff8e <= r1ff8e;
        for (tm_cap_i = 0; tm_cap_i < 4; tm_cap_i = tm_cap_i + 1) begin
            tm_scrollx[tm_cap_i] <= w_scrollx[tm_cap_i];
            tm_scrolly[tm_cap_i] <= w_scrolly[tm_cap_i];
            tm_offsx[tm_cap_i] <= w_offsx[tm_cap_i];
            tm_offsy[tm_cap_i] <= w_offsy[tm_cap_i];
        end
        for (tm_cap_i = 0; tm_cap_i < 8; tm_cap_i = tm_cap_i + 1)
            tm_pages[tm_cap_i] <= w_pages[tm_cap_i];
        for (tm_cap_i = 0; tm_cap_i < 2; tm_cap_i = tm_cap_i + 1) begin
            tm_scrollfracx[tm_cap_i] <= w_scrollfracx[tm_cap_i];
            tm_scrollfracy[tm_cap_i] <= w_scrollfracy[tm_cap_i];
            tm_zoomx[tm_cap_i] <= w_zoomx[tm_cap_i];
            tm_zoomy[tm_cap_i] <= w_zoomy[tm_cap_i];
        end
        for (tm_cap_i = 0; tm_cap_i < 20; tm_cap_i = tm_cap_i + 1)
            tm_clips[tm_cap_i] <= tm_clips_cdc[tm_cap_i];
    end
end

wire [5:0] tm_layer_off;
wire [21:3] tile_rom_addr;
s32_tilemap tilemap (
    .clk(clk_ram), .rst(rst),
    .line(tm_source_line), .line_start(line_start_r), .line_done(tm_line_done),
    .mode_416(tm_mode_416), .is_multi32(is_multi32), .ext_tilebank(tm_ext_tilebank), .layer_off_o(tm_layer_off),
    .r1ff00(tm_r1ff00), .r1ff02(tm_r1ff02), .r1ff04(tm_r1ff04), .r1ff06(tm_r1ff06),
    .r1ff5c(tm_r1ff5c), .r1ff5e(tm_r1ff5e),
    .r1ff88(tm_r1ff88), .r1ff8a(tm_r1ff8a), .r1ff8c(tm_r1ff8c), .r1ff8e(tm_r1ff8e),
    .scrollfracx(tm_scrollfracx), .scrollfracy(tm_scrollfracy),
    .scrollx(tm_scrollx), .scrolly(tm_scrolly),
    .offsx(tm_offsx), .offsy(tm_offsy),
    .pages(tm_pages), .zoomx(tm_zoomx), .zoomy(tm_zoomy), .clips(tm_clips),
    .vram_addr(vid_vaddr), .vram_rdata(vram_vid_q),
    .tile_req(sdr_p1_req), .tile_addr(tile_rom_addr),
    .tile_data(sdr_p1_dout), .tile_ack(sdr_p1_ack),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_x(tm_lb_x), .lb_pix(tm_lb_pix)
);
// The 4 MB tile region begins at the non-power-of-two-aligned 0x600000.
// Concatenating only the high address bits placed reads at 0x400000 and would
// fetch sound ROM on hardware; add the renderer's region-local row address.
assign sdr_p1_addr = SDR_TILES_BASE[24:3] + {3'b000, tile_rom_addr};

// sprite engine
wire [7:0] sprctl_q;
wire [1:0] disp_buf;
wire [1:0] spr_scan_buf;
s32_sprite #(
`ifdef S32_GOLDENAXE_ONLY
    .VERIFY_SROM(1'b1)
`else
    .VERIFY_SROM(1'b0)
`endif
) sprite (
    .clk(clk_ram), .rst(rst), .is_multi32(is_multi32),
    .screen_sel(screen_sel),
    // Old MRAs predate bank metadata and therefore retain the original
    // four-bank address space. New descriptors mirror 4/8 MiB ROMs exactly.
    .srom_bank_mask(cfg_sprite_bank_valid ? cfg_sprite_bank_mask : 2'b11),
    // Publish completed physical frames at VBLANK start, before the line-0
    // prefetch. MAME schedules logical erase/swap/render just after VBLANK
    // ends; GA2 builds its next list during VBLANK, so that trigger stays late.
    .present(vbl_start), .vblank(vbl_end), .rendering(debug_sprite_rendering),
    .debug_first_rom_desc(debug_sprite_desc),
    .debug_first_rom_valid(debug_sprite_desc_valid),
    .debug_last_desc(debug_sprite_last_desc),
    .debug_last_draw_desc(debug_sprite_last_draw_desc),
    .debug_activity(debug_sprite_activity),
    .debug_state(debug_sprite_state),
    .debug_counts(debug_sprite_counts),
    .ctl_we(wr_stb && m_we && sel_sprctl && m_be[0]),
    .ctl_addr(A[3:1]), .ctl_wdata(m_wdata[7:0]),
    .ctl_rdata(sprctl_q), .ctl_raddr(A[3:1]),
    .slist_addr(slist_addr), .slist_data(sprlist_q),
    .srom_req(sdr_p2_req), .srom_addr(sdr_p2_addr[23:4]),
    .srom_data(sdr_p2_dout), .srom_ack(sdr_p2_ack),
    .fb_wr_start(fb_wr_start), .fb_wr_buf(fb_wr_buf), .fb_wr_x(fb_wr_x),
    .fb_wr_y(fb_wr_y), .fb_wr_valid(fb_wr_valid), .fb_wr_pix(fb_wr_pix),
    .fb_wr_end(fb_wr_end),
    .fb_wr_shadow(fb_wr_shadow), .fb_busy(fb_wr_busy),
    .fb_er_req(fb_er_req), .fb_er_buf(fb_er_buf), .fb_er_y(fb_er_y),
    .fb_er_ack(fb_er_ack),
    .disp_buf(disp_buf), .scan_buf(spr_scan_buf)
);
assign sdr_p2_addr[24] = 1'b1;   // sprites region base 0x1000000

// TM-1: CRT/tilemap screen-width authority is VRAM $1FF00 bit 15, matching
// MAME screen_update_system32 / multi32_update, which set the visible area to
// 52*8 (416) when that bit is set and 40*8 (320) otherwise.  The sprite engine
// keeps its own width bit (ctl_latched[6][0]) for sprite-side clipping, exactly
// MAME's split (games program both consistently).  $1FF00 powers up 0x8000
// (bit 15 = 1 => 416), preserving the prior power-on default.
assign mode_416 = r1ff00[15];

// Sprite line prefetch for mixer. Hold the request and its address until the
// DDR service acknowledges it; a one-cycle pulse was lost whenever an erase
// or sprite write occupied the framebuffer engine.
reg       fb_rd_req_r;
reg [1:0] fb_rd_buf_r;
reg [7:0] fb_rd_y_r;
// Qualification telemetry: a line request still outstanding when its visible
// scanline starts means the mixer is consuming stale sprite data.  Keep this
// synthesizable and hierarchically visible without burdening the release I/O.
reg       fb_rd_underrun_sticky;
reg [15:0] fb_rd_underrun_count;
reg       fb_rd_deadline_seen;
// PF-6: surface the sprite line-fetch overrun telemetry for an OSD debug view.
// R = sticky "ever underran" flag, G:B = saturating underrun count.
assign debug_fb_underrun = {fb_rd_underrun_sticky ? 8'hff : 8'h00, fb_rd_underrun_count};
// Prefetch only lines that will actually display: kicks during vcnt 0-222
// fetch lines 1-223 and vcnt 261 fetches next frame's line 0.  The former
// ungated kick also ran through the 37 vblank lines, fetching nonexistent
// buffer rows 224-255 and wasting ~14% of the DDR line-read bandwidth (same
// rationale as the TM-5 tilemap vblank suppression).
wire fb_rd_kick = ce_pix && hcnt == (mode_416_active ? 9'd420 : 9'd324) &&
                  (vcnt < 9'd223 || vcnt == 9'd261);
wire fb_rd_deadline = ce_pix && hcnt == 9'd0 && vcnt < 9'd224;
always @(posedge clk_ram) begin
    if (rst) begin
        fb_rd_req_r <= 1'b0;
        fb_rd_buf_r <= 2'd0;
        fb_rd_y_r   <= 8'd0;
        fb_rd_underrun_sticky <= 1'b0;
        fb_rd_underrun_count <= 16'd0;
        fb_rd_deadline_seen <= 1'b0;
    end
    else begin
        if (!fb_rd_deadline) fb_rd_deadline_seen <= 1'b0;
        else if (!fb_rd_deadline_seen) begin
            fb_rd_deadline_seen <= 1'b1;
            if (fb_rd_req_r && !fb_rd_ack) begin
                fb_rd_underrun_sticky <= 1'b1;
                if (~&fb_rd_underrun_count)
                    fb_rd_underrun_count <= fb_rd_underrun_count + 1'd1;
            end
        end

        if (fb_rd_req_r) begin
            if (fb_rd_ack) fb_rd_req_r <= 1'b0;
        end
        else if (!fb_rd_ack && fb_rd_kick) begin
            fb_rd_req_r <= 1'b1;
            // The CPU-visible logical selector changes with MAME's delayed
            // sprite-controller update. Scanout uses the separately published
            // physical buffer, which changes only at a complete frame boundary.
            fb_rd_buf_r <= spr_scan_buf;
            // CRT lines are 0..261. Truncating line 261 before adding produced
            // line 6 instead of the next frame's line 0.
            if (vcnt == 9'd261)
                fb_rd_y_r <= cfg_flip_y ? 8'd223 : 8'd0;
            else if (cfg_flip_y && vcnt < 9'd223)
                fb_rd_y_r <= 8'd222 - vcnt[7:0];
            else
                fb_rd_y_r <= vcnt[7:0] + 8'd1;
        end
    end
end
assign fb_rd_req = fb_rd_req_r;
assign fb_rd_buf = fb_rd_buf_r;
assign fb_rd_y   = fb_rd_y_r;
assign fb_rd_x   = hcnt;

// mixers + palettes
// Screen B sprite line: per-monitor framebuffer fetch is a tracked deeper
// item; v1 shares screen A's fetched line so B's tilemaps/palette/mixer are
// nonetheless fully independent (the valuable part of B7).
wire [15:0] fb_rd_pix_b = fb_rd_pix;
wire [15:0] pal0_cpu_q, pal1_cpu_q;
wire [47:0] dbg_pal0_entries;
wire [13:0] mix0_pal_addr, mix1_pal_addr;
wire [15:0] mix0_pal_q, mix1_pal_q;
wire [15:0] mix0_q, mix1_q;
wire [15:0] mix0_r4e, mix1_r4e;
wire [13:0] mix_px_text, mix_px_nbg0, mix_px_nbg1;
wire [13:0] mix_px_nbg2, mix_px_nbg3, mix_px_bmp;

// Both current screen mixers consume the same tilemap-renderer stream.  Share
// the twelve physical parity/layer RAM banks and fan out their registered
// pixels; the mixers retain independent registers, palettes and RGB pipelines.
s32_linebuf shared_lbuf (
    .clk(clk_ram),
    .lb_we(tm_lb_we), .lb_layer(tm_lb_layer), .lb_wx(tm_lb_x),
    .lb_wpix(tm_lb_pix), .lb_bank(tm_lb_bank),
    .rd_x(hcnt), .rd_bank(vcnt[0]),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp)
);

s32_palette pal0 (
    .clk(clk_sys), .mix_clk(clk_ram),
    .cpu_we(m_req && m_we && is_pal0),
    .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
    .cpu_rdata(pal0_cpu_q), .mixer_r4e(mix0_r4e),
    .mix_addr(mix0_pal_addr), .mix_data(mix0_pal_q),
    .dbg_entries(dbg_pal0_entries)
);
assign debug_pal_rd = dbg_pal0_entries;

s32_mixer mix0 (
    .clk(clk_ram), .rst(rst),
    .reg_we(wr_stb && m_we && is_mix0),
    .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
    .reg_rdata(mix0_q), .reg_raddr(A[6:1]), .reg_r4e(mix0_r4e),
    .disp_x(mix_disp_x_cdc), .disp_y(vcnt), .disp_active(~hb & ~vb),
    .display_en(io0_cnt1), .flip_y(cfg_flip_y), .layer_off(tm_layer_off), .bg_ctrl(mix_bg_ctrl),
    .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
    .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
    .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
    .spr_pix(fb_rd_pix),
    .pal_addr(mix0_pal_addr), .pal_data(mix0_pal_q),
    .rgb(rgb_a)
);

generate
    if (SYSTEM32_ONLY) begin : g_system32_only_video
        // 0x680000/0x690000 are Multi 32-only windows, so System 32 reads
        // continue through the normal open-bus default in the CPU read mux.
        // Mirror A onto the unused output to keep the top-level screen selector
        // harmless for single-screen MRAs.
        assign pal1_cpu_q     = 16'hffff;
        assign mix1_q         = 16'hffff;
        assign mix1_r4e       = 16'h0000;
        assign mix1_pal_addr  = 14'h0000;
        assign mix1_pal_q     = 16'h0000;
        assign rgb_b          = rgb_a;
    end
    else begin : g_multi32_video
        // B7: Multi 32 second screen — palette bank 1 (0x680000) + mixer 1
        // (0x690000).  This branch remains available to a future Multi 32 QSF.
        s32_palette pal1 (
            .clk(clk_sys), .mix_clk(clk_ram),
            .cpu_we(m_req && m_we && is_pal1),
            .cpu_addr(A[15:1]), .cpu_wdata(m_wdata), .cpu_be(m_be),
            .cpu_rdata(pal1_cpu_q), .mixer_r4e(mix1_r4e),
            .mix_addr(mix1_pal_addr), .mix_data(mix1_pal_q),
            .dbg_entries()   // Multi 32 screen B not used by the holo diagnostic
        );
        s32_mixer mix1 (
            .clk(clk_ram), .rst(rst),
            .reg_we(wr_stb && m_we && is_mix1),
            .reg_addr(A[6:1]), .reg_wdata(m_wdata), .reg_be(m_be),
            .reg_rdata(mix1_q), .reg_raddr(A[6:1]), .reg_r4e(mix1_r4e),
            .disp_x(mix_disp_x_cdc), .disp_y(vcnt), .disp_active(~hb & ~vb),
            .display_en(io1_cnt1), .flip_y(cfg_flip_y), .layer_off(tm_layer_off), .bg_ctrl(mix_bg_ctrl),
            .px_text(mix_px_text), .px_nbg0(mix_px_nbg0),
            .px_nbg1(mix_px_nbg1), .px_nbg2(mix_px_nbg2),
            .px_nbg3(mix_px_nbg3), .px_bmp(mix_px_bmp),
            .spr_pix(fb_rd_pix_b),
            .pal_addr(mix1_pal_addr), .pal_data(mix1_pal_q),
            .rgb(rgb_b)
        );
    end
endgenerate

// ---------------------------------------------------------------------------
// sound subsystem
// ---------------------------------------------------------------------------
wire        snd_doorbell, snd_to_v60;
wire [15:0] sh_rdata;
wire [23:0] zrom_ba;
wire [21:0] mpcm_ba;

s32_soundsys #(.SYSTEM32_ONLY(SYSTEM32_ONLY), .MULTI32_ONLY(OUTRUNNERS_ONLY)) sound (
    .clk(clk_sys), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
    .rst(rst),
    .z80_reset(~io0_cnt2),
    .is_multi32(is_multi32),
    .sh_cs(m_req && sel_shared),
    .sh_we(m_we && sel_shared),
    .sh_addr(A[12:1]), .sh_be(m_be), .sh_wdata(m_wdata), .sh_rdata(sh_rdata),
    .v60_doorbell(snd_doorbell),
    .irq_to_v60(snd_to_v60),
    .zrom_req(sdr_p3_req), .zrom_addr(zrom_ba),
    .zrom_data(sdr_p3_dout), .zrom_ack(sdr_p3_ack),
    .mpcm_req(sdr_p4_req), .mpcm_addr(mpcm_ba),
    // Select the addressed byte from the 16-bit SDRAM word.  The MultiPCM ROM
    // bus is byte-wide; the old code always took the even lane, corrupting
    // every odd sample/descriptor byte (audit R20 AU-2).  mpcm_ba is held
    // stable by the MultiPCM engine until its req/ack completes.
    .mpcm_data(mpcm_ba[0] ? sdr_p4_dout[15:8] : sdr_p4_dout[7:0]),
    .mpcm_ack(sdr_p4_ack),
    .audio_l(audio_l), .audio_r(audio_r)
);
// B1: SDRAM address hookup for sound ports — add region bases so fetches
// land in the soundcpu / multipcm regions instead of address 0.
assign sdr_p3_addr = SDR_SOUNDCPU_BASE[24:1] + {1'b0, zrom_ba[23:1]};
assign sdr_p4_addr = SDR_MULTIPCM_BASE[24:1] + {3'b000, mpcm_ba[21:1]};

// ---------------------------------------------------------------------------
// IO-7: S32COMM shared RAM + host-side flip-flops. The communication board is
// present even with no link peer (OutRunners/Stadium Cross use 837-8792 with
// EPR-15033), so CN/FG are real registers rather than open bus. This models
// MAME's non-networked device path: the main CPU can enable CN and drive FG,
// while the absent comm-CPU/link partner leaves ZFG low. Only D[7:0] is mapped.
// ---------------------------------------------------------------------------
wire       sel_comm_ram = sel_comm && (A[15:12] == 4'h0);
wire       sel_comm_cn  = sel_comm && (A[15:0] == 16'h1000);
wire       sel_comm_fg  = sel_comm && (A[15:0] == 16'h1002);
// 2 KiB of S32COMM link-board share RAM.  Only 16,384 bits, but it lands in two
// whole M10Ks; on the M10K-bound Multi 32 revision the MLAB form is the better
// trade.  Single read port, single write port, and the read is registered.
`ifdef S32_LINEBUF_MLAB
(* ramstyle = "MLAB, no_rw_check" *)
`endif
reg [7:0]  comm_ram [0:2047];
reg [7:0]  comm_q;
reg        comm_cn, comm_fg, comm_zfg;
integer    comm_init_i;
initial begin
    for (comm_init_i = 0; comm_init_i < 2048; comm_init_i = comm_init_i + 1)
        comm_ram[comm_init_i] = 8'h00;
    comm_q = 8'h00;
    comm_cn = 1'b0;
    comm_fg = 1'b0;
    comm_zfg = 1'b0;
end
always @(posedge clk_sys) begin
    comm_q <= comm_ram[A[11:1]];
    if (m_req && m_we && sel_comm_ram && m_be[0])
        comm_ram[A[11:1]] <= m_wdata[7:0];
    if (rst) begin
        comm_cn   <= 1'b0;
        comm_fg   <= 1'b0;
        comm_zfg  <= 1'b0;
    end
    else if (m_req && m_we && m_be[0]) begin
        if (sel_comm_cn) begin
            comm_cn <= m_wdata[0];
            if (!m_wdata[0]) begin
                comm_fg  <= 1'b0;
                comm_zfg <= 1'b0;
            end
        end
        else if (sel_comm_fg && comm_cn)
            comm_fg <= m_wdata[0];
    end
end
wire [7:0] comm_cn_q = {7'h7f, comm_cn};
wire [7:0] comm_fg_q = {~comm_zfg, 6'h3f, comm_fg};
wire [15:0] comm_rdata = sel_comm_ram ? {8'hff, comm_q} :
                         sel_comm_cn  ? {8'hff, comm_cn_q} :
                         sel_comm_fg  ? {8'hff, comm_fg_q} : 16'hffff;
`ifdef SIMULATION
function automatic [7:0] comm_peek(input [10:0] addr);
    comm_peek = comm_ram[addr];
endfunction
`endif

// ---------------------------------------------------------------------------
// I/O chips + EEPROM
// ---------------------------------------------------------------------------
wire [7:0] io0_q, io1_q;
wire [7:0] io0_pd, io0_pg, io1_ph;
wire       eep_do;

s32_io5296 io0 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io0 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io0_q),
    .in_pa(in_p1a), .in_pb(in_p2a),
    .in_pc(in_portc),                          // B2: portc no longer carries EEPROM
    .in_pe(in_svc12),
    // EEPROM DO is on SERVICE34_A bit 7 for BOTH board families.  MAME's
    // multi32_generic inherits system32_generic's SERVICE34_A unchanged
    // (segas32.cpp:1354) and only ADDS the second copy on SERVICE34_B
    // (segas32.cpp:1438) — the 93C46 DO pin is wired to both 315-5296s.  The
    // earlier Multi 32 carve-out left io0 bit 7 stuck at 1, so any code path
    // that clocked the EEPROM through chip 1 but sampled it on chip 0 read
    // erased data forever.
    .in_pf({eep_do, in_svc34[6:0]}),
    .out_pd(io0_pd), .out_pg(io0_pg), .out_ph(io0_ph),
    .cnt0(), .cnt1(io0_cnt1), .cnt2(io0_cnt2)
);
assign out_lamps = io0_pd;

s32_io5296 io1 (
    .clk(clk_sys), .rst(rst),
    .cs(m_req && sel_io1 && m_be[0]), .we(m_we),
    .addr(A[5:1]), .wdata(m_wdata[7:0]), .rdata(io1_q),
    .in_pa(in_p1b), .in_pb(in_p2b), .in_pc(in_portc_b),
    // Multi 32 EEPROM DO is read on the SECOND I/O chip's SERVICE34_B bit 7
    // (MAME io_chip_1.in_pf = SERVICE34_B, do_read on bit 7); previously io1 got
    // constant 0xff there, so Multi 32 NVRAM boot never converged (audit R23-F1).
    .in_pe(in_svc12_b), .in_pf(is_multi32 ? {eep_do, in_svc34_b[6:0]} : in_svc34_b),
    .out_pd(), .out_pg(), .out_ph(io1_ph),
    // cnt1 = screen-B display enable (MAME io_chip_1 out_cnt1 -> display_enable_w<1>).
    .cnt0(), .cnt1(io1_cnt1), .cnt2()
);

// EEPROM wiring: S32 = io0 port D bits {7=DI,5=CS,6=CLK}; M32 = io1 port H
wire [7:0] eep_src = is_multi32 ? io1_ph : io0_pd;
s32_eeprom93c46 eeprom (
    .clk(clk_sys), .rst(rst),
    .di(eep_src[7]), .cs(eep_src[5]), .sk(eep_src[6]), .dout(eep_do),
    .ld_wr(eep_ld_wr), .ld_addr(eep_ld_addr), .ld_data(eep_ld_data),
    .rd_data(eep_rd_data), .rd_addr(eep_rd_addr),
    .upload(eep_upload), .modified(eep_modified)
);

// extended IO: ADC / trackballs / PPI
wire adc_bit;
wire [7:0] trk_q [0:2];
wire sel_adc   = sel_ioex && (A[5:3] == 3'b010) && cfg_has_adc;
wire sel_track = sel_ioex && (A[5:3] <= 3'b010) && cfg_has_track;
wire sel_ppi   = sel_ioex && (A[5:3] == 3'b100) && cfg_has_ppi;
genvar t;                         // declare outside the generate-for (Quartus 17.0)
generate
    if (GOLDENAXE_ONLY) begin : g_goldenaxe_no_analog
        // Golden Axe has no MSM6253 ADC or uPD4701 trackball board.
        assign adc_bit = 1'b1;
        for (t = 0; t < 3; t = t + 1) begin : tracks
            assign trk_q[t] = 8'hff;
        end
    end
    else if (GAME_ONLY && !OUTRUNNERS_ONLY) begin : g_game_no_analog
        // The trackball counters (sonic) stay compiled out of the dedicated
        // release, but the MSM6253 ADC is tiny and the gun/positional games on
        // this profile (alien3, jpark: descriptor has_adc=1) read their aim
        // through it at 0xC00050-57, so it is retained.  Non-ADC descriptors
        // gate sel_adc off and Quartus sweeps it as before.  System 32 games
        // never bank the analog mux (0xC00060 is Multi 32-only), so the four
        // fixed channels P1X/P1Y/P2X/P2Y match MAME's ANALOG1-4.  The dedicated
        // OutRunners profile is Multi 32 and therefore takes the banked path
        // below even though it is also a GAME_ONLY build.
        s32_msm6253 adc (
            .clk(clk_sys),
            .cs(m_req && sel_adc && m_be[0]), // 0xC00050-57
            .we(m_we), .addr(A[2:1]),
            .dout_bit(adc_bit),
            .an0(adc_ch[0]), .an1(adc_ch[1]),
            .an2(adc_ch[2]), .an3(adc_ch[3])
        );
        for (t = 0; t < 3; t = t + 1) begin : tracks
            assign trk_q[t] = 8'hff;
        end
    end
    else begin : g_extended_analog
        // Power up at bank 0 to match MAME device_start (m_analog_bank = 0);
        // System 32 analog games never write 0xC00060 so it would otherwise
        // stay X in simulation and undefined at cold boot (audit R20 IO-15).
        reg analog_bank = 1'b0;
        s32_msm6253 adc (
            .clk(clk_sys),
            .cs(m_req && sel_adc && m_be[0]), // 0xC00050-57
            .we(m_we), .addr(A[2:1]),
            .dout_bit(adc_bit),
            // MSM6253 inputs 0/1 are fixed ANALOG1/2. Only inputs 2/3 are
            // banked: bank 0 selects ANALOG3/4, bank 1 ANALOG7/8.
            .an0(adc_ch[0]), .an1(adc_ch[1]),
            .an2(adc_ch[analog_bank ? 6 : 2]),
            .an3(adc_ch[analog_bank ? 7 : 3])
        );
        always @(posedge clk_sys) begin
            if (rst)
                analog_bank <= 1'b0;
            else if (m_req && m_we && sel_ioex && m_be[0] && is_multi32 &&
                     A[5:0] == 6'h20)
                analog_bank <= m_wdata[0];   // 0xC00060 analog_bank_w
        end

        // The uPD4701 counters only exist on the SegaSonic trackball harness.
        // OutRunners takes this banked-ADC branch because it is Multi 32, but
        // its descriptor sets has_track=0, so the three counters are dead logic
        // in that revision.
        if (OUTRUNNERS_ONLY) begin : g_no_tracks
            for (t = 0; t < 3; t = t + 1) begin : tracks
                assign trk_q[t] = 8'hff;
            end
        end
        else begin : g_tracks
            for (t = 0; t < 3; t = t + 1) begin : tracks
                s32_upd4701 upd (
                    .clk(clk_sys), .rst(rst),
                    .delta_valid(trk_dv[t]), .dx(trk_dx[t]), .dy(trk_dy[t]),
                    .cs(m_req && sel_ioex && m_be[0] &&
                        cfg_has_track && A[5:3] == t[2:0]), // B4: 0x40/48/50
                    .we(m_we), .addr(A[2:1]),
                    .rdata(trk_q[t]), .buttons(trk_btn[t])
                );
            end
        end
    end
endgenerate

wire [7:0] ppi_q;
generate
    // The 8255 is the 4/6-player expansion board (ga2, spidman, harddunk).
    // OutRunners is a two-station driving cabinet with has_ppi=0, and sel_ppi
    // is already gated by cfg_has_ppi, so the chip is unreachable there.
    if (OUTRUNNERS_ONLY) begin : g_no_ppi
        assign ppi_q = 8'hff;
    end
    else begin : g_ppi
        s32_i8255 ppi (
            .clk(clk_sys),
            .cs(m_req && sel_ppi && m_be[0]),
            .we(m_we), .addr(A[2:1]), .wdata(m_wdata[7:0]), .rdata(ppi_q),
            .pa(ppi_pa), .pb(ppi_pb), .pc_in(ppi_pc), .pc_out()
        );
    end
endgenerate

// ---------------------------------------------------------------------------
// interrupt controller
// ---------------------------------------------------------------------------
wire [7:0] intc_q;
s32_intc intc (
    .clk(clk_sys), .rst(rst), .is_multi32(is_multi32),
    .cs(wr_stb && sel_intc), .we(m_we),
    .addr(A[3:1]), .be(m_be), .wdata(m_wdata), .rdata(intc_q),
    .vblank_start(vbl_start), .vblank_end(vbl_end),
    .sound_irq(snd_to_v60),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_taken(1'b0),
    .z80_doorbell(snd_doorbell)
);

// ---------------------------------------------------------------------------
// protection
// ---------------------------------------------------------------------------
wire        br_trap;
wire [15:0] br_trap_q;
wire [15:0] dsp_q, dual_q;
wire        prot_rom_req;
wire [23:0] prot_rom_addr;
wire        prot_rom_ack;
wire [15:0] prot_rom_data = sdr_p0_dout;
wire [7:0]  v25_q;

generate
    if (GAME_ONLY) begin : g_game_no_other_protection
        // Dedicated game profiles use only their selected board path.  Generic
        // HLE, Burning Rival and Air Rescue DSP protection are unreachable.
        assign pr_req = 1'b0;
        assign pr_we = 1'b0;
        assign pr_addr = 16'h0000;
        assign pr_wdata = 16'h0000;
        assign pr_be = 2'b00;
        assign br_trap = 1'b0;
        assign br_trap_q = 16'hffff;
        assign prot_rom_req = 1'b0;
        assign prot_rom_addr = 24'h000000;
        assign dsp_q = 16'hffff;
    end
    else begin : g_other_protection
        s32_prot_hle prot (
            .clk(clk_sys), .rst(rst), .prot_sel(cfg_prot_sel),
            .cpu_wr(m_req && m_we && (sel_wram || sel_prot_a)),
            .cpu_addr(A), .cpu_wdata(m_wdata),
            .vblank(vbl_start),
            .wram_req(pr_req), .wram_we(pr_we), .wram_addr(pr_addr),
            .wram_wdata(pr_wdata), .wram_be(pr_be),
            .wram_rdata(pr_q), .wram_ack(pr_ack),
            .rom_req(prot_rom_req), .rom_addr(prot_rom_addr),
            .rom_data(prot_rom_data), .rom_ack(prot_rom_ack)
        );

        s32_prot_brival brival (
            .clk(clk_sys), .rst(rst), .enable(cfg_prot_sel == PROT_BRIVAL),
            .cpu_wr(m_req && m_we && sel_prot_a),
            .cpu_addr(A), .cpu_wdata(m_wdata),
            .cpu_rd(m_req && !m_we && sel_wram), .cpu_be(m_be),
            .trap_active(br_trap), .trap_data(br_trap_q),
            .pram_we(), .pram_addr(), .pram_wdata(),
            .rom_req(), .rom_addr(), .rom_data(sdr_p0_dout), .rom_ack(1'b0)
        );

        s32_arescue_dsp dsp (
            .clk(clk_sys), .rst(rst), .enable(cfg_has_dsp_hle),
            .cs(m_req && sel_prot_a && A[15:4] == 0), .we(m_we),
            .addr(A[2:1]), .wdata(m_wdata), .rdata(dsp_q)
        );
    end
endgenerate

generate
    if (GAME_ONLY) begin : g_no_dualpcb
        // Dedicated profiles target single-board System 32 titles.  Keeping
        // this runtime-dead 4KB array cost 32,784 registers in Quartus 17
        // because its original
        // read/write shape did not infer block RAM.
        assign dual_q = 16'h0000;
    end
    else begin : g_dualpcb
        s32_dualpcb dual (
            .clk(clk_sys), .enable(cfg_dual_pcb),
            .cs_ram(m_req && sel_dual && !A[15]),
            // MAME serves the dual-PCB identity only at 0x818000-0x818003; the
            // rest of the 0x818000-0x81FFFF window reads open-bus (audit R20
            // IO-10a).  A[14:2]==0 selects the low id words.
            .cs_id(m_req && sel_dual && A[15] && A[14:2] == 13'd0),
            .we(m_we), .addr(A[11:1]), .wdata(m_wdata), .rdata(dual_q)
        );
    end
endgenerate

// Raw V25 core diagnostics (clk_v25 domain in the real build).  Declared before
// the instantiation so no implicit nets are inferred; the HLE build ties them
// off — its static tables are always "alive" so the flags carry no signal.
wire v25_dbg_ce_raw, v25_dbg_io_raw, v25_dbg_unm_raw;
`ifndef S32_REAL_V25
assign v25_dbg_ce_raw  = 1'b0;
assign v25_dbg_io_raw  = 1'b0;
assign v25_dbg_unm_raw = 1'b0;
`endif

// OutRunners is an unprotected Multi 32 board (MAME segas32.cpp marks the set
// "not protected", and gen_mra.py gives it has_v25=0), so the 317-xxxx socket
// and its 0xA00000 mailbox window are physically absent.  The HLE responder is
// otherwise instantiated unconditionally and carries a 2 KiB dual-port store
// plus its table ROM; with cfg_has_v25 tied low it can only ever return the
// open-bus value the read mux already substitutes for sel_v25.
`ifdef S32_OUTRUNNERS_ONLY
assign v25_q = 8'hff;
`else

`ifdef S32_REAL_V25
// V25 program-fetch address to SDRAM port 5 — declared before the instantiation
// that drives .rom_addr so no wrong-width implicit net is inferred (this path was
// previously never compiled; ModelSim/Verilator both reject the use-before-decl).
wire [15:3] v25_rom_addr;
wire        v25_p5_req;
wire        v25_first_valid;
wire [63:0] v25_first_data;
wire [15:3] v25_first_addr;

`ifdef S32_RELEASE_MINIMAL
// Release profiles start the V25 immediately. The full-image readback/hash is
// bring-up telemetry only; eliminating it removes the p5 requester mux/state
// and shortens core loading by roughly 4 ms without changing game-visible RAM.
wire        sweep_active = 1'b0;
wire        sweep_done   = 1'b1;
wire [12:0] sweep_line   = 13'd0;
wire        sweep_req_r  = 1'b0;
wire [23:0] sweep_hash   = 24'd0;
`else
// ---- MCU image checksum sweep (bring-up diagnostic) ------------------------
// After every reset release on a V25 board, read the whole 64 KiB program
// image back through the SAME SDRAM port 5 the V25 fetches from, folding it
// into a position-dependent 24-bit hash (rotate-left-1 then XOR of the three
// line thirds).  The V25 is held disabled (enable low) until the sweep hands
// the port over, so the two never contend; the V60 spends the ~4 ms polling
// the mailbox it would poll anyway.  The hash is shown in the Debug Video
// "V25" view and compared against the same fold computed offline from the
// descrambled ROM — a mismatch proves the image in external SDRAM is corrupt
// (the per-byte DQM-masked write path is used by nothing else in the design).
reg         sweep_active, sweep_done;
reg  [12:0] sweep_line;
reg         sweep_req_r, sweep_wait;
reg  [23:0] sweep_hash;
always @(posedge clk_sys) begin
    if (rst) begin
        sweep_active <= 1'b0; sweep_done <= 1'b0;
        sweep_line <= 13'd0; sweep_req_r <= 1'b0; sweep_wait <= 1'b0;
        sweep_hash <= 24'd0;
    end
    else if (!sweep_done && !sweep_active) begin
        if (cfg_has_v25) begin
            sweep_active <= 1'b1;
            sweep_line   <= 13'd0;
            sweep_hash   <= 24'd0;
            sweep_req_r  <= 1'b1;
            sweep_wait   <= 1'b1;
        end
        else sweep_done <= 1'b1;        // no V25: hand the port over at once
    end
    else if (sweep_active) begin
        sweep_req_r <= 1'b0;
        if (sweep_wait && sdr_p5_ack) begin
            sweep_hash <= {sweep_hash[22:0], sweep_hash[23]}
                        ^ sdr_p5_dout[23:0] ^ sdr_p5_dout[47:24]
                        ^ {8'h00, sdr_p5_dout[63:48]};
            sweep_wait <= 1'b0;
        end
        else if (!sweep_wait) begin
            if (sweep_line == 13'h1FFF) begin
                sweep_active <= 1'b0;
                sweep_done   <= 1'b1;
            end
            else begin
                sweep_line  <= sweep_line + 1'd1;
                sweep_req_r <= 1'b1;
                sweep_wait  <= 1'b1;
            end
        end
    end
end
`endif

s32_v25_cpu v25 (
    .clk_v25(clk_v25),
    .pause(pause),
`else
s32_v25 v25 (
`endif
`ifdef S32_REAL_V25
    .clk(clk_sys), .rst(rst), .enable(cfg_has_v25 && sweep_done),
`else
    .clk(clk_sys), .rst(rst), .enable(cfg_has_v25),
`endif
    .table_sel(cfg_v25_table),
    .prg_wr(v25_prg_wr), .prg_waddr(v25_prg_waddr), .prg_wdata(v25_prg_wdata),
`ifdef S32_REAL_V25
    .rom_req(v25_p5_req), .rom_addr(v25_rom_addr),
    .rom_data(sdr_p5_dout), .rom_ack(sdr_p5_ack && !sweep_active),
    .debug_cpu_clk(v25_dbg_ce_raw),
    .debug_io_seen(v25_dbg_io_raw),
    .debug_unmapped_seen(v25_dbg_unm_raw),
    .debug_first_fetch_valid(v25_first_valid),
    .debug_first_fetch_data(v25_first_data),
    .debug_first_fetch_addr(v25_first_addr),
`endif
    .cs(m_req && sel_v25 && cfg_has_v25 && m_be[0]), .we(m_we),
    .addr(A[11:1]), .wdata(m_wdata[7:0]), .rdata(v25_q)
);
`endif

// ---------------------------------------------------------------------------

`ifdef S32_REAL_V25
// Registered so the sweep/V25 mux + base add never sits combinationally on
// the clk_sys -> clk_ram controller crossing.  Both requesters tolerate the
// one-cycle latency (the bridge and the sweep wait on sdr_p5_ack levels).
reg        sdr_p5_req_r;
reg [24:3] sdr_p5_addr_r;
always @(posedge clk_sys) begin
    sdr_p5_req_r  <= sweep_active ? sweep_req_r : v25_p5_req;
    sdr_p5_addr_r <= SDR_MCU_BASE[24:3] +
                     (sweep_active ? {9'b0, sweep_line}
                                   : {9'b0, v25_rom_addr});
end
assign sdr_p5_req  = sdr_p5_req_r;
assign sdr_p5_addr = sdr_p5_addr_r;
`else
assign sdr_p5_req  = 1'b0;
assign sdr_p5_addr = '0;
`endif

// V60 ROM fetch via SDRAM p0, through a small I/D cache (perf):
//   32 lines x 8 bytes direct-mapped. Hit = 1 clk_sys; miss = 4 sequential
//   p0 word reads to fill the line. Reset (incl. ROM download) invalidates.
// ---------------------------------------------------------------------------
`ifdef S32_MLAB_ROM_CACHE
wire        rom_req_r;
wire [23:1] rom_addr_r;
`else
reg        rom_req_r;
reg [23:1] rom_addr_r;
`endif
// Transaction-acked flag (the read-mux ack register below).  Forward-declared
// here so the icache lookup can suppress re-arming a completed ROM read while
// the V60 bus still holds m_req; the driving logic lives in the read-mux block.
reg        ack_r;
`ifdef S32_MLAB_ROM_CACHE
// Both profiles that select this cache are unprotected builds: GAME_ONLY has
// already tied prot_rom_req low, so p0 has a single requester.
wire       prot_rom_grant = 1'b0;
`else
reg        prot_rom_grant;
`endif
wire [23:1] prot_p0_addr = {3'b000, prot_rom_addr[20:3], 2'b00};
assign prot_rom_ack = prot_rom_grant && sdr_p0_ack;
assign sdr_p0_req  = prot_rom_grant ? prot_rom_req : rom_req_r;
assign sdr_p0_addr = prot_rom_grant ? {2'b00, prot_p0_addr[21:1]} :
                                       {2'b00, rom_addr_r[21:1]};

`ifdef S32_MLAB_ROM_CACHE
// Dedicated-profile area cache. The generic asynchronous cache below provides a
// one-clk_sys hit, but its two variable-index read paths flatten 2,464 cache
// bits into registers and very wide muxes in Quartus 17. This implementation
// gives the dedicated profile one arbitrated synchronous lookup port. Because
// the V60/V70 advances only on ce_cpu (one clk_sys in three for Golden Axe, one
// in two-plus for OutRunners' 20 MHz V70), the extra raw clock of lookup
// latency remains inside one architectural CPU interval.
wire        rom_ready;
wire [15:0] rom_word_r;
s32_ga_rom_cache ga_rom_cache (
    .clk(clk_sys),
    .rst(rst),
    .invalidate(1'b0),
    .if_req(if_req),
    .if_line_addr((if_addr[23:20] == 4'hf)
                  ? {1'b0, if_addr[19:3]} : if_addr[20:3]),
    .if_offset(if_addr[2:0]),
    .if_data(if_data),
    .if_ack(if_served),
    .data_req(m_req && !m_we && (sel_rom || sel_romhi) && !ack_r),
    .data_addr(sel_romhi ? {1'b0, A[19:0]} : A[20:0]),
    .data_data(rom_word_r),
    .data_ack(rom_ready),
    .rom_req(rom_req_r),
    .rom_addr(rom_addr_r),
    .rom_data(sdr_p0_dout),
    .rom_ack(sdr_p0_ack)
);
`else
reg  [63:0] icache_data [0:31];
reg  [12:0] icache_tag  [0:31];      // addr[20:8]
reg  [31:0] icache_valid;

// MAME: map(0xf00000, 0xffffff).rom().region("maincpu", 0) — the top window
// mirrors the FIRST megabyte (the V60 reset stub at 0xFFFFF0 lives at
// maincpu offset 0xFFFF0). A[20:0] would fetch reset code from the wrong
// megabyte — found by real-ROM inspection (ga2: JMP $00100506 sits at
// 0x0FFFF0, data at 0x1FFFF0).
wire [20:0] rom_byte_a = sel_romhi ? {1'b0, A[19:0]} : A[20:0];
wire [4:0]  ic_line    = rom_byte_a[7:3];
wire [12:0] ic_tag     = rom_byte_a[20:8];
wire        ic_hit     = icache_valid[ic_line] && (icache_tag[ic_line] == ic_tag);
wire [63:0] ic_ldata   = icache_data[ic_line];
wire [15:0] ic_word    = ic_ldata[{rom_byte_a[2:1], 4'b0000} +: 16];

// Instruction-fetch lookup (whole 8-byte line).  Same romhi mirroring as data.
wire        if_romhi   = (if_addr[23:20] == 4'hF);
wire [20:0] if_byte_a  = if_romhi ? {1'b0, if_addr[19:3], 3'b000} : {if_addr[20:3], 3'b000};
wire [4:0]  if_line_ix = if_byte_a[7:3];
wire [12:0] if_tag_ix  = if_byte_a[20:8];
wire        if_hit     = icache_valid[if_line_ix] && (icache_tag[if_line_ix] == if_tag_ix);
// Pre-align the fetched line so byte 0 is the frontier byte (if_addr[2:0] = offset
// within the 8-byte line).  Doing the >>foff barrel shift HERE, on the icache read
// path, keeps it off the V60's tight execution clock domain (timing-closure guard).
wire [63:0] if_hit_data = icache_data[if_line_ix] >> {if_addr[2:0], 3'b000};

reg  [1:0]  fill_word;
reg         rom_filling;
reg         rom_ready;               // pulses when requested word available
reg  [15:0] rom_word_r;
// latched fill target: with two clients (data ROM read + instruction fetch) the
// live A/if_addr can change mid-fill, so the fill FSM uses its own latched line.
reg  [4:0]  fill_line;
reg  [12:0] fill_tag;
reg  [17:0] fill_wbase;              // 8-byte line address (byte_a[20:3])
reg         fill_isfetch;
reg  [1:0]  fill_dsel;               // data-read word select (byte_a[2:1])
reg  [2:0]  fill_foff;               // fetch intra-line offset (if_addr[2:0]) to align

// The rev. C Sonic protection responder is a second architectural client of
// the single main-ROM port.  Do not mux it by the live request level: a CPU
// line fill may already own p0, and SDRAM services each request only once per
// rising edge.  Wait for the CPU fill/request to become idle, latch the
// protection address through prot_p0_addr, and hold the grant until p0 ack.
always @(posedge clk_sys) begin
    if (rst)
        prot_rom_grant <= 1'b0;
    else if (prot_rom_grant) begin
        if (sdr_p0_ack) prot_rom_grant <= 1'b0;
    end
    else if (prot_rom_req && !rom_filling && !rom_req_r && !if_req &&
             !sdr_p0_ack)
        prot_rom_grant <= 1'b1;
end

always @(posedge clk_sys) begin
    if (rst) begin
        rom_req_r <= 0; rom_filling <= 0; rom_ready <= 0;
        icache_valid <= 32'h0;
        if_served <= 1'b0;
    end
    else begin
        rom_req_r <= 0;
        rom_ready <= 0;
        // re-arm the fetch port once the CPU drops if_req (having consumed if_ack)
        if (!if_req) if_served <= 1'b0;

        if (rom_filling) begin
            if (sdr_p0_ack) begin
                icache_data[fill_line][{fill_word, 4'b0000} +: 16] <= sdr_p0_dout;
                if (fill_word == 2'd3) begin
                    rom_filling <= 0;
                    icache_tag[fill_line]   <= fill_tag;
                    icache_valid[fill_line] <= 1'b1;
                    if (fill_isfetch) begin
                        // return the line (word 3 is on sdr_p0_dout now), pre-aligned
                        // by the latched offset so byte 0 is the frontier byte.
                        if_data   <= ({sdr_p0_dout, icache_data[fill_line][47:0]})
                                     >> {fill_foff, 3'b000};
                        if_served <= 1'b1;
                    end
                    else begin
                        rom_word_r <= (fill_dsel == 2'd3) ? sdr_p0_dout
                                     : icache_data[fill_line][{fill_dsel, 4'b0000} +: 16];
                        rom_ready  <= 1'b1;
                    end
                end
                else begin
                    fill_word  <= fill_word + 1'd1;
                    rom_req_r  <= 1'b1;
                    rom_addr_r <= {3'b000, fill_wbase, fill_word + 2'd1};
                end
            end
        end
        // instruction fetch has priority (it is the common ROM access)
        else if (if_req && !if_served) begin
            if (if_hit) begin
                if_data   <= if_hit_data;      // already aligned to the frontier byte
                if_served <= 1'b1;
            end
            else begin
                rom_filling  <= 1'b1;
                fill_isfetch <= 1'b1;
                fill_foff    <= if_addr[2:0];  // remember offset to align on completion
                fill_line    <= if_line_ix;
                fill_tag     <= if_tag_ix;
                fill_wbase   <= if_byte_a[20:3];
                fill_word    <= 0;
                rom_req_r    <= 1'b1;
                rom_addr_r   <= {3'b000, if_byte_a[20:3], 2'b00};
            end
        end
        // data ROM read (rare: constants/tables in ROM).  See !ack_r note above.
        else if (m_req && !m_we && (sel_rom || sel_romhi) && !rom_ready && !ack_r) begin
            if (ic_hit) begin
                rom_word_r <= ic_word;
                rom_ready  <= 1'b1;
            end
            else begin
                rom_filling  <= 1'b1;
                fill_isfetch <= 1'b0;
                fill_line    <= ic_line;
                fill_tag     <= ic_tag;
                fill_wbase   <= rom_byte_a[20:3];
                fill_dsel    <= rom_byte_a[2:1];
                fill_word    <= 0;
                rom_req_r    <= 1'b1;
                rom_addr_r   <= {3'b000, rom_byte_a[20:3], 2'b00};
            end
        end
    end
end
`endif

// ---------------------------------------------------------------------------
// CPU read mux + ack
// ---------------------------------------------------------------------------
reg [15:0] rmux;
assign m_rdata = rmux;
assign m_ack   = ack_r;   // ack_r declared with the ROM fetch regs above

// Random source for 0xD80000.  MAME returns machine().rand() (full-width,
// uncorrelated).  A 32-bit xorshift advanced every clk_sys — not just on the
// CPU clock-enable — plus a per-read fold decorrelates reads only a few CPU
// cycles apart, which a 1-bit-per-CPU-clock LFSR did not (audit R20 IO-13).
reg [31:0] rng = 32'h1357_9BDF;
always @(posedge clk_sys) begin
    logic [31:0] rx;
    rx  = rng ^ (rng << 13);
    rx  = rx  ^ (rx  >> 17);
    rng <= rx ^ (rx << 5);
end
wire [15:0] rng_read = rng[31:16] ^ rng[15:0];

reg ack_d;
reg rd_wait;   // BRAM/register reads: one dead cycle so the registered q
               // (wram_q, v25 rdata, io rdata, ...) reflects THIS address.
               // Without it rmux latches the previous access's data — the q
               // registers update on the same edge the ack mux samples them.
assign wr_stb = ack_r & ~ack_d;   // one-shot per transaction (for side-effect regs)
always @(posedge clk_sys) begin
    ack_d <= ack_r;
    if (!m_req) begin ack_r <= 0; rd_wait <= 0; end
    else if (!ack_r) begin
        if (sel_rom || sel_romhi) begin
            if (m_we) ack_r <= 1'b1;   // writes to ROM: ack + discard
            else if (rom_ready) begin rmux <= rom_word_r; ack_r <= 1'b1; end
        end
        else if (!m_we && !rd_wait) rd_wait <= 1'b1;
        else begin
            rd_wait <= 1'b0;
            ack_r <= 1'b1;   // BRAM/regs
            casez (1'b1)
                br_trap:     rmux <= br_trap_q;
                sel_wram:    rmux <= wram_q;
                sel_vram:    rmux <= vram_cpu_q;
                sel_sprram:  rmux <= sprram_q;
                sel_sprctl:  rmux <= {8'hff, sprctl_q};
                is_pal0:     rmux <= pal0_cpu_q;
                is_mix0:     rmux <= mix0_q;
                is_pal1:     rmux <= pal1_cpu_q;   // B7: Multi 32 screen B
                is_mix1:     rmux <= mix1_q;
                sel_shared:  rmux <= sh_rdata;
                // IO-7: byte-wide share RAM plus S32COMM CN/FG registers;
                // all other addresses in the page are open bus.
                sel_comm:    rmux <= comm_rdata;
                // Open-bus outside the comm RAM (A[15]=0) and the 4-byte id
                // window (A[15] && A[14:2]==0); the module holds stale rdata
                // when neither chip-select fires (audit R20 IO-10a).
                sel_dual:    rmux <= (cfg_dual_pcb &&
                                      (!A[15] || A[14:2] == 13'd0)) ? dual_q
                                                                    : 16'hffff;
                sel_v25:     if (GAME_ONLY)
                                 // Open-bus when this board has no V25 (holo,
                                 // spidman): MAME leaves 0xA00000 unmapped
                                 // (audit R20 PF-7).
                                 rmux <= cfg_has_v25 ? {8'hff, v25_q} : 16'hffff;
                             else
                                 rmux <= cfg_has_v25 ? {8'hff, v25_q} :
                                         cfg_has_dsp_hle ? dsp_q : 16'hffff;
                sel_prot_a:  rmux <= cfg_has_dsp_hle ? dsp_q : 16'hffff;
                sel_io0:     rmux <= {8'hff, io0_q};
                sel_io1:     rmux <= {8'hff, io1_q};
                sel_ioex:    if (GAME_ONLY)
                                 // MSM6253 serial output on D7 (audit R20
                                 // IO-3), same as the universal profile.
                                 rmux <= sel_adc ? {8'hff, adc_bit, 7'h7f} :
                                         sel_ppi ? {8'hff, ppi_q} : 16'hffff;
                             else
                                 // MSM6253 serial output is wired to D7, not
                                 // D0 (MAME msm6253 d7_r); audit R20 IO-3.
                                 rmux <= sel_adc   ? {8'hff, adc_bit, 7'h7f} :
                                         sel_track ? {8'hff, trk_q[A[4]?2:(A[3]?1:0)]} :
                                         sel_ppi   ? {8'hff, ppi_q} : 16'hffff;
                sel_intc:    rmux <= {8'hff, intc_q};
                sel_rand:    rmux <= rng_read;
                default:     rmux <= 16'hffff;
            endcase
        end
    end
end

// V25 bring-up diagnostic (Debug Video "V25").  Classifies the V25-game
// black screen from the V60-visible mailbox plus three synchronised core
// flags, without touching operation:
//   - never executes  -> io_seen stays 0 and every V60 mailbox read is 0x00
//   - executes garbage-> io/unmapped flags set but no wake string appears
//   - V25 healthy     -> byte 0xA00100 reads 'w' (0x77): wake string present
// mb_last samples exactly when the read mux does (rd_wait cycle), so it shows
// the byte the V60 actually consumed.
reg  [23:0] dbg_v25_ce_cnt;                 // ~10MHz CE pulses; [23:20] blink
reg  [7:0]  dbg_v25_mb_last;                // last V60 read of byte 0xA00100
reg  [7:0]  dbg_v25_rd_cnt;                 // V60 mailbox reads (proves polling)
reg         dbg_v25_mb_nonzero, dbg_v25_wake;
reg         v25_dbg_ce_s1, v25_dbg_ce_s2, v25_dbg_ce_s3;
reg         v25_dbg_io_s1, v25_dbg_io_s2;
reg         v25_dbg_unm_s1, v25_dbg_unm_s2;
wire        v25_dbg_rd_sample = m_req && !m_we && sel_v25 && cfg_has_v25 &&
                                m_be[0] && !ack_r && rd_wait;
always @(posedge clk_sys) begin
    if (rst) begin
        dbg_v25_ce_cnt     <= 24'd0;
        dbg_v25_mb_last    <= 8'h00;
        dbg_v25_rd_cnt     <= 8'd0;
        dbg_v25_mb_nonzero <= 1'b0;
        dbg_v25_wake       <= 1'b0;
    end
    else begin
        // CE pulses are one clk_v25 (~41ns) wide, so 48MHz sampling sees each.
        if (v25_dbg_ce_s2 && !v25_dbg_ce_s3) dbg_v25_ce_cnt <= dbg_v25_ce_cnt + 1'b1;
        if (v25_dbg_rd_sample) begin
            dbg_v25_rd_cnt <= dbg_v25_rd_cnt + 1'b1;
            if (v25_q != 8'h00) dbg_v25_mb_nonzero <= 1'b1;
            if (A[11:1] == 11'h080) begin       // mailbox byte 0xA00100
                dbg_v25_mb_last <= v25_q;
                if (v25_q == 8'h77) dbg_v25_wake <= 1'b1;   // 'w'ake up!
            end
        end
    end
end
always @(posedge clk_sys) begin
    v25_dbg_ce_s1  <= v25_dbg_ce_raw;  v25_dbg_ce_s2  <= v25_dbg_ce_s1;
    v25_dbg_ce_s3  <= v25_dbg_ce_s2;
    v25_dbg_io_s1  <= v25_dbg_io_raw;  v25_dbg_io_s2  <= v25_dbg_io_s1;
    v25_dbg_unm_s1 <= v25_dbg_unm_raw; v25_dbg_unm_s2 <= v25_dbg_unm_s1;
end
assign debug_v25 = {dbg_v25_ce_cnt[23:20], dbg_v25_wake, dbg_v25_mb_nonzero,
                    v25_dbg_unm_s2, v25_dbg_io_s2,
                    dbg_v25_rd_cnt, dbg_v25_mb_last};
`ifdef S32_REAL_V25
assign debug_v25_img = {sweep_done, v25_first_valid, sweep_hash, v25_first_data};
`else
assign debug_v25_img = 90'd0;
`endif

// Sticky boot-progress telemetry for first-hardware bring-up. A screenshot of
// the diagnostic modes preserves enough state to locate a boot stall without
// requiring SignalTap or changing CPU/memory timing.
reg [23:0] debug_status_r;
reg [15:0] debug_first_rom_r;
reg        debug_first_rom_seen;
reg [15:0] debug_bus_wait;
reg [23:0] debug_prev_pc_r;
reg [23:0] debug_pc_seen_r;
reg [23:0] debug_pc_hist0_r;
reg [23:0] debug_pc_hist1_r;
reg [23:0] debug_pc_hist2_r;
reg [23:0] debug_pc_hist3_r;
reg [23:0] debug_pc_hist4_r;
reg  [7:0] debug_last_irq_vector_r;
reg [23:0] debug_halt_trace_rgb;

// If the CPU halts unexpectedly, expose eight compact post-mortem clues as
// 8-pixel bands. The top-level displays one 64-pixel strip over the otherwise
// unchanged game image, while debug mode 2 repeats the trace across the screen:
//   current PC, previous PC, five older PCs, last/current IRQ vectors.
always @(*) begin
    case (hcnt[5:3])
        3'd0: debug_halt_trace_rgb = v60_debug_pc[23:0];
        3'd1: debug_halt_trace_rgb = debug_prev_pc_r;
        3'd2: debug_halt_trace_rgb = debug_pc_hist0_r;
        3'd3: debug_halt_trace_rgb = debug_pc_hist1_r;
        3'd4: debug_halt_trace_rgb = debug_pc_hist2_r;
        3'd5: debug_halt_trace_rgb = debug_pc_hist3_r;
        3'd6: debug_halt_trace_rgb = debug_pc_hist4_r;
        default: debug_halt_trace_rgb = {8'h00, debug_last_irq_vector_r, irq_vector};
    endcase
end

assign debug_status = v60_debug_halted ? debug_halt_trace_rgb : debug_status_r;
assign debug_first_rom = v60_debug_halted ?
                         {debug_last_irq_vector_r, irq_vector} :
                         debug_first_rom_r;

always @(posedge clk_sys) begin
    if (rst) begin
        debug_status_r       <= 24'h000000;
        debug_first_rom_r    <= 16'h0000;
        debug_first_rom_seen <= 1'b0;
        debug_bus_wait       <= 16'h0000;
        debug_prev_pc_r      <= 24'hfffff0;
        debug_pc_seen_r      <= 24'hfffff0;
        debug_pc_hist0_r     <= 24'hfffff0;
        debug_pc_hist1_r     <= 24'hfffff0;
        debug_pc_hist2_r     <= 24'hfffff0;
        debug_pc_hist3_r     <= 24'hfffff0;
        debug_pc_hist4_r     <= 24'hfffff0;
        debug_last_irq_vector_r <= 8'hff;
    end
    else begin
        if (v60_debug_pc[23:0] != debug_pc_seen_r) begin
            debug_pc_hist4_r <= debug_pc_hist3_r;
            debug_pc_hist3_r <= debug_pc_hist2_r;
            debug_pc_hist2_r <= debug_pc_hist1_r;
            debug_pc_hist1_r <= debug_pc_hist0_r;
            debug_pc_hist0_r <= debug_prev_pc_r;
            debug_prev_pc_r  <= debug_pc_seen_r;
            debug_pc_seen_r  <= v60_debug_pc[23:0];
        end
        // Sampling while the controller asserts IRQ avoids routing the CPU's
        // otherwise-unused irq_ack hierarchy output, which Quartus 17 crashes
        // while elaborating. The value still identifies the selected source.
        if (!irq_n)
            debug_last_irq_vector_r <= irq_vector;

        debug_status_r[0] <= 1'b1;
        if (c_req)       debug_status_r[1]  <= 1'b1;
        if (c_ack)       debug_status_r[2]  <= 1'b1;
        if (m_req)       debug_status_r[3]  <= 1'b1;
        if (m_ack)       debug_status_r[4]  <= 1'b1;
        if (sdr_p0_req)  debug_status_r[5]  <= 1'b1;
        if (sdr_p0_ack)  debug_status_r[6]  <= 1'b1;
        // Architectural reset PC is 32'hFFFFFFF0 (START_PC); the old 32-bit
        // compare against 00FFFFF0 never matched, so bit 7 ("PC left the reset
        // vector") was stuck on from the first cycle.  Compare the bus-visible
        // 24 bits, which is what the mirror decode actually fetches from.
        if (v60_debug_pc[23:0] != 24'hfffff0)
            debug_status_r[7] <= 1'b1;
        if (v60_debug_pc < 32'h00200000)
            debug_status_r[8] <= 1'b1;
        if (m_req && m_we && sel_wram) debug_status_r[9]  <= 1'b1;
        if (m_req && m_we && sel_vram) debug_status_r[10] <= 1'b1;
        if (m_req && m_we && is_pal0)  debug_status_r[11] <= 1'b1;
        if (m_req && m_we && sel_io0)  debug_status_r[12] <= 1'b1;
        if (m_req && m_we && sel_intc) debug_status_r[13] <= 1'b1;
        if (io0_cnt1)                  debug_status_r[14] <= 1'b1;
        if (v60_debug_halted)          debug_status_r[15] <= 1'b1;
        if (sdr_p1_req)                debug_status_r[16] <= 1'b1;
        if (sdr_p1_ack)                debug_status_r[17] <= 1'b1;
        if (sdr_p2_req)                debug_status_r[18] <= 1'b1;
        if (sdr_p2_ack)                debug_status_r[19] <= 1'b1;
        if (vbl_start)                 debug_status_r[20] <= 1'b1;
        if (!irq_n)                    debug_status_r[21] <= 1'b1;
        // Runaway-PC detector.  Exclude the 16-byte architectural reset-vector
        // window FFFFFFF0-FFFFFFFF (the only legitimate PC with a non-zero
        // upper byte); the unqualified check fired at reset on every boot.
        if (v60_debug_pc[31:24] != 8'h00 && v60_debug_pc[31:4] != 28'hFFFFFFF)
            debug_status_r[22] <= 1'b1;

        if (m_req && !m_ack) begin
            if (!(&debug_bus_wait)) debug_bus_wait <= debug_bus_wait + 1'd1;
            if (&debug_bus_wait)  debug_status_r[23] <= 1'b1;
        end
        else debug_bus_wait <= 16'h0000;

        if (sdr_p0_ack && !debug_first_rom_seen) begin
            debug_first_rom_seen <= 1'b1;
            debug_first_rom_r    <= sdr_p0_dout;
        end
    end
end

endmodule
//============================================================================
// Golden Axe main-ROM cache: 32 direct-mapped 8-byte lines.
//
// A single synchronous lookup port is sufficient because instruction fetches
// have priority and the V60 data bus holds a request until acknowledge. The
// whole line is committed after the fourth SDRAM beat, avoiding partial writes
// so Quartus can implement {tag,data} as four 32x20 MLAB lanes. Valid bits stay
// outside the memory so reset/invalidation remains a one-cycle operation.
//============================================================================
module s32_ga_rom_cache (
    input              clk,
    input              rst,
    input              invalidate,

    input              if_req,
    input       [20:3] if_line_addr,
    input        [2:0] if_offset,
    output reg  [63:0] if_data,
    output reg         if_ack,

    input              data_req,
    input       [20:0] data_addr,
    output reg  [15:0] data_data,
    output reg         data_ack,

    output reg         rom_req,
    output reg  [23:1] rom_addr,
    input       [15:0] rom_data,
    input              rom_ack
);

// 32 x 77 = 2,464 bits. Cyclone V MLABs support a synchronous 32-word read;
// keeping the validity vector separate avoids a reset loop on the RAM itself.
(* ramstyle = "MLAB" *) reg [76:0] cache_mem [0:31]; // {tag[12:0], data[63:0]}
reg [76:0] cache_q;
reg [31:0] cache_valid;

reg        lookup_pending;
reg        lookup_fetch;
reg  [4:0] lookup_index;
reg [12:0] lookup_tag;
reg [17:0] lookup_line_addr;
reg  [2:0] lookup_if_offset;
reg  [1:0] lookup_data_word;

reg        filling;
reg        fill_discard;
reg        fill_fetch;
reg  [4:0] fill_index;
reg [12:0] fill_tag;
reg [17:0] fill_line_addr;
reg  [2:0] fill_if_offset;
reg  [1:0] fill_data_word;
reg  [1:0] fill_word;
reg [63:0] fill_data;

wire choose_fetch = if_req && !if_ack;
wire choose_data  = !choose_fetch && data_req && !data_ack;
wire launch_lookup = !lookup_pending && !filling && (choose_fetch || choose_data);
wire [4:0] lookup_mem_addr = lookup_pending ? lookup_index :
                              choose_fetch ? if_line_addr[7:3] : data_addr[7:3];
wire [63:0] completed_line = {rom_data, fill_data[47:0]};
wire cache_commit = filling && rom_ack && (fill_word == 2'd3) &&
                    !fill_discard && !invalidate && !rst;

function automatic [15:0] select_word(
    input [63:0] line,
    input  [1:0] word_sel
);
begin
    case (word_sel)
        2'd0: select_word = line[15:0];
        2'd1: select_word = line[31:16];
        2'd2: select_word = line[47:32];
        default: select_word = line[63:48];
    endcase
end
endfunction

// Synchronous read plus one full-line write port. There is no asynchronous
// array read and no partial array write, the two shapes that flattened the old
// cache into ALMs in Quartus 17.
always @(posedge clk) begin
    cache_q <= cache_mem[lookup_mem_addr];
    if (cache_commit)
        cache_mem[fill_index] <= {fill_tag, completed_line};
end

always @(posedge clk) begin
    if (rst) begin
        cache_valid      <= 32'd0;
        lookup_pending   <= 1'b0;
        lookup_fetch     <= 1'b0;
        lookup_index     <= 5'd0;
        lookup_tag       <= 13'd0;
        lookup_line_addr <= 18'd0;
        lookup_if_offset <= 3'd0;
        lookup_data_word <= 2'd0;
        filling          <= 1'b0;
        fill_discard     <= 1'b0;
        fill_fetch       <= 1'b0;
        fill_index       <= 5'd0;
        fill_tag         <= 13'd0;
        fill_line_addr   <= 18'd0;
        fill_if_offset   <= 3'd0;
        fill_data_word   <= 2'd0;
        fill_word        <= 2'd0;
        fill_data        <= 64'd0;
        if_data          <= 64'd0;
        if_ack           <= 1'b0;
        data_data        <= 16'hffff;
        data_ack         <= 1'b0;
        rom_req          <= 1'b0;
        rom_addr         <= 23'd0;
    end
    else begin
        rom_req <= 1'b0;
        if (!if_req)   if_ack   <= 1'b0;
        if (!data_req) data_ack <= 1'b0;

        if (invalidate) begin
            cache_valid    <= 32'd0;
            lookup_pending <= 1'b0;
            if_ack          <= 1'b0;
            data_ack        <= 1'b0;
            if (filling) begin
                if (rom_ack) begin
                    filling      <= 1'b0;
                    fill_discard <= 1'b0;
                end
                else begin
                    fill_discard <= 1'b1;
                end
            end
            else begin
                fill_discard <= 1'b0;
            end
        end
        else if (filling) begin
            if (rom_ack) begin
                if (fill_discard) begin
                    // Drain one response from an invalidated transaction and
                    // abandon the rest of that line. A held requester retries.
                    filling      <= 1'b0;
                    fill_discard <= 1'b0;
                end
                else begin
                    case (fill_word)
                        2'd0: fill_data[15:0]  <= rom_data;
                        2'd1: fill_data[31:16] <= rom_data;
                        2'd2: fill_data[47:32] <= rom_data;
                        default: fill_data[63:48] <= rom_data;
                    endcase
                    if (fill_word == 2'd3) begin
                        cache_valid[fill_index] <= 1'b1;
                        filling <= 1'b0;
                        if (fill_fetch) begin
                            if_data <= completed_line >> {fill_if_offset, 3'b000};
                            if_ack  <= 1'b1;
                        end
                        else begin
                            data_data <= select_word(completed_line, fill_data_word);
                            data_ack  <= 1'b1;
                        end
                    end
                    else begin
                        fill_word <= fill_word + 1'd1;
                        rom_addr  <= {3'b000, fill_line_addr, fill_word + 2'd1};
                        rom_req   <= 1'b1;
                    end
                end
            end
        end
        else if (lookup_pending) begin
            lookup_pending <= 1'b0;
            if (cache_valid[lookup_index] && cache_q[76:64] == lookup_tag) begin
                if (lookup_fetch) begin
                    if_data <= cache_q[63:0] >> {lookup_if_offset, 3'b000};
                    if_ack  <= 1'b1;
                end
                else begin
                    data_data <= select_word(cache_q[63:0], lookup_data_word);
                    data_ack  <= 1'b1;
                end
            end
            else begin
                filling        <= 1'b1;
                fill_discard   <= 1'b0;
                fill_fetch     <= lookup_fetch;
                fill_index     <= lookup_index;
                fill_tag       <= lookup_tag;
                fill_line_addr <= lookup_line_addr;
                fill_if_offset <= lookup_if_offset;
                fill_data_word <= lookup_data_word;
                fill_word      <= 2'd0;
                fill_data      <= 64'd0;
                rom_addr       <= {3'b000, lookup_line_addr, 2'b00};
                rom_req        <= 1'b1;
            end
        end
        else if (launch_lookup) begin
            lookup_pending <= 1'b1;
            lookup_fetch   <= choose_fetch;
            if (choose_fetch) begin
                lookup_index     <= if_line_addr[7:3];
                lookup_tag       <= if_line_addr[20:8];
                lookup_line_addr <= if_line_addr;
                lookup_if_offset <= if_offset;
                lookup_data_word <= 2'd0;
            end
            else begin
                lookup_index     <= data_addr[7:3];
                lookup_tag       <= data_addr[20:8];
                lookup_line_addr <= data_addr[20:3];
                lookup_if_offset <= 3'd0;
                lookup_data_word <= data_addr[2:1];
            end
        end
    end
end

endmodule
