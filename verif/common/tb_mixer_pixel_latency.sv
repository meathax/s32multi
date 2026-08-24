//============================================================================
//  Directed test: s32_mixer output latency must fit inside a 416-wide pixel
//
//  s32_video generates the 416-wide dot clock as MAIN/6, and clk_ram is 2x
//  clk_sys, so one 416-mode pixel is exactly 12 clk_ram edges (320-wide mode
//  is 15).  The display samples `rgb` on the edge that starts the next pixel.
//  If the mixer needs all 12 edges, the sample lands on the same edge the
//  register updates and the whole 416-mode picture is displayed one column to
//  the right of where it belongs in 416-wide mode
//  screen did against MAME before the P3 bubble was removed (that frame then
//  matched MAME with zero differing pixels).  320-wide games never showed it
//  because they had three edges of slack.
//
//  This bench pins the budget so the pipeline cannot silently grow back past
//  it.  It uses no ROM data: it programs two palette entries, alternates the
//  displayed pixel between them, and counts clk_ram edges from the display-X
//  change to the edge on which `rgb` presents the new colour.
//============================================================================
`timescale 1ns/1ps

module tb_mixer_pixel_latency;

// One 416-wide pixel is 12 clk_ram edges, so the mixer has to produce its
// pixel inside one pixel period.  Calibrated against the picture, not
// assumed: the pre-fix pipeline measured 13 edges here and the
// 416-wide WARNING screen sat one column right of MAME (6,662 / 93,184
// differing pixels, exact after shifting MAME right by one).  The fixed
// pipeline measures 12 and that frame matches MAME with zero differing
// pixels.  12 is therefore the proven-good bound and 13 the proven-bad one.
localparam integer PIXEL_EDGES_416 = 12;
localparam integer BUDGET_EDGES    = PIXEL_EDGES_416;

reg clk_ram = 0;
always #5 clk_ram = ~clk_ram;
reg clk_sys = 0;
always @(posedge clk_ram) clk_sys = ~clk_sys;   // /2, edge-aligned

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

reg         reg_we = 0;
reg  [5:0]  reg_addr = 0;
reg  [15:0] reg_wdata = 0;
reg  [8:0]  disp_x = 0, disp_y = 0;
reg         lb_we = 0;
reg  [2:0]  lb_layer = 0;
reg  [8:0]  lb_wx = 0;
reg  [13:0] lb_wpix = 0;
reg         lb_bank = 0;
reg         rst = 1;
reg         frame_latch = 1'b0;
wire [23:0] rgb;
wire [13:0] px_text, px_nbg0, px_nbg1, px_nbg2, px_nbg3, px_bmp;

s32_linebuf lbuf (
    .clk(clk_ram),
    .lb_we(lb_we), .lb_layer(lb_layer), .lb_wx(lb_wx),
    .lb_wpix(lb_wpix), .lb_bank(lb_bank),
    .rd_x(disp_x), .rd_bank(disp_y[0]),
    .px_text(px_text), .px_nbg0(px_nbg0), .px_nbg1(px_nbg1),
    .px_nbg2(px_nbg2), .px_nbg3(px_nbg3), .px_bmp(px_bmp)
);

s32_mixer mix (
    .clk(clk_ram), .rst(rst),
    .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_be(2'b11),
    .reg_rdata(), .reg_raddr(6'h0), .reg_r4e(),
    .disp_x(disp_x), .disp_y(disp_y), .disp_active(1'b1), .display_en(1'b1),
    .flip_y(1'b0), .frame_latch(frame_latch), .layer_off(6'b000000), .bg_ctrl(16'h0000),
    .px_text(px_text), .px_nbg0(px_nbg0), .px_nbg1(px_nbg1),
    .px_nbg2(px_nbg2), .px_nbg3(px_nbg3), .px_bmp(px_bmp),
    .spr_pix(16'hffff),
    .pal_addr(mix_addr), .pal_data(mix_data),
    .rgb(rgb)
);

task wreg(input [5:0] a, input [15:0] d);
    @(posedge clk_ram); reg_we <= 1; reg_addr <= a; reg_wdata <= d;
    @(posedge clk_ram); reg_we <= 0;
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

integer errors = 0;
integer worst = 0;

// Drive disp_x to x and count clk_ram edges until rgb presents want.  The
// count starts on the edge that publishes the new display X, matching the
// core, where s32_video advances hcnt on the pixel edge and s32_core samples
// it into mix_disp_x_cdc on the following clk_ram edge.
task measure(input [8:0] x, input [23:0] want, input [255:0] label);
    integer edges;
    begin
        @(posedge clk_ram); disp_x <= x;
        edges = 0;
        while (edges <= 2 * PIXEL_EDGES_416 && rgb !== want) begin
            @(posedge clk_ram);
            edges = edges + 1;
        end
        if (rgb !== want) begin
            errors = errors + 1;
            $display("  FAIL %0s: rgb never reached %06x (last %06x)",
                     label, want, rgb);
        end
        else begin
            if (edges > worst) worst = edges;
            $display("  %0s: rgb=%06x after %0d clk_ram edges (budget %0d)",
                     label, rgb, edges, BUDGET_EDGES);
            if (edges > BUDGET_EDGES) begin
                errors = errors + 1;
                $display("  FAIL %0s: %0d edges exceeds the 416-wide pixel budget of %0d",
                         label, edges, BUDGET_EDGES);
            end
        end
        // let the pipeline settle before the next measurement
        repeat (2 * PIXEL_EDGES_416) @(posedge clk_ram);
    end
endtask

initial begin
    repeat (4) @(posedge clk_ram);
    rst = 0;
    repeat (2) @(posedge clk_ram);

    // coloroffs_bank0/1 only latch from mreg on a frame_latch pulse and
    // reset to -1 per channel (s32_mixer.sv's own uninitialized-register
    // model); zero the offset regs and pulse once so this test's expected
    // full-scale colors (ffffff/0000ff) aren't silently darkened by one step.
    wreg(6'h1f, 16'h0000);
    wreg(6'h20, 16'h0000); wreg(6'h21, 16'h0000); wreg(6'h22, 16'h0000);
    wreg(6'h23, 16'h0000); wreg(6'h24, 16'h0000); wreg(6'h25, 16'h0000);
    @(posedge clk_ram); frame_latch = 1'b1;
    @(posedge clk_ram); frame_latch = 1'b0;

    // palette: [1] = white, [2] = blue-only, [0] = black backdrop
    wpal(15'h0000, 16'h0000);
    wpal(15'h0001, 16'h7FFF);
    wpal(15'h0002, 16'h7C00);

    // NBG0 wins outright.  The register file resets to 0xFFFF like MAME's
    // video_start memset, so every register this relies on is written.
    wreg(6'h11, 16'h000F);   // NBG0 prio F
    wreg(6'h10, 16'h0000);   // TEXT off
    wreg(6'h12, 16'h0000);   // NBG1 off
    wreg(6'h13, 16'h0000);   // NBG2 off
    wreg(6'h14, 16'h0000);   // NBG3 off
    wreg(6'h15, 16'h0000);   // BITMAP off
    wreg(6'h16, 16'h0001);   // background
    wreg(6'h00, 16'h0000);   // sprite groups 0-15 prio 0
    wreg(6'h01, 16'h0000);
    wreg(6'h02, 16'h0000);
    wreg(6'h03, 16'h0000);
    wreg(6'h04, 16'h0000);
    wreg(6'h05, 16'h0000);
    wreg(6'h06, 16'h0000);
    wreg(6'h07, 16'h0000);
    wreg(6'h26, 16'h0000);   // 0x4C sprite group config
    wreg(6'h27, 16'h0000);   // 0x4E blend off
    wreg(6'h1f, 16'h0000);   // 0x3E color-offset select
    wreg(6'h19, 16'h0000);   // NBG0 blend reg
    wreg(6'h20, 16'h0000);   // 0x40-0x4A RGB offsets = 0
    wreg(6'h21, 16'h0000);
    wreg(6'h22, 16'h0000);
    wreg(6'h23, 16'h0000);
    wreg(6'h24, 16'h0000);
    wreg(6'h25, 16'h0000);
    wreg(6'h2f, 16'h0000);   // mixer $5E must not drive backdrop

    // two adjacent NBG0 pixels with different pens so rgb must change.
    // Bit 13 is the line-buffer opaque flag, as in tb_mixer.
    wlb(3'd1, 1'b0, 9'd100, 14'h2001);
    wlb(3'd1, 1'b0, 9'd101, 14'h2002);

    // prime: walk onto the first pixel and let it settle
    disp_x = 9'd400;
    repeat (4 * PIXEL_EDGES_416) @(posedge clk_ram);

    measure(9'd100, 24'hFFFFFF, "pen1 white");
    measure(9'd101, 24'h0000FF, "pen2 blue ");
    measure(9'd100, 24'hFFFFFF, "pen1 again");

    if (errors == 0)
        $display("MIXER PIXEL LATENCY PASS worst=%0d budget=%0d", worst, BUDGET_EDGES);
    else
        $display("MIXER PIXEL LATENCY FAIL errors=%0d worst=%0d", errors, worst);
    $finish;
end

initial begin
    #200000;
    $display("MIXER PIXEL LATENCY FAIL timeout");
    $finish;
end

endmodule
