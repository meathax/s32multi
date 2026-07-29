//============================================================================
// Sprite vblank edge-detect regression (audit R24 SP-8).
//
// On hardware the sprite engine runs on clk_ram (96.634615 MHz) while its vblank
// input is the end-of-vblank pulse from s32_video, which is one clk_sys
// (48.317307 MHz) wide — i.e. TWO consecutive clk_ram samples.  The R20 SP-3
// "vblank seen mid-render" latch must treat that 2-cycle pulse as a SINGLE
// frame event.  Before the edge-detect fix it re-latched the same pulse on its
// second sample (the FSM had already left R_IDLE), producing a spurious second
// erase/swap/render pass mid-frame — the sprite-buffer tear.
//
// This bench drives the realistic 2-cycle pulse and asserts exactly one
// rendering pass and one buffer swap per frame.  A 1-cycle pulse (the shape
// every prior sprite bench used) is also checked, to prove the fix does not
// regress the single-sample path.
//============================================================================
`timescale 1ns/1ps

module tb_sprite_vblank;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// Sprite-list RAM: every word 0xC000 => word0 command bits[15:14]=11 = END, so
// the list terminates on entry 0 and each render pass is minimal.
reg [15:0] sram [0:16383];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr[13:0]];

// Sprite ROM: unused (list ends immediately) but keep the handshake alive.
wire        srom_req;
wire [23:4] srom_addr;
reg         srom_ack = 0;
reg [127:0] srom_data = 128'h0;
always @(posedge clk) srom_ack <= srom_req;

// Sprite -> framebuffer ports.
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy;
wire [1:0]  fbw_buf;
wire [8:0]  fbw_x;
wire [7:0]  fbw_y;
wire [15:0] fbw_pix;
wire        fbe_req, fbe_ack;
wire [1:0]  fbe_buf;
wire [7:0]  fbe_y;
wire [1:0]  disp_buf;
wire [1:0]  scan_buf;
wire        rendering;

reg present = 0;
reg vblank = 0;
reg [7:0] ctl_addr = 0;
reg [7:0] ctl_wdata = 0;
reg       ctl_we = 0;

// Small post-vblank delay keeps the sim short; behaviour is delay-independent.
s32_sprite #(.POST_VBLANK_CYCLES(8)) sprite (
    .clk(clk), .rst(rst), .is_multi32(1'b0), .screen_sel(1'b0),
    .srom_bank_mask(2'b11),
    .present(present), .vblank(vblank), .rendering(rendering),
    .debug_first_rom_desc(), .debug_first_rom_valid(),
    .debug_last_desc(), .debug_last_draw_desc(),
    .debug_activity(), .debug_state(), .debug_counts(),
    .ctl_we(ctl_we), .ctl_addr(ctl_addr[2:0]), .ctl_wdata(ctl_wdata),
    .ctl_rdata(), .ctl_raddr(3'd0),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf),
    .fb_wr_x(fbw_x), .fb_wr_y(fbw_y), .fb_wr_valid(fbw_valid),
    .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_busy(fbw_busy),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y),
    .fb_er_ack(fbe_ack), .disp_buf(disp_buf), .scan_buf(scan_buf)
);

// Non-backpressured DDR so passes complete quickly.
wire        dd_busy;
wire [7:0]  dd_burst;
wire [28:0] dd_addr;
reg  [63:0] dd_dout = 0;
reg         dd_ready = 0;
wire        dd_rd, dd_we;
wire [63:0] dd_din;
wire [7:0]  dd_be;
assign dd_busy = 1'b0;

s32_fb_if #(.FB_BASE(32'h3000_0000)) fb (
    .clk(clk), .rst(rst),
    .DDRAM_BUSY(dd_busy), .DDRAM_BURSTCNT(dd_burst),
    .DDRAM_ADDR(dd_addr), .DDRAM_DOUT(dd_dout),
    .DDRAM_DOUT_READY(dd_ready), .DDRAM_RD(dd_rd),
    .DDRAM_DIN(dd_din), .DDRAM_BE(dd_be), .DDRAM_WE(dd_we),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(1'b0), .rd_buf(2'd0), .rd_y(8'd0), .rd_ack(),
    .rd_x(9'd0), .rd_pix()
);

// Count logical controller swaps and physical scan-buffer publishes globally.
// A published buffer may change only during vblank, and no erase/render command
// may ever target the physical buffer currently feeding scanout.
integer render_edges = 0;
integer swap_edges = 0;
integer scan_edges = 0;
integer errors = 0;
reg used_third_buffer = 0;
reg rendering_d = 0;
reg [1:0] disp_buf_d = 0;
reg [1:0] scan_buf_d = 0;
reg present_sample_d = 0;
always @(posedge clk) begin
    rendering_d <= rendering;
    disp_buf_d  <= disp_buf;
    scan_buf_d  <= scan_buf;
    present_sample_d <= present;
    if (!rst && rendering && !rendering_d) render_edges = render_edges + 1;
    if (!rst && disp_buf !== disp_buf_d)   swap_edges   = swap_edges + 1;
    // Nonblocking DUT updates are observed by this monitor on the following
    // edge, so retain the previous start-of-vblank sample for attribution.
    if (!rst && !$isunknown(scan_buf) && !$isunknown(scan_buf_d) &&
        scan_buf !== scan_buf_d) begin
        scan_edges = scan_edges + 1;
        if (!(present || present_sample_d)) begin
            errors = errors + 1;
            $display("  FAIL scan buffer changed outside vblank: %0d -> %0d",
                     scan_buf_d, scan_buf);
        end
    end
    if (!rst && fbe_req && fbe_buf == 2'd2)
        used_third_buffer <= 1'b1;
    if (!rst && (fbe_req || fbw_start) &&
        ((fbe_req ? fbe_buf : fbw_buf) == scan_buf)) begin
        errors = errors + 1;
        $display("  FAIL framebuffer write/erase targets scanned buffer %0d",
                 scan_buf);
    end
end

task write_ctl(input [2:0] a, input [7:0] d);
    @(posedge clk); ctl_we <= 1'b1; ctl_addr <= {5'd0, a}; ctl_wdata <= d;
    @(posedge clk); ctl_we <= 1'b0;
endtask

// Drive one vblank pulse `width` clk cycles wide, then let the pass settle.
task pulse_frame(input integer width);
    integer i;
    // Start of vblank publishes the prior completed frame. End of vblank
    // independently launches the delayed controller update/render pass.
    @(posedge clk); present <= 1'b1;
    for (i = 0; i < width; i = i + 1) @(posedge clk);
    present <= 1'b0;
    repeat (4) @(posedge clk);
    vblank <= 1'b1;
    for (i = 0; i < width; i = i + 1) @(posedge clk);
    vblank <= 1'b0;
endtask

task pulse_and_settle(input integer width);
    pulse_frame(width);
    // wait for the pass to run and the framebuffer to drain
    wait (rendering === 1'b1);
    wait (rendering === 1'b0);
    wait (fbw_busy === 1'b0);
    repeat (40) @(posedge clk);
endtask

integer si;
integer base_render, base_swap, base_scan;
initial begin
    for (si = 0; si < 16384; si = si + 1) sram[si] = 16'hc000; // all END

    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (6) @(posedge clk);

    // Automatic every-frame mode: ctl[3] bit1=0, bit0=0 => command forced 2'b11.
    write_ctl(3'd3, 8'h00);
    repeat (8) @(posedge clk);

    // ---- Realistic 2-cycle (clk_ram) wide pulse: must produce ONE pass. ----
    base_render = render_edges;
    base_swap   = swap_edges;
    base_scan   = scan_edges;
    pulse_and_settle(2);
    if (render_edges - base_render !== 1) begin
        errors = errors + 1;
        $display("  FAIL 2-wide vblank produced %0d render passes (want 1)",
                 render_edges - base_render);
    end
    if (swap_edges - base_swap !== 1) begin
        errors = errors + 1;
        $display("  FAIL 2-wide vblank produced %0d buffer swaps (want 1)",
                 swap_edges - base_swap);
    end
    if (scan_edges - base_scan !== 0) begin
        errors = errors + 1;
        $display("  FAIL first frame published an incomplete buffer");
    end

    // ---- Three more 2-wide frames: strictly one pass + one swap each. ----
    for (si = 0; si < 3; si = si + 1) begin
        base_render = render_edges;
        base_swap   = swap_edges;
        base_scan   = scan_edges;
        pulse_and_settle(2);
        if (render_edges - base_render !== 1) begin
            errors = errors + 1;
            $display("  FAIL frame %0d: %0d render passes (want 1)",
                     si, render_edges - base_render);
        end
        if (swap_edges - base_swap !== 1) begin
            errors = errors + 1;
            $display("  FAIL frame %0d: %0d swaps (want 1)",
                     si, swap_edges - base_swap);
        end
        if (scan_edges - base_scan !== 1) begin
            errors = errors + 1;
            $display("  FAIL frame %0d: %0d scan publishes (want 1)",
                     si, scan_edges - base_scan);
        end
    end

    // ---- 1-cycle pulse must still yield exactly one pass (no regression). ----
    base_render = render_edges;
    base_swap   = swap_edges;
    base_scan   = scan_edges;
    pulse_and_settle(1);
    if (render_edges - base_render !== 1) begin
        errors = errors + 1;
        $display("  FAIL 1-wide vblank produced %0d render passes (want 1)",
                 render_edges - base_render);
    end
    if (swap_edges - base_swap !== 1) begin
        errors = errors + 1;
        $display("  FAIL 1-wide vblank produced %0d buffer swaps (want 1)",
                 swap_edges - base_swap);
    end
    if (scan_edges - base_scan !== 1) begin
        errors = errors + 1;
        $display("  FAIL 1-wide vblank produced %0d scan publishes (want 1)",
                 scan_edges - base_scan);
    end

    // ---- Overrun path: a second frame event while erase/render is busy. ----
    // The completed first frame must remain queued, so the pending pass uses
    // physical buffer 2 rather than touching scanout or the queued buffer.
    used_third_buffer = 1'b0;
    base_render = render_edges;
    base_swap = swap_edges;
    pulse_frame(2);
    wait (fbe_req === 1'b1);
    pulse_frame(2);
    wait (render_edges - base_render == 2);
    wait (rendering === 1'b0);
    wait (fbw_busy === 1'b0);
    repeat (40) @(posedge clk);
    if (swap_edges - base_swap !== 2) begin
        errors = errors + 1;
        $display("  FAIL overrun path produced %0d swaps (want 2)",
                 swap_edges - base_swap);
    end
    if (!used_third_buffer) begin
        errors = errors + 1;
        $display("  FAIL overrun path did not rotate through buffer 2");
    end

    if (errors == 0) $display("SPRITE VBLANK PASS");
    else             $display("SPRITE VBLANK FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #20000000;
    $display("SPRITE VBLANK FAIL (timeout)");
    $finish;
end

endmodule
