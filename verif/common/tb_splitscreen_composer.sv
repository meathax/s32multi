//============================================================================
//  Self-checking bench for s32_splitscreen_composer: drives it with real
//  s32_video native timing and a synthetic per-pixel pattern that encodes
//  {screen marker, native hcnt} directly into rgb_a/rgb_b, then verifies the
//  composed active-region stream is exactly: 416 A0 samples with hcnt
//  0..415 in order, followed by 416 B0 samples with hcnt 0..415 in order,
//  once per composite line -- checked against the STREAM SHAPE itself
//  (self-referential), not against a hand-modelled copy of the DUT's
//  internal pipeline latency, so it can't silently assume the wrong offset.
//============================================================================
module tb_splitscreen_composer;

reg clk = 1'b0;
reg rst = 1'b1;
reg mode_416 = 1'b1;
always #5 clk = ~clk;

wire ce_pix_n, mode_active;
wire [8:0] hcnt, vcnt;
wire hb_n, vb_n, hs_n, vs_n, vbs, vbe;

s32_video native_timing (
    .clk(clk), .rst(rst), .mode_416(mode_416),
    .ce_pix(ce_pix_n), .mode_active(mode_active),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb_n), .vblank(vb_n),
    .hsync(hs_n), .vsync(vs_n), .vblank_start(vbs), .vblank_end(vbe)
);

// Synthetic per-pixel pattern: marker byte identifies the screen, low 9
// bits carry the native hcnt the sample was taken at.
wire [23:0] rgb_a = {8'hA0, 7'b0, hcnt};
wire [23:0] rgb_b = {8'hB0, 7'b0, hcnt};

wire [23:0] rgb_out;
wire        ce_pix_out, vsync_out, vblank_out;
wire        hsync_out, hblank_out;

s32_splitscreen_composer dut (
    .clk(clk), .rst(rst), .mode_416_active(mode_active),
    .rgb_a(rgb_a), .rgb_b(rgb_b),
    .hcnt(hcnt), .ce_pix_native(ce_pix_n),
    .vblank_native(vb_n), .vsync_native(vs_n),
    .rgb_out(rgb_out), .ce_pix_out(ce_pix_out),
    .hsync_out(hsync_out), .vsync_out(vsync_out),
    .hblank_out(hblank_out), .vblank_out(vblank_out)
);

integer errors = 0;
integer lines_checked = 0;
integer divider_px = 0;
// Must track s32_splitscreen_composer's own DIVIDER_W/DIVIDER_HALF.
localparam integer DIVIDER_W    = 2;
localparam integer DIVIDER_HALF = DIVIDER_W / 2;
// Active width per screen depends on the live 416/320 mode -- read directly
// off the native timing generator so the check works in either mode.
wire [8:0] HDISP = mode_active ? 9'd416 : 9'd320;

// Checking is disabled until the initial block has let the ping-pong banks
// settle past the first, necessarily-empty read bank.
reg checking_en = 1'b0;

// Per-line stream-shape state machine: on each active sample, check it
// against what the NEXT expected sample should be, purely from the stream
// itself -- no assumption about which absolute cycle/out_hcnt it lands on.
localparam ST_WANT_A = 0, ST_WANT_B = 1, ST_DONE = 2;
reg [1:0] line_state;
reg [8:0] want_hcnt;
reg       hblank_out_prev = 1'b0;

// Testbench checker state -- deliberately blocking assignment throughout
// (this is non-synthesizable check logic, not RTL) so a same-cycle
// blanking->active edge takes effect on the SAME sample it applies to,
// instead of one cycle late as a nonblocking reset would.
always @(posedge clk) begin
    if (rst) begin
        line_state = ST_WANT_A;
        want_hcnt  = 9'd0;
        hblank_out_prev = 1'b0;
    end
    else if (ce_pix_out) begin
        reg [7:0] marker;
        reg [8:0] src_hcnt;
        marker   = rgb_out[23:16];
        src_hcnt = rgb_out[8:0];

        // Blanking->active edge starts a fresh line's expectation, in time
        // for this same sample's check below.
        if (hblank_out_prev && !hblank_out) begin
            line_state = ST_WANT_A;
            want_hcnt  = 9'd0;
        end

        if (checking_en && !hblank_out) begin
            case (line_state)
                ST_WANT_A: begin
                    if (want_hcnt >= HDISP - DIVIDER_HALF[8:0]) begin
                        // A's rightmost DIVIDER_HALF columns are overpainted
                        // by the seam bar, so they must read pure black.
                        if (rgb_out !== 24'h000000) begin
                            errors = errors + 1;
                            $display("  FAIL divider (A side) hcnt=%0d: expected black, got %06x",
                                     want_hcnt, rgb_out);
                        end
                        else divider_px = divider_px + 1;
                    end
                    else if (marker !== 8'hA0 || src_hcnt !== want_hcnt) begin
                        errors = errors + 1;
                        $display("  FAIL screen-A stream: want hcnt=%0d marker=A0, got marker=%02x hcnt=%0d",
                                 want_hcnt, marker, src_hcnt);
                    end
                    if (want_hcnt == HDISP - 9'd1) begin
                        line_state = ST_WANT_B;
                        want_hcnt  = 9'd0;
                    end
                    else want_hcnt = want_hcnt + 9'd1;
                end
                ST_WANT_B: begin
                    if (want_hcnt < 9'(DIVIDER_W - DIVIDER_HALF)) begin
                        // B's leftmost columns, the other half of the seam.
                        if (rgb_out !== 24'h000000) begin
                            errors = errors + 1;
                            $display("  FAIL divider (B side) hcnt=%0d: expected black, got %06x",
                                     want_hcnt, rgb_out);
                        end
                        else divider_px = divider_px + 1;
                    end
                    else if (marker !== 8'hB0 || src_hcnt !== want_hcnt) begin
                        errors = errors + 1;
                        $display("  FAIL screen-B stream: want hcnt=%0d marker=B0, got marker=%02x hcnt=%0d",
                                 want_hcnt, marker, src_hcnt);
                    end
                    if (want_hcnt == HDISP - 9'd1) begin
                        line_state = ST_DONE;
                        lines_checked = lines_checked + 1;
                    end
                    else want_hcnt = want_hcnt + 9'd1;
                end
                default: begin
                    // Extra active samples beyond 2*HDISP before the next
                    // blanking edge would be a real geometry bug.
                    errors = errors + 1;
                    $display("  FAIL extra active sample past 2*HDISP, marker=%02x hcnt=%0d",
                             marker, src_hcnt);
                end
            endcase
        end
        hblank_out_prev = hblank_out;
    end
end

// vblank_out/vsync_out must track the native signals exactly (pure
// passthrough by design -- combinational, so this can only ever catch a
// wiring mistake, never a timing one).
always @(posedge clk) begin
    if (!rst) begin
        if (vblank_out !== vb_n) begin
            errors = errors + 1;
            $display("  FAIL vblank_out != vblank_native at t=%0t", $time);
        end
        if (vsync_out !== vs_n) begin
            errors = errors + 1;
            $display("  FAIL vsync_out != vsync_native at t=%0t", $time);
        end
    end
end

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;

    // Let a handful of frames of ping-pong settle (first line after reset
    // reads an empty bank -- expected, not checked) then require a solid
    // run of clean lines with real per-line stream checks.
    wait (vcnt == 9'd10 && hcnt == 9'd0);
    errors = 0;
    lines_checked = 0;
    divider_px = 0;
    checking_en = 1'b1;

    while (lines_checked < 40) @(posedge clk);
    // Exactly DIVIDER_W black seam pixels per composed line, no more, no
    // less -- catches a seam that silently widened, vanished, or drifted.
    if (divider_px !== 40 * DIVIDER_W) begin
        errors = errors + 1;
        $display("  FAIL 416-mode divider pixels: got %0d, expected %0d",
                 divider_px, 40 * DIVIDER_W);
    end
    if (errors == 0)
        $display("SPLITSCREEN COMPOSER 416-MODE PASS: lines_checked=%0d divider_px=%0d",
                 lines_checked, divider_px);
    else
        $display("SPLITSCREEN COMPOSER 416-MODE FAIL (%0d errors)", errors);

    // Switch to 320-mode, let it take effect at the next frame boundary
    // (s32_video only latches mode_416 between frames), then repeat the
    // same stream check at the new geometry.
    checking_en = 1'b0;
    mode_416 = 1'b0;
    wait (mode_active == 1'b0);
    wait (vcnt == 9'd10 && hcnt == 9'd0);
    errors = 0;
    lines_checked = 0;
    divider_px = 0;
    checking_en = 1'b1;

    while (lines_checked < 40) @(posedge clk);
    if (divider_px !== 40 * DIVIDER_W) begin
        errors = errors + 1;
        $display("  FAIL 320-mode divider pixels: got %0d, expected %0d",
                 divider_px, 40 * DIVIDER_W);
    end
    if (errors == 0)
        $display("SPLITSCREEN COMPOSER 320-MODE PASS: lines_checked=%0d divider_px=%0d",
                 lines_checked, divider_px);
    else
        $display("SPLITSCREEN COMPOSER 320-MODE FAIL (%0d errors)", errors);

    if (errors == 0)
        $display("SPLITSCREEN COMPOSER OVERALL PASS");
    else
        $display("SPLITSCREEN COMPOSER OVERALL FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #40000000;
    $display("SPLITSCREEN COMPOSER FAIL (timeout)");
    $finish;
end

endmodule
