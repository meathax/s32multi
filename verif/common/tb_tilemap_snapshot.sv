// Replay a captured System 32 VRAM image through the production tile renderer.
// Usage: vsim ... +VRAM=<64Kx16 hex> +TILES=<512Kx64 hex>
`timescale 1ns/1ps

module tb_tilemap_snapshot;

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

reg [15:0] vram_mem [0:65535];
reg [63:0] tile_mem [0:524287];
reg [15:0] vram_q = 0;
reg [63:0] tile_q = 0;
reg tile_ack = 0;
reg line_start = 0;
reg [8:0] render_line = 0;

wire [15:0] vram_addr;
wire tile_req;
wire [21:3] tile_addr;
wire line_done;
wire lb_we;
wire [2:0] lb_layer;
wire [8:0] lb_x;
wire [13:0] lb_pix;
wire [5:0] layer_off;

wire [15:0] r1ff00 = vram_mem[16'hff80];
wire [15:0] r1ff02 = vram_mem[16'hff81];
wire [15:0] r1ff04 = vram_mem[16'hff82];
wire [15:0] r1ff06 = vram_mem[16'hff83];
wire [15:0] r1ff5c = vram_mem[16'hffae];
wire [15:0] r1ff5e = vram_mem[16'hffaf];
wire [15:0] r1ff88 = vram_mem[16'hffc4];
wire [15:0] r1ff8a = vram_mem[16'hffc5];
wire [15:0] r1ff8c = vram_mem[16'hffc6];
wire [15:0] r1ff8e = vram_mem[16'hffc7];
wire [15:0] scrollfracx [0:1];
wire [15:0] scrollfracy [0:1];
wire [15:0] scrollx [0:3];
wire [15:0] scrolly [0:3];
wire [15:0] offsx [0:3];
wire [15:0] offsy [0:3];
wire [15:0] pages [0:7];
wire [15:0] zoomx [0:1];
wire [15:0] zoomy [0:1];
wire [15:0] clips [0:19];

assign scrollfracx[0] = vram_mem[16'hff88];
assign scrollx[0]     = vram_mem[16'hff89];
assign scrollfracy[0] = vram_mem[16'hff8a];
assign scrolly[0]     = vram_mem[16'hff8b];
assign scrollfracx[1] = vram_mem[16'hff8c];
assign scrollx[1]     = vram_mem[16'hff8d];
assign scrollfracy[1] = vram_mem[16'hff8e];
assign scrolly[1]     = vram_mem[16'hff8f];
assign scrollx[2] = vram_mem[16'hff91];
assign scrolly[2] = vram_mem[16'hff93];
assign scrollx[3] = vram_mem[16'hff95];
assign scrolly[3] = vram_mem[16'hff97];

genvar gi;
generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_offsets
        assign offsx[gi] = vram_mem[16'hff98 + gi * 2];
        assign offsy[gi] = vram_mem[16'hff99 + gi * 2];
    end
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_pages
        assign pages[gi] = vram_mem[16'hffa0 + gi];
    end
    for (gi = 0; gi < 2; gi = gi + 1) begin : g_zoom
        assign zoomx[gi] = vram_mem[16'hffa8 + gi * 2];
        assign zoomy[gi] = vram_mem[16'hffa9 + gi * 2];
    end
    for (gi = 0; gi < 20; gi = gi + 1) begin : g_clips
        assign clips[gi] = vram_mem[16'hffb0 + gi];
    end
endgenerate

s32_tilemap dut (
    .clk(clk), .rst(rst), .line(render_line), .line_start(line_start),
    .line_done(line_done), .mode_416(r1ff00[15]), .is_multi32(1'b0),
    .ext_tilebank(8'h00), .r1ff00(r1ff00), .r1ff02(r1ff02),
    .r1ff04(r1ff04), .r1ff06(r1ff06), .r1ff5c(r1ff5c),
    .r1ff5e(r1ff5e), .r1ff88(r1ff88), .r1ff8a(r1ff8a),
    .r1ff8c(r1ff8c), .r1ff8e(r1ff8e), .scrollfracx(scrollfracx),
    .scrollfracy(scrollfracy), .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages), .zoomx(zoomx),
    .zoomy(zoomy), .clips(clips), .vram_addr(vram_addr),
    .vram_rdata(vram_q), .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(tile_q), .tile_ack(tile_ack), .lb_we(lb_we),
    .lb_layer(lb_layer), .lb_x(lb_x), .lb_pix(lb_pix),
    .layer_off_o(layer_off)
);

always @(posedge clk) begin
    vram_q <= vram_mem[vram_addr];
    tile_ack <= 1'b0;
    if (tile_req && !tile_ack) begin
        tile_q <= tile_mem[tile_addr];
        tile_ack <= 1'b1;
    end
end

integer opaque [0:5];
integer writes [0:5];
integer line_timeout;
integer layer_i;
integer y;
string vram_path;
string tiles_path;

always @(posedge clk) if (lb_we) begin
    writes[lb_layer] = writes[lb_layer] + 1;
    if (lb_pix[13]) opaque[lb_layer] = opaque[lb_layer] + 1;
end

initial begin
    if (!$value$plusargs("VRAM=%s", vram_path))
        $fatal(1, "+VRAM=<64Kx16 hex> is required");
    if (!$value$plusargs("TILES=%s", tiles_path))
        $fatal(1, "+TILES=<512Kx64 hex> is required");
    $readmemh(vram_path, vram_mem);
    $readmemh(tiles_path, tile_mem);
    for (layer_i = 0; layer_i < 6; layer_i = layer_i + 1) begin
        opaque[layer_i] = 0;
        writes[layer_i] = 0;
    end
    repeat (4) @(posedge clk);
    rst = 0;
    for (y = 0; y < 224; y = y + 1) begin
        @(negedge clk);
        render_line = y[8:0];
        line_start = 1'b1;
        @(negedge clk);
        line_start = 1'b0;
        line_timeout = 0;
        while (!line_done && line_timeout < 10000) begin
            @(posedge clk);
            line_timeout = line_timeout + 1;
        end
        if (!line_done) $fatal(1, "tile snapshot timeout at line %0d", y);
    end
    $display("TILE SNAPSHOT regs r00=%04x r02=%04x r04=%04x r06=%04x r8e=%04x off=%02x",
        r1ff00, r1ff02, r1ff04, r1ff06, r1ff8e, layer_off);
    for (layer_i = 0; layer_i < 6; layer_i = layer_i + 1)
        $display("TILE SNAPSHOT layer=%0d writes=%0d opaque=%0d",
            layer_i, writes[layer_i], opaque[layer_i]);
    $display("TILE SNAPSHOT PASS");
    $finish;
end

endmodule
