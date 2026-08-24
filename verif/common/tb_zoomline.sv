// Directed check of the NBG0/1 zoom pipeline: drive s32_tilemap with the
// register set captured from MAME (arabfgt attract, frame 1200) and print the
// per-destination-line source Y and source X base for each layer.  The
// reference values come from MAME update_tilemap_zoom's 12.20 arithmetic.
`timescale 1ns/1ps

module tb_zoomline;

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

reg  [8:0] line = 0;
reg        line_start = 0;
wire       line_done;

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
wire        tile_req;
wire [21:3] tile_addr;

s32_tilemap dut (
    .clk(clk), .rst(rst),
    .line(line), .line_start(line_start), .line_done(line_done),
    .mode_416(1'b0), .is_multi32(1'b0), .ext_tilebank(8'h00),
    // $1FF02 = 0x0020 enables only NBG0..3 + TEXT; the bitmap layer is off.
    .r1ff00(16'h4400), .r1ff02(16'h0020), .r1ff04(16'h7c03), .r1ff06(16'h8421),
    .r1ff5c(16'h01f6), .r1ff5e(16'h81e1),
    .r1ff88(16'h0000), .r1ff8a(16'h0000), .r1ff8c(16'h0000), .r1ff8e(16'h0000),
    .scrollfracx(scrollfracx), .scrollfracy(scrollfracy),
    .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages),
    .zoomx(zoomx), .zoomy(zoomy), .clips(clips),
    .vram_addr(vram_addr), .vram_rdata(16'h0000),
    .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(64'h0), .tile_ack(tile_req),
    .lb_we(), .lb_layer(), .lb_x(), .lb_pix(), .layer_off_o()
);

integer i;
integer l;
integer cyc;
reg [2:0] prev_lay;
reg [4:0] prev_tst;

initial begin
    // MAME arabfgt frame 1200: $1FF10-$1FF1E scroll, $1FF30-$1FF36 centres,
    // $1FF50-$1FF56 zoom.
    scrollfracx[0] = 16'hffb8; scrollx[0] = 16'h0237;
    scrollfracy[0] = 16'h3a23; scrolly[0] = 16'hffe1;
    scrollfracx[1] = 16'h0000; scrollx[1] = 16'h0979;
    scrollfracy[1] = 16'h3a23; scrolly[1] = 16'hffe1;
    scrollx[2] = 16'h0000; scrolly[2] = 16'hff9f;
    scrollx[3] = 16'hfec3; scrolly[3] = 16'hffd1;
    offsx[0] = 16'h0000; offsy[0] = 16'h0000;
    offsx[1] = 16'h0000; offsy[1] = 16'h0000;
    offsx[2] = 16'h0000; offsy[2] = 16'h0000;
    offsx[3] = 16'h0000; offsy[3] = 16'h0000;
    zoomx[0] = 16'h0200; zoomy[0] = 16'h0200;
    zoomx[1] = 16'h0400; zoomy[1] = 16'h0400;
    for (i = 0; i < 8; i = i + 1) pages[i] = 16'h0000;
    for (i = 0; i < 20; i = i + 1) clips[i] = 16'h0000;

    repeat (4) @(posedge clk);
    rst = 0;
    repeat (4) @(posedge clk);

    for (l = 0; l < 224; l = l + 1) begin
        line = l[8:0];
        @(posedge clk);
        line_start = 1;
        @(posedge clk);
        line_start = 0;
        // Sample the row invariants as each layer enters its tile fetch.
        prev_tst = 5'h1f;
        cyc = 0;
        while (!line_done) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (dut.tst == 8 /* T_NAME */ && prev_tst != 8)
                $display("line %0d lay %0d sy_row %0d sx_base %0d srcy %0d",
                         l, dut.lay, dut.sy_row, dut.sx_base, dut.srcy);
            prev_tst = dut.tst;
        end
        $display("CYCLES line %0d = %0d", l, cyc);
        @(posedge clk);
    end
    $finish;
end

initial begin
    #20000000;
    $display("TIMEOUT");
    $finish;
end

endmodule
