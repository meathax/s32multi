//============================================================================
// Integrated tile scheduler + renderer SDRAM-backpressure regression.
//============================================================================
`timescale 1ns/1ps

module tb_tile_backpressure;

reg clk = 0;
always #5 clk = ~clk;

reg rst = 1;
reg line_kick = 0;
reg [8:0] next_line = 0;
wire line_start, line_done, busy, lb_bank;
wire [8:0] render_line;

s32_tile_line_scheduler scheduler (
    .clk(clk), .rst(rst), .line_kick(line_kick),
    .next_line(next_line), .line_done(line_done),
    .line_start(line_start), .render_line(render_line),
    .lb_bank(lb_bank), .busy(busy)
);

// CPU-domain sources and the core's per-line snapshots.
reg        source_mode = 0;
reg [15:0] source_r1ff00 = 16'h0000;
reg [15:0] source_r1ff02 = 16'h003e; // only NBG0 enabled
reg        snap_mode = 0;
reg [15:0] snap_r1ff00 = 16'h0000;
reg [15:0] snap_r1ff02 = 16'h003e;
always @(posedge clk) begin
    if (line_start) begin
        snap_mode   <= source_mode;
        snap_r1ff00 <= source_r1ff00;
        snap_r1ff02 <= source_r1ff02;
    end
end

reg [15:0] scrollx [0:3], scrolly [0:3];
reg [15:0] scrollfracx [0:1], scrollfracy [0:1];
reg [15:0] offsx [0:3], offsy [0:3];
reg [15:0] pages [0:7];
reg [15:0] zoomx [0:1], zoomy [0:1];
reg [15:0] clips [0:19];
integer i;
initial begin
    for (i = 0; i < 4; i = i + 1) begin
        scrollx[i] = 0; scrolly[i] = 0;
        offsx[i] = 0; offsy[i] = 0;
    end
    for (i = 0; i < 8; i = i + 1)
        pages[i] = 0;
    for (i = 0; i < 2; i = i + 1) begin
        scrollfracx[i] = 0;
        scrollfracy[i] = 0;
        zoomx[i] = 16'h0200;
        zoomy[i] = 16'h0200;
    end
    for (i = 0; i < 20; i = i + 1)
        clips[i] = 0;
end

wire [15:0] vram_addr;
reg  [15:0] vram_rdata = 16'h0001;
always @(posedge clk)
    vram_rdata <= 16'h0001;

wire tile_req;
wire [21:3] tile_addr;
reg  [63:0] tile_data = 64'h0123_4567_89ab_cdef;
reg         tile_ack = 0;
reg         ack_enable = 0;
reg   [2:0] ack_wait = 0;
always @(posedge clk) begin
    tile_ack <= 1'b0;
    if (!tile_req)
        ack_wait <= 0;
    else if (ack_enable) begin
        if (ack_wait == 3) begin
            tile_ack <= 1'b1;
            ack_wait <= 0;
        end
        else
            ack_wait <= ack_wait + 1'd1;
    end
end

wire lb_we;
wire [2:0] lb_layer;
wire [8:0] lb_x;
wire [13:0] lb_pix;
s32_tilemap tilemap (
    .clk(clk), .rst(rst), .line(render_line),
    .line_start(line_start), .line_done(line_done),
    .mode_416(snap_mode), .is_multi32(1'b0), .ext_tilebank(8'b0),
    .r1ff00(snap_r1ff00), .r1ff02(snap_r1ff02),
    .r1ff04(16'h0000), .r1ff06(16'h0000),
    .r1ff5c(16'h0000), .r1ff5e(16'h0000),
    .r1ff88(16'h0000), .r1ff8a(16'h0000),
    .r1ff8c(16'h0000), .r1ff8e(16'h0000),
    .scrollfracx(scrollfracx), .scrollfracy(scrollfracy),
    .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages),
    .zoomx(zoomx), .zoomy(zoomy), .clips(clips),
    .vram_addr(vram_addr), .vram_rdata(vram_rdata),
    .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(tile_data), .tile_ack(tile_ack),
    .lb_we(lb_we), .lb_layer(lb_layer), .lb_x(lb_x),
    .lb_pix(lb_pix), .layer_off_o()
);

integer errors = 0;
integer starts = 0;
integer timeout;
reg found;
always @(posedge clk)
    if (line_start)
        starts = starts + 1;

task automatic fail(input [8*96-1:0] message);
begin
    $display("FAIL %0s", message);
    errors = errors + 1;
end
endtask

task automatic check_held;
begin
    if (render_line !== 9'd5 || lb_bank !== 1'b1)
        fail("line or parity bank changed during tile SDRAM stall");
    if (snap_mode !== 1'b0 || snap_r1ff00 !== 16'h0000 ||
        snap_r1ff02 !== 16'h003e)
        fail("video-control snapshot changed during tile SDRAM stall");
end
endtask

initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // Accept line 5, then stall its very first tile-row fetch.
    next_line = 9'd5;
    line_kick = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    line_kick = 1'b0;

    found = 0;
    for (timeout = 0; timeout < 200 && !found; timeout = timeout + 1) begin
        @(negedge clk);
        if (tile_req) found = 1;
    end
    if (!found)
        fail("renderer did not reach its first tile SDRAM request");
    check_held;

    // Emulate CPU register writes and another scanline boundary while the
    // SDRAM request remains unacknowledged.
    source_mode = 1'b1;
    source_r1ff00 = 16'hffff;
    source_r1ff02 = 16'h0000;
    next_line = 9'd6;
    line_kick = 1'b1;
    repeat (2) begin
        @(posedge clk);
        @(negedge clk);
        check_held;
    end
    line_kick = 1'b0;
    repeat (12) begin
        source_r1ff00 = source_r1ff00 + 1'd1;
        @(posedge clk);
        @(negedge clk);
        if (!tile_req || line_done)
            fail("stalled tile transaction completed without an ACK");
        check_held;
    end
    if (starts != 1)
        fail("stalled scanline accepted a second line");

    // Release SDRAM with repeatable three-cycle backpressure and wait for the
    // real tilemap FSM to pulse completion.
    ack_enable = 1'b1;
    found = 0;
    for (timeout = 0; timeout < 10000 && !found; timeout = timeout + 1) begin
        @(negedge clk);
        if (line_done) found = 1;
    end
    if (!found)
        fail("renderer did not complete after tile ACKs resumed");

    // Present the next real boundary while line_done is high.  The completed
    // line is replaced immediately, with no false overrun or target mutation.
    source_mode = 1'b0;
    source_r1ff00 = 16'h0200;
    source_r1ff02 = 16'h003e;
    next_line = 9'd6;
    line_kick = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!line_start || !busy || render_line !== 9'd6 || lb_bank !== 1'b0)
        fail("real line_done plus boundary did not launch line 6");
    if (line_done)
        fail("tilemap line_done was not a one-cycle pulse");
    line_kick = 1'b0;
    @(posedge clk);
    @(negedge clk);
    if (starts != 2 || snap_r1ff00 !== 16'h0200 || snap_r1ff02 !== 16'h003e)
        fail("line 6 control snapshot was not captured");

    if (errors == 0)
        $display("TILE BACKPRESSURE PASS");
    else
        $display("TILE BACKPRESSURE FAIL (%0d errors)", errors);
    $finish;
end

endmodule
