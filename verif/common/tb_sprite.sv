//============================================================================
//  Directed test: s32_sprite pixel path (V-8 exact pen semantics)
//   1. 1:1 4bpp direct draw: nibble order (bits31:28 leftmost), positions
//   2. pen 0 never drawn (direct); pen F transparent only first/last of word
//   3. end code: word ending in F terminates the row (next word not drawn)
//   4. flipx: destination sweep reversed, source order preserved
//   5. 2x horizontal zoom: each source pixel doubled
//   6. indirect (inline table): transmask decides transparency, entry drawn
//   7. shadow sprite: run flagged fb_wr_shadow
//   8. even-width center alignment uses (dstw-1)/2
//   9. alignment code 3 aliases center, matching the controller
//  10. from-RAM pixel source uses the controller's 32-bit byte repacking
//  11. clip-out persists across a later clip-in-only command
//  12. signed position + JUMP offset does not wrap in the 12-bit domain
//  13. MAME-exact 16.16 horizontal zoom source selection
//  14. latched sprite-control global X/Y flip mirrors the framebuffer scan
//  15. self-referential JUMP is bounded to 8192 commands (no frame freeze)
//  16. hardware diagnostics capture CPU writes, descriptors, activity and
//      saturating command counters without changing the renderer path
//============================================================================
`timescale 1ns/1ps

module tb_sprite;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// control port
reg       ctl_we = 0;
reg [2:0] ctl_addr = 0;
reg [7:0] ctl_wdata = 0;
reg [2:0] ctl_raddr = 0;
wire [7:0] ctl_rdata;

// sprite RAM model (registered read, 1-clk lag like s32_core)
reg [15:0] sram [0:65535];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr];

// sprite ROM model: 128-bit chunks indexed by chunk address
reg [127:0] rom128 [0:255];
wire        srom_req;
wire [23:4] srom_addr;
reg         srom_ack;
reg [127:0] srom_data;
always @(posedge clk) begin
    srom_ack  <= srom_req;
    srom_data <= rom128[srom_addr[11:4]];
end

// framebuffer capture
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow;
wire [8:0]  fbw_x;
wire [7:0]  fbw_y;
wire [15:0] fbw_pix;
wire        fbe_req;
wire [1:0]  fbe_buf;
wire [7:0]  fbe_y;
reg         fbe_ack;
always @(posedge clk) fbe_ack <= fbe_req;
integer erase_count_0 = 0;
integer erase_count_1 = 0;
always @(posedge clk) begin
    if (fbe_req && fbe_ack) begin
        if (fbe_buf[1]) erase_count_1 = erase_count_1 + 1;
        else            erase_count_0 = erase_count_0 + 1;
    end
end

reg [15:0] fbcap [0:511];       // pixel values by x (single test row)
reg        fbsh  [0:511];       // captured with shadow flag
reg  [7:0] fbycap [0:511];       // captured output row by x
integer    fbcnt = 0;
reg        run_shadow = 0;
integer ci;
always @(posedge clk) begin
    if (fbw_start) run_shadow <= fbw_shadow;
    if (fbw_valid) begin
        fbcap[fbw_x] <= fbw_pix;
        fbsh[fbw_x]  <= run_shadow | fbw_shadow;
        fbycap[fbw_x] <= fbw_y;
        fbcnt = fbcnt + 1;
    end
end

reg vblank = 0;
reg is_multi32 = 0;
reg [1:0] srom_bank_mask = 2'b11;
wire        dbg_rendering;
wire [127:0] dbg_first_desc;
wire         dbg_first_valid;
wire [127:0] dbg_last_desc;
wire [127:0] dbg_last_draw_desc;
wire  [23:0] dbg_activity;
wire  [31:0] dbg_state;
wire  [63:0] dbg_counts;

reg         cpu_dbg_we = 0;
reg  [15:0] cpu_dbg_addr = 0;
reg  [15:0] cpu_dbg_data = 0;
reg   [1:0] cpu_dbg_be = 0;
wire        cpu_dbg_seen;
wire  [7:0] cpu_dbg_count;
wire [15:0] cpu_dbg_last_addr;
wire [15:0] cpu_dbg_last_data;
wire  [1:0] cpu_dbg_last_be;
s32_sprite_write_debug cpu_write_debug (
    .clk(clk), .rst(rst), .wr_stb(cpu_dbg_we),
    .wr_addr(cpu_dbg_addr), .wr_data(cpu_dbg_data), .wr_be(cpu_dbg_be),
    .seen(cpu_dbg_seen), .count(cpu_dbg_count),
    .last_addr(cpu_dbg_last_addr), .last_data(cpu_dbg_last_data),
    .last_be(cpu_dbg_last_be)
);

s32_sprite #(.POST_VBLANK_CYCLES(4)) dut (
    .clk(clk), .rst(rst), .is_multi32(is_multi32), .screen_sel(1'b0),
    .srom_bank_mask(srom_bank_mask),
    .present(vblank), .vblank(vblank), .rendering(dbg_rendering),
    .debug_first_rom_desc(dbg_first_desc),
    .debug_first_rom_valid(dbg_first_valid),
    .debug_last_desc(dbg_last_desc),
    .debug_last_draw_desc(dbg_last_draw_desc),
    .debug_activity(dbg_activity), .debug_state(dbg_state),
    .debug_counts(dbg_counts),
    .ctl_we(ctl_we), .ctl_addr(ctl_addr), .ctl_wdata(ctl_wdata),
    .ctl_rdata(ctl_rdata), .ctl_raddr(ctl_raddr),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(), .fb_wr_x(fbw_x), .fb_wr_y(fbw_y),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_busy(1'b0),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y), .fb_er_ack(fbe_ack),
    .disp_buf(), .scan_buf()
);

// write one list entry (8 words at entry*8)
task entry(input [12:0] e, input [15:0] w0, w1, w2, w3, w4, w5, w6, w7);
    sram[{e, 3'd0}]      = w0; sram[{e, 3'd0} + 1] = w1;
    sram[{e, 3'd0} + 2]  = w2; sram[{e, 3'd0} + 3] = w3;
    sram[{e, 3'd0} + 4]  = w4; sram[{e, 3'd0} + 5] = w5;
    sram[{e, 3'd0} + 6]  = w6; sram[{e, 3'd0} + 7] = w7;
endtask

task wctl(input [2:0] a, input [7:0] d);
    @(posedge clk); ctl_we <= 1; ctl_addr <= a; ctl_wdata <= d;
    @(posedge clk); ctl_we <= 0;
endtask

integer errors = 0;
// run one frame: pulse vblank, wait for the walker to finish
task frame;
    integer k;
    for (k = 0; k < 512; k = k + 1) begin
        fbcap[k] = 16'hFFFF; fbsh[k] = 0; fbycap[k] = 8'hff;
    end
    fbcnt = 0;
    @(posedge clk); vblank <= 1;
    @(posedge clk); vblank <= 0;
    // The delayed event may spend one cycle publishing the completed back
    // buffer before it begins erasing the now-hidden old front buffer.
    for (k = 0; k < 4; k = k + 1) begin
        @(posedge clk); #1;
        if (fbe_req) begin
            errors = errors + 1;
            $display("  FAIL sprite command started before post-VBLANK delay");
        end
    end
    for (k = 0; k < 3 && !fbe_req; k = k + 1) begin
        @(posedge clk); #1;
    end
    if (!fbe_req) begin
        errors = errors + 1;
        $display("  FAIL sprite command missing after post-VBLANK delay");
    end
    ctl_raddr = 3'd0; #1;
    if (ctl_rdata[1] !== 1'b0) begin
        errors = errors + 1;
        $display("  FAIL ctl0 exposed non-MAME erase-busy bit: %02x", ctl_rdata);
    end
    wait (dut.rendering === 1'b1);
    wait (dut.rendering === 1'b0);
    repeat (8) @(posedge clk);
endtask

task check(input [8:0] x, input [15:0] want);
    if (fbcap[x] !== want) begin
        errors = errors + 1;
        $display("  FAIL x=%0d pix=%04x want=%04x", x, fbcap[x], want);
    end
endtask

task expect_skipped_frame;
    reg [7:0] swaps_before;
    integer k;
    begin
        swaps_before = dbg_counts[7:0];
        @(posedge clk); vblank <= 1;
        @(posedge clk); vblank <= 0;
        for (k = 0; k < 10; k = k + 1) begin
            @(posedge clk); #1;
            if (fbe_req || dbg_rendering) begin
                errors = errors + 1;
                $display("  FAIL 30/60-Hz skipped frame started work");
            end
        end
        if (dbg_counts[7:0] !== swaps_before) begin
            errors = errors + 1;
            $display("  FAIL skipped frame swapped buffers");
        end
    end
endtask

// common fields: draw, 4bpp, srch=1, srcw=1 word, dsth=1, ax/ay=start(2'b10)
localparam [15:0] W0_PLAIN  = 16'h000A;              // ay=10 ax=10
localparam [15:0] W1_1x1    = 16'h0102;              // srch=1, srcw=1 (bits6:1)
localparam [15:0] COLOR     = 16'h0100;              // palette bits -> 0x8100 | pen

initial begin
    repeat (6) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);

    // CPU sprite-RAM diagnostic: one count per completed write, exact last
    // word address/data/BE, plus a saturating sticky count.
    @(negedge clk);
    cpu_dbg_we = 1; cpu_dbg_addr = 16'h1234;
    cpu_dbg_data = 16'habcd; cpu_dbg_be = 2'b01;
    @(negedge clk); cpu_dbg_we = 0;
    @(negedge clk);
    cpu_dbg_we = 1; cpu_dbg_addr = 16'h4567;
    cpu_dbg_data = 16'h89ef; cpu_dbg_be = 2'b10;
    @(negedge clk); cpu_dbg_we = 0;
    #1;
    if (!cpu_dbg_seen || cpu_dbg_count !== 8'd2 ||
        cpu_dbg_last_addr !== 16'h4567 || cpu_dbg_last_data !== 16'h89ef ||
        cpu_dbg_last_be !== 2'b10) begin
        errors = errors + 1;
        $display("  FAIL CPU write diagnostic seen/count/last = %0d/%0d/%04x/%04x/%b",
                 cpu_dbg_seen, cpu_dbg_count, cpu_dbg_last_addr,
                 cpu_dbg_last_data, cpu_dbg_last_be);
    end
    for (ci = 0; ci < 260; ci = ci + 1) begin
        @(negedge clk); cpu_dbg_we = 1;
        @(negedge clk); cpu_dbg_we = 0;
    end
    #1;
    if (cpu_dbg_count !== 8'hff) begin
        errors = errors + 1;
        $display("  FAIL CPU write diagnostic did not saturate: %02x",
                 cpu_dbg_count);
    end

    // sprite pixel data at word addr 0 (chunk 0): 0x12345678 -> pens 1..8
    // little-endian byte packing, BE word: bytes 12 34 56 78
    rom128[0] = 128'h0; rom128[0][31:0] = 32'h78563412;
    // word addr 1 (bytes 4-7): 0x1F0F0F3F -> pens 1,F,0,F,0,F,3,F (end code F)
    rom128[0][63:32] = 32'h3F0F0F1F;
    // word addr 2: 0x10203040 pens 1,0,2,0,3,0,4,0
    rom128[0][95:64] = 32'h40302010;

    // ---- 1: plain 1:1, xpos=100 ypos=10: pens 1..8 at x=100..107 ----
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8101); check(101, 16'h8102); check(102, 16'h8103);
    check(103, 16'h8104); check(104, 16'h8105); check(105, 16'h8106);
    check(106, 16'h8107); check(107, 16'h8108);
    check(99, 16'hFFFF);  check(108, 16'hFFFF);
    if (!(dbg_activity[3] && dbg_activity[5] && dbg_activity[6] &&
          dbg_activity[10] && dbg_activity[13] && dbg_activity[14] &&
          dbg_activity[16])) begin
        errors = errors + 1;
        $display("  FAIL sprite activity=%06x missing draw-path events",
                 dbg_activity);
    end
    if (dbg_counts[7:0] !== 8'd1 ||       // swap
        dbg_counts[15:8] !== 8'd2 ||      // draw + END decode
        dbg_counts[23:16] !== 8'd1 ||     // END
        dbg_counts[47:40] !== 8'd1 ||     // non-zero draw
        dbg_counts[63:56] !== 8'd1) begin // sprite-ROM request
        errors = errors + 1;
        $display("  FAIL initial diagnostic counts=%016x", dbg_counts);
    end
    if (dbg_last_desc[15:0] !== 16'hc000 ||
        dbg_last_draw_desc[15:0] !== W0_PLAIN ||
        dbg_last_draw_desc[31:16] !== W1_1x1) begin
        errors = errors + 1;
        $display("  FAIL descriptor capture last=%032x draw=%032x",
                 dbg_last_desc, dbg_last_draw_desc);
    end
    if (dbg_state[4:0] !== 5'd0 || dbg_state[31:18] !== 14'd2 ||
        !dbg_first_valid || dbg_first_desc !== dbg_last_draw_desc) begin
        errors = errors + 1;
        $display("  FAIL diagnostic state/first state=%08x valid=%0d first=%032x",
                 dbg_state, dbg_first_valid, dbg_first_desc);
    end

    // ---- 2: pen 0 skipped everywhere, pen F drawn ONLY mid-word ----
    // word addr 2: pens 1,0,2,0,3,0,4,0 -> zeros never drawn
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0002, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'hFFFF); check(102, 16'h8102);
    check(103, 16'hFFFF); check(104, 16'h8103); check(105, 16'hFFFF);
    check(106, 16'h8104); check(107, 16'hFFFF);
    // word addr 1: pens 1,F,0,F,0,F,3,F: F at first(pos0)? pos0 pen=1 drawn;
    // F at positions 1,3,5 are MID-word -> drawn; last F transparent+endcode
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0001, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'h810F); check(102, 16'hFFFF);
    check(103, 16'h810F); check(104, 16'hFFFF); check(105, 16'h810F);
    check(106, 16'h8103); check(107, 16'hFFFF);

    // ---- 3: end code terminates the row: srcw=2 words, dstw=16; word0
    // ends in 8 (no code) -> continues; use words 1(themed F end)+2:
    // src = word1, word2: row should STOP after word1 (last pen F) ----
    entry(0, W0_PLAIN, 16'h0104, 16'h0001, 16'h0010, 16'd10, 16'd100, 16'h0001, COLOR);
    frame;
    check(106, 16'h8103);          // inside word 1
    check(108, 16'hFFFF);          // word 2 never drawn (row ended)
    check(110, 16'hFFFF);

    // ---- 4: flipx: pens 1..8 mirrored to x=107..100 ----
    entry(0, W0_PLAIN | 16'h0040, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    frame;
    check(107, 16'h8101); check(106, 16'h8102); check(105, 16'h8103);
    check(104, 16'h8104); check(103, 16'h8105); check(102, 16'h8106);
    check(101, 16'h8107); check(100, 16'h8108);

    // ---- 5: 2x zoom: dstw=16 -> each pen doubled ----
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0010, 16'd10, 16'd100, 16'h0000, COLOR);
    frame;
    check(100, 16'h8101); check(101, 16'h8101);
    check(102, 16'h8102); check(103, 16'h8102);
    check(114, 16'h8108); check(115, 16'h8108);

    // ---- 6: indirect inline table: entry pen1 = 0x1234 (drawn),
    // pen2 = 0x7fff == transmask(ctl4=0,ctl5=0) -> transparent ----
    entry(0, W0_PLAIN | 16'h3000, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0002, 16'h0000);
    // inline table = entries 1..2 (16 words after the 8-entry words)
    sram[{11'd0,3'd0}+8+1]  = 16'h1234;   // pen 1
    sram[{11'd0,3'd0}+8+2]  = 16'h7fff;   // pen 2 -> transparent
    sram[{11'd0,3'd0}+8+3]  = 16'h0345;   // pen 3
    sram[{11'd0,3'd0}+8+4]  = 16'h0456;   // pen 4
    entry(3, 16'hC000, 0,0,0,0,0,0,0);    // list end AFTER skipped table
    frame;
    // src word 2: pens 1,0,2,0,3,0,4,0; pen0 entry = sram[..+8] (X? default 0)
    // set pen0 entry explicitly to transparent
    // (already checked below: pens 1,3,4 drawn; pen 2 transparent)
    check(100, 16'h1234); check(102, 16'hFFFF);
    check(104, 16'h0345); check(106, 16'h0456);

    // ---- 7: shadow sprite: fb_wr_shadow flagged for the run ----
    wctl(3'd4, 8'h02);                    // transmask row select
    wctl(3'd5, 8'h01);                    // shadow enable (reg 5 bit 0)
    entry(0, W0_PLAIN | 16'h0800, W1_1x1, 16'h0001, 16'h0008, 16'd10, 16'd100, 16'h0000, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    if (!fbsh[100] || !fbsh[107]) begin
        errors = errors + 1;
        $display("  FAIL shadow run not flagged (sh100=%0d sh107=%0d)", fbsh[100], fbsh[107]);
    end
    // Registers 4/5 are latched at swap and CPU-readable like 2/3.
    ctl_raddr = 3'd4; #1;
    if (ctl_rdata !== 8'hfe) begin
        errors = errors + 1;
        $display("  FAIL ctl4 readback=%02x want=fe", ctl_rdata);
    end
    ctl_raddr = 3'd5; #1;
    if (ctl_rdata !== 8'hfd) begin
        errors = errors + 1;
        $display("  FAIL ctl5 readback=%02x want=fd", ctl_rdata);
    end

    // ---- 8: even-width center alignment subtracts (dstw-1)/2 = 3 ----
    // ay=start(10), ax=center(00), xpos=100 -> pixels at x=97..104.
    entry(0, 16'h0008, W1_1x1, 16'h0001, 16'h0008,
          16'd10, 16'd100, 16'h0000, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(96, 16'hFFFF); check(97, 16'h8101); check(104, 16'h8108);
    check(105, 16'hFFFF);

    // ---- 9: alignment code 3 is the second center encoding ----
    entry(0, 16'h000B, W1_1x1, 16'h0001, 16'h0008,
          16'd10, 16'd100, 16'h0000, COLOR);
    frame;
    check(96, 16'hFFFF); check(97, 16'h8101); check(104, 16'h8108);
    check(105, 16'hFFFF);

    // ---- 10: from-RAM source repacks two CPU halfwords like MAME ----
    // even=0x5678, odd=0x1234 -> numeric word 0x78563412, consumed
    // MSB-first by draw_one_sprite -> pens 7,8,5,6,3,4,1,2.
    sram[16'h0200] = 16'h5678;
    sram[16'h0201] = 16'h1234;
    entry(0, W0_PLAIN | 16'h0400, W1_1x1, 16'h0001, 16'h0008,
          16'd10, 16'd100, 16'h0100, COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8107); check(101, 16'h8108); check(102, 16'h8105);
    check(103, 16'h8106); check(104, 16'h8103); check(105, 16'h8104);
    check(106, 16'h8101); check(107, 16'h8102);
    if (!dbg_activity[11] || dbg_counts[55:48] == 8'd0 ||
        dbg_last_draw_desc[15:0] !== (W0_PLAIN | 16'h0400)) begin
        errors = errors + 1;
        $display("  FAIL from-RAM diagnostic activity/count/desc=%0d/%0d/%04x",
                 dbg_activity[11], dbg_counts[55:48],
                 dbg_last_draw_desc[15:0]);
    end

    // A zero-sized draw never reaches p2, but must still be diagnosable.
    entry(0, W0_PLAIN, 16'h0000, 0,0,0,0,0,0);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    if (!dbg_activity[9] || dbg_counts[39:32] == 8'd0 ||
        dbg_last_draw_desc[15:0] !== W0_PLAIN ||
        dbg_last_draw_desc[31:16] !== 16'h0000) begin
        errors = errors + 1;
        $display("  FAIL zero-size diagnostic activity/count/desc=%0d/%0d/%032x",
                 dbg_activity[9], dbg_counts[39:32], dbg_last_draw_desc);
    end

    // ---- 11: clip-out persists if a later clip command updates only
    // clip-in. MAME changes each rectangle only when its individual enable
    // bit is present; x=102 remains excluded by the first command. ----
    entry(0, 16'h6000, 0,0,0, 16'd10,16'd10,16'd102,16'd102);
    entry(1, 16'h5000,16'd223,16'd0,16'd319, 0,0,0,0);
    entry(2, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008,
          16'd10, 16'd100, 16'h0000, COLOR);
    entry(3, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(101, 16'h8102); check(102, 16'hFFFF); check(103, 16'h8104);

    // ---- 12: both signed 12-bit values are -2048. MAME's int-domain sum
    // is -4096 (offscreen); a 12-bit RTL sum wraps to zero and draws there. ----
    entry(0, 16'hA001,16'h0800,16'h0800,0,0,0,0,0); // JUMP+offset -> entry1
    entry(1, W0_PLAIN | 16'h0030, W1_1x1, 16'h0001, 16'h0008,
          16'h0800,16'h0800,16'h0000,COLOR);
    entry(2, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    if (fbcnt != 0 || fbcap[0] !== 16'hFFFF) begin
        errors = errors + 1;
        $display("  FAIL signed offset wrapped onscreen count=%0d x0=%04x", fbcnt, fbcap[0]);
    end

    // ---- 13: MAME uses 16.16 zoom. For 4 source pixels expanded to 41,
    // destination x=31 selects source index 3. The former 10.10 step selected
    // index 2 due to cumulative truncation. ----
    rom128[0][31:0] = 32'h04030201; // 8bpp source pixels 1,2,3,4
    entry(0, 16'h020A, 16'h0101, 16'h0001, 16'h0029,
          16'd10,16'd100,16'h0000,COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(130, 16'h8103); // x=30 still source index 2
    check(131, 16'h8104); // x=31 advances exactly as MAME

    // ---- 14: ctl2 globally mirrors the displayed sprite framebuffer.
    // Original x=100..107,y=10 becomes x=219..212,y=213 in 320 mode. ----
    wctl(3'd2, 8'h03);
    rom128[0][31:0] = 32'h78563412; // restore 4bpp pens 1..8
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008,
          16'd10,16'd100,16'h0000,COLOR);
    entry(1, 16'hC000, 0,0,0,0,0,0,0);
    frame;
    check(219, 16'h8101); check(212, 16'h8108);
    if (fbycap[219] !== 8'd213 || fbycap[212] !== 8'd213) begin
        errors = errors + 1;
        $display("  FAIL global Y flip rows=%0d/%0d want=213", fbycap[219], fbycap[212]);
    end
    wctl(3'd2, 8'h00);

    // ---- 15: strong 4bpp downscale still checks END in every skipped
    // source word, including across 128-bit cache-line boundaries. dx=1
    // would sample source word 8, but word 5 terminates the row first. ----
    rom128[0] = 128'd0; rom128[1] = 128'd0; rom128[2] = 128'd0;
    rom128[0][31:0]  = 32'h00000010; // word 0 starts with pen 1
    rom128[1][63:32] = 32'h0f000000; // word 5 final nibble is END
    rom128[2][31:0]  = 32'h00000020; // word 8 would produce pen 2
    entry(0, W0_PLAIN, 16'h0120, 16'h0001, 16'h0002,
          16'd10,16'd100,16'h0000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8101); check(101, 16'hffff);

    // ---- 16: identical skipped-word END semantics in 8bpp mode. ----
    rom128[0] = 128'd0; rom128[1] = 128'd0; rom128[2] = 128'd0;
    rom128[0][31:0]  = 32'h00000001;
    rom128[1][63:32] = 32'hff000000;
    rom128[2][31:0]  = 32'h00000002;
    entry(0, W0_PLAIN | 16'h0200, 16'h0110, 16'h0001, 16'h0002,
          16'd10,16'd100,16'h0000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8101); check(101, 16'hffff);

    // ---- 17: skipped-word END scan also traverses sprite-RAM cache lines. ----
    for (ci = 16'h2000; ci <= 16'h2011; ci = ci + 1) sram[ci] = 16'd0;
    sram[16'h2000] = 16'h0010; // dword 0x1000: first MAME pen = 1
    sram[16'h200a] = 16'h0000;
    sram[16'h200b] = 16'h0f00; // dword 0x1005: final MAME nibble = F
    sram[16'h2010] = 16'h0020; // dword 0x1008 would produce pen 2
    entry(0, W0_PLAIN | 16'h0400, 16'h0120, 16'h0001, 16'h0002,
          16'd10,16'd100,16'h1000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8101); check(101, 16'hffff);

    // ---- 18: from-RAM 32-bit source addresses wrap at 0x7fff. The second
    // word comes from dword zero (the initial JUMP descriptor). ----
    sram[16'hfffe] = 16'h5678;
    sram[16'hffff] = 16'h1234;
    entry(0, 16'h800a, 0,0,0,0,0,0,0); // jump to descriptor 10
    entry(10, W0_PLAIN | 16'h0400, 16'h0104, 16'h0001, 16'h0010,
          16'd10,16'd100,16'h7fff,COLOR);
    entry(11, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(100, 16'h8107); check(101, 16'h8108);
    check(102, 16'h8105); check(103, 16'h8106);
    check(104, 16'h8103); check(105, 16'h8104);
    check(106, 16'h8101); check(107, 16'h8102);
    check(108, 16'hffff); check(109, 16'h810a); check(110, 16'h8108);

    // ---- 19: MAME bank %= numbanks. A two-bank region mirrors raw bank 2
    // to bank 0, while a four-bank region preserves it. ----
    rom128[0] = 128'd0; rom128[0][31:0] = 32'h78563412;
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h4008,
          16'd10,16'd100,16'h0000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    srom_bank_mask = 2'b01;
    frame;
    if (srom_addr[23:22] !== 2'b00) begin
        errors = errors + 1;
        $display("  FAIL two-bank modulo address=%05x", srom_addr);
    end
    srom_bank_mask = 2'b11;
    frame;
    if (srom_addr[23:22] !== 2'b10) begin
        errors = errors + 1;
        $display("  FAIL four-bank address=%05x", srom_addr);
    end

    // ---- 20: ctl6 is latched at swap and drives sprite outer width; x=400
    // proves the sprite uses the latched ctl6 value. ----
    wctl(3'd6, 8'h01);
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0008,
          16'd10,16'd400,16'h0000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(400, 16'h8101); check(407, 16'h8108);
    ctl_raddr = 3'd6; #1;
    if (ctl_rdata !== 8'hfd) begin
        errors = errors + 1;
        $display("  FAIL ctl6 latched readback=%02x", ctl_rdata);
    end
    wctl(3'd6, 8'h00);

    // MAME clips the trailing X target before walking source data. Starting
    // a 100-pixel sprite at x=318 in 320 mode must stop after dx=2 rather
    // than spending 98 more off-screen pixel iterations.
    entry(0, W0_PLAIN, W1_1x1, 16'h0001, 16'h0064,
          16'd10,16'd318,16'h0000,COLOR);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    check(318, 16'h8101); check(319, 16'h8101);
    if (dut.dx !== 10'd2 || fbcnt !== 2) begin
        errors = errors + 1;
        $display("  FAIL trailing X clip dx/writes=%0d/%0d", dut.dx, fbcnt);
    end

    // ---- 21: all 13 list-index bits reach the production 64K-word RAM. ----
    entry(0, 16'h9fff, 0,0,0,0,0,0,0);
    entry(13'h1fff, 16'hc000, 0,0,0,0,0,0,0);
    frame;
    if (dut.list_idx !== 13'h1fff || dut.list_count !== 14'd2 ||
        dbg_last_desc[15:0] !== 16'hc000) begin
        errors = errors + 1;
        $display("  FAIL high list JUMP idx/count/desc=%04x/%0d/%04x",
                 dut.list_idx, dut.list_count, dbg_last_desc[15:0]);
    end

    // ---- 22: Multi32 erase clears the selected visible buffer on both
    // monitors before swapping/rendering. ----
    entry(0, 16'hc000, 0,0,0,0,0,0,0);
    erase_count_0 = 0; erase_count_1 = 0; is_multi32 = 1'b1;
    frame;
    if (erase_count_0 !== 224 || erase_count_1 !== 224) begin
        errors = errors + 1;
        $display("  FAIL Multi32 erase counts=%0d/%0d",
                 erase_count_0, erase_count_1);
    end
    is_multi32 = 1'b0;

    // ---- 23: exact MAME automatic cadence: 30 Hz commands every other
    // update. Switching back to 60 Hz preserves a pending count of one, so
    // one final update is skipped before every-frame rendering resumes. ----
    wctl(3'd3, 8'h01);
    frame;
    expect_skipped_frame;
    frame;
    wctl(3'd3, 8'h00);
    expect_skipped_frame;
    frame;

    // ---- 24: malformed/self-referential list cannot trap renderer ----
    entry(0, 16'h8000, 0,0,0,0,0,0,0);    // JUMP to entry 0 forever
    frame;
    if (dut.list_count !== 14'd8192 || dut.rendering !== 1'b0) begin
        errors = errors + 1;
        $display("  FAIL list watchdog count=%0d rendering=%0d",
                 dut.list_count, dut.rendering);
    end
    if (!dbg_activity[7] || !dbg_activity[18] ||
        dbg_counts[31:24] !== 8'hff || dbg_counts[15:8] !== 8'hff ||
        dbg_last_desc[15:0] !== 16'h8000) begin
        errors = errors + 1;
        $display("  FAIL watchdog diagnostics activity=%06x counts=%016x last=%032x",
                 dbg_activity, dbg_counts, dbg_last_desc);
    end

    if (errors == 0) $display("SPRITE PASS");
    else             $display("SPRITE FAIL (%0d errors)", errors);
    $finish;
end

// pen0's indirect entry must not accidentally draw: init inline table area
integer ii;
initial begin
    for (ii = 0; ii < 65536; ii = ii + 1) sram[ii] = 16'h7fff;
end

initial begin
    #10000000;
    $display("SPRITE FAIL (timeout)");
    $finish;
end

endmodule
