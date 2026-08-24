//============================================================================
// Tile renderer line-budget measurement.
//
// Drives s32_tile_line_scheduler + s32_tilemap at the real scanline cadence
// with the arabfgt attract register set (4 NBG layers + text, NBG1 at 2x
// vertical zoom) and a parameterised tile-fetch latency, then reports how
// many scanline kicks the scheduler had to drop.  A dropped kick leaves that
// line-buffer parity holding the line rendered two lines earlier, which shows
// on screen as alternating duplicated background scanlines.
//
// Line period: 410 dots at MAIN/5 (6.44 MHz dot clock) is 63.6 us, which is
// 6146 clk_ram (96.634 MHz) cycles.
//============================================================================
`timescale 1ns/1ps

module tb_tile_line_budget;

localparam int LINE_CYCLES = 6146;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

reg  [8:0] next_line = 0;
reg        line_kick = 0;
wire       line_start, line_done, busy, lb_bank;
wire [8:0] render_line;

s32_tile_line_scheduler scheduler (
    .clk(clk), .rst(rst), .line_kick(line_kick),
    .next_line(next_line), .line_done(line_done),
    .line_start(line_start), .render_line(render_line),
    .lb_bank(lb_bank), .busy(busy)
);

reg [15:0] scrollfracx [0:1];
reg [15:0] scrollfracy [0:1];
reg [15:0] scrollx [0:3];
reg [15:0] scrolly [0:3];
reg [15:0] offsx   [0:3];
reg [15:0] offsy   [0:3];
reg [15:0] pages   [0:7];
reg [15:0] zoomx   [0:1];
reg [15:0] zoomy   [0:1];
reg [15:0] clips   [0:19];

wire [15:0] vram_addr;
reg  [15:0] vram_rdata = 16'h0001;
always @(posedge clk) vram_rdata <= 16'h0001;

// Tile fetch model: fixed latency per request, set from +define or plusarg.
integer ack_latency = 8;
wire        tile_req;
wire [21:3] tile_addr;
reg  [63:0] tile_data = 64'h0123_4567_89ab_cdef;
reg         tile_ack = 0;
integer     ack_wait = 0;
always @(posedge clk) begin
    tile_ack <= 1'b0;
    if (!tile_req)
        ack_wait <= 0;
    else if (ack_wait >= ack_latency) begin
        tile_ack <= 1'b1;
        ack_wait <= 0;
    end
    else
        ack_wait <= ack_wait + 1;
end

s32_tilemap tilemap (
    .clk(clk), .rst(rst), .line(render_line),
    .line_start(line_start), .line_done(line_done),
    .mode_416(1'b0), .is_multi32(1'b0), .ext_tilebank(8'b0),
    .r1ff00(16'h4400), .r1ff02(16'h0020), .r1ff04(16'h7c03), .r1ff06(16'h8421),
    .r1ff5c(16'h01f6), .r1ff5e(16'h81e1),
    .r1ff88(16'h0000), .r1ff8a(16'h0000), .r1ff8c(16'h0000), .r1ff8e(16'h0000),
    .scrollfracx(scrollfracx), .scrollfracy(scrollfracy),
    .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages),
    .zoomx(zoomx), .zoomy(zoomy), .clips(clips),
    .vram_addr(vram_addr), .vram_rdata(vram_rdata),
    .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(tile_data), .tile_ack(tile_ack),
    .lb_we(), .lb_layer(), .lb_x(), .lb_pix(), .layer_off_o()
);

integer i;
integer l;
integer c;
integer drops;
integer worst;
integer cyc;
integer accepted;

initial begin
    if (!$value$plusargs("latency=%d", ack_latency)) ack_latency = 8;

    scrollfracx[0] = 16'hffb8; scrollx[0] = 16'h0237;
    scrollfracy[0] = 16'h3a23; scrolly[0] = 16'hffe1;
    scrollfracx[1] = 16'h0000; scrollx[1] = 16'h0979;
    scrollfracy[1] = 16'h3a23; scrolly[1] = 16'hffe1;
    scrollx[2] = 16'h0000; scrolly[2] = 16'hff9f;
    scrollx[3] = 16'hfec3; scrolly[3] = 16'hffd1;
    for (i = 0; i < 4; i = i + 1) begin offsx[i] = 0; offsy[i] = 0; end
    zoomx[0] = 16'h0200; zoomy[0] = 16'h0200;
    zoomx[1] = 16'h0400; zoomy[1] = 16'h0400;
    for (i = 0; i < 8; i = i + 1) pages[i] = 16'h0000;
    for (i = 0; i < 20; i = i + 1) clips[i] = 16'h0000;

    repeat (4) @(posedge clk);
    rst = 0;
    repeat (4) @(posedge clk);

    drops = 0; worst = 0; accepted = 0;
    for (l = 0; l < 224; l = l + 1) begin
        next_line = l[8:0];
        // Scanline boundary kick.
        line_kick = 1'b1;
        if (busy && !line_done) drops = drops + 1;
        else accepted = accepted + 1;
        @(posedge clk);
        @(posedge clk);
        line_kick = 1'b0;
        cyc = 2;
        for (c = 0; c < LINE_CYCLES - 2; c = c + 1) begin
            @(posedge clk);
            if (busy) cyc = cyc + 1;
        end
        if (cyc > worst) worst = cyc;
    end

    $display("RESULT latency=%0d line_budget=%0d worst_busy=%0d accepted=%0d drops=%0d",
             ack_latency, LINE_CYCLES, worst, accepted, drops);
    $finish;
end

initial begin
    #200000000;
    $display("TIMEOUT");
    $finish;
end

endmodule
