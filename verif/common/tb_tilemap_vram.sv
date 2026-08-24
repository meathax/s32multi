//============================================================================
// Directed VRAM -> tilemap fetch test.
//
// The video RAM has a synchronous registered read port.  Exercise each
// renderer client with a value that differs from the previously addressed
// word so a one-request-behind pipeline cannot pass accidentally.
//============================================================================
`timescale 1ns/1ps

module tb_tilemap_vram;

reg clk_sys = 0, clk_ram = 0, rst = 1;
always #10 clk_sys = ~clk_sys;
always #5  clk_ram = ~clk_ram;

reg         cpu_we = 0;
reg  [15:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
reg   [1:0] cpu_be = 2'b11;
wire [15:0] cpu_rdata;
reg  [15:0] vid_addr;
wire [15:0] vid_rdata;

wire [15:0] r1ff00, r1ff02, r1ff04, r1ff06, r1ff5c, r1ff5e;
wire [15:0] r1ff88, r1ff8a, r1ff8c, r1ff8e;
wire [15:0] scrollfracx [0:1], scrollfracy [0:1];
wire [15:0] scrollx [0:3], scrolly [0:3], offsx [0:3], offsy [0:3];
wire [15:0] pages [0:7], zoomx [0:1], zoomy [0:1], clips [0:19];

s32_vram vram (
    .clk(clk_sys), .vid_clk(clk_ram),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_rdata(cpu_rdata),
    .vid_addr(vid_addr), .vid_rdata(vid_rdata),
    .reg_1ff00(r1ff00), .reg_1ff02(r1ff02), .reg_1ff04(r1ff04),
    .reg_1ff06(r1ff06),
    .reg_scrollfracx(scrollfracx), .reg_scrollfracy(scrollfracy),
    .reg_scrollx(scrollx), .reg_scrolly(scrolly),
    .reg_offsx(offsx), .reg_offsy(offsy), .reg_pages(pages),
    .reg_zoomx(zoomx), .reg_zoomy(zoomy), .reg_1ff5c(r1ff5c),
    .reg_1ff5e(r1ff5e), .reg_clips(clips), .reg_1ff88(r1ff88),
    .reg_1ff8a(r1ff8a), .reg_1ff8c(r1ff8c), .reg_1ff8e(r1ff8e)
);

reg         line_start = 0;
reg  [8:0]  render_line = 0;
wire        line_done;
wire        tile_req;
wire [21:3] tile_addr;
// Bytes 12 34 56 78 9A BC DE F0 exercise every nibble and the non-linear
// MAME bgcharlayout byte order.  Pixels x0..15 must decode as
// 1,2,5,6,3,4,7,8,9,A,D,E,B,C,F,0.
reg  [63:0] tile_data = 64'hF0DE_BC9A_7856_3412;
reg         tile_ack = 0;
wire        lb_we;
wire  [2:0] lb_layer;
wire  [8:0] lb_x;
wire [13:0] lb_pix;

s32_tilemap dut (
    .clk(clk_ram), .rst(rst), .line(render_line), .line_start(line_start),
    .line_done(line_done), .mode_416(1'b0), .is_multi32(1'b0), .ext_tilebank(8'b0),
    .r1ff00(r1ff00), .r1ff02(r1ff02), .r1ff04(r1ff04),
    .r1ff06(r1ff06), .r1ff5c(r1ff5c), .r1ff5e(r1ff5e),
    .r1ff88(r1ff88), .r1ff8a(r1ff8a), .r1ff8c(r1ff8c),
    .r1ff8e(r1ff8e),
    .scrollfracx(scrollfracx), .scrollfracy(scrollfracy),
    .scrollx(scrollx), .scrolly(scrolly),
    .offsx(offsx), .offsy(offsy), .pages(pages), .zoomx(zoomx),
    .zoomy(zoomy), .clips(clips), .vram_addr(vid_addr),
    .vram_rdata(vid_rdata), .tile_req(tile_req), .tile_addr(tile_addr),
    .tile_data(tile_data), .tile_ack(tile_ack), .lb_we(lb_we),
    .lb_layer(lb_layer), .lb_x(lb_x), .lb_pix(lb_pix), .layer_off_o()
);

always @(posedge clk_ram) begin
    tile_ack <= 1'b0;
    if (tile_req && !tile_ack)
        tile_ack <= 1'b1;
end

integer errors = 0;
integer timeout;
reg found;
integer sim_cycles = 0;
integer render_start_cycles = 0;
integer last_render_cycles = 0;
reg [31:0] render_hash = 32'h811c9dc5;
reg [31:0] last_render_hash = 0;

always @(posedge clk_ram) begin
    sim_cycles = sim_cycles + 1;
    if (lb_we)
        render_hash = {render_hash[26:0], render_hash[31:27]} ^
                      {6'b0, lb_layer, lb_x, lb_pix};
end

task automatic cpu_write(input [15:0] a, input [15:0] d);
begin
    @(negedge clk_sys);
    cpu_addr = a; cpu_wdata = d; cpu_we = 1'b1;
    @(negedge clk_sys);
    cpu_we = 1'b0;
end
endtask

task automatic start_render;
begin
    render_start_cycles = sim_cycles;
    render_hash = 32'h811c9dc5;
    @(negedge clk_ram); line_start = 1'b1;
    @(negedge clk_ram); line_start = 1'b0;
end
endtask

task automatic expect_first_tile(input [18:0] want_addr,
                                 input [2:0] want_layer,
                                 input [13:0] want_pix);
integer pixels;
reg [3:0] want_pen;
reg [13:0] decoded_pix;
begin
    found = 0;
    for (timeout = 0; timeout < 2000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (tile_req) begin
            found = 1;
            if (tile_addr !== want_addr) begin
                $display("FAIL tile address: got %05x want %05x", tile_addr, want_addr);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin $display("FAIL no tile request"); errors = errors + 1; end

    found = 0;
    for (timeout = 0; timeout < 2000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (lb_we && lb_layer == want_layer && lb_x == 0) begin
            found = 1;
            if (lb_pix !== want_pix) begin
                $display("FAIL tile pixel: got %04x want %04x", lb_pix, want_pix);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin $display("FAIL no first tile pixel"); errors = errors + 1; end

    // The old test filled every nibble with A, which let an even/odd nibble
    // reversal pass.  Check the remaining row against MAME's exact
    // bgcharlayout x offsets: 0,4,16,20,8,12,24,28,...
    pixels = 1; // x=0 was consumed by the first-pixel check above
    while (pixels < 16 && timeout < 4000) begin
        @(posedge clk_ram);
        timeout = timeout + 1;
        if (lb_we && lb_layer == want_layer && lb_x == pixels[8:0]) begin
            case (pixels)
                1: want_pen = 4'h2;  2: want_pen = 4'h5;
                3: want_pen = 4'h6;  4: want_pen = 4'h3;
                5: want_pen = 4'h4;  6: want_pen = 4'h7;
                7: want_pen = 4'h8;  8: want_pen = 4'h9;
                9: want_pen = 4'ha; 10: want_pen = 4'hd;
               11: want_pen = 4'he; 12: want_pen = 4'hb;
               13: want_pen = 4'hc; 14: want_pen = 4'hf;
                default: want_pen = 4'h0;
            endcase
            decoded_pix = (want_pen == 0) ? 14'h0000 : (14'h2000 | want_pen);
            if (lb_pix !== decoded_pix) begin
                $display("FAIL tile pixel x=%0d: got %04x want %04x",
                         pixels, lb_pix, decoded_pix);
                errors = errors + 1;
            end
            pixels = pixels + 1;
        end
    end
    if (pixels != 16) begin
        $display("FAIL incomplete decoded tile row (%0d/16 pixels)", pixels);
        errors = errors + 1;
    end
end
endtask

task automatic expect_first_pixel(input [2:0] want_layer,
                                  input [13:0] want_pix);
begin
    found = 0;
    for (timeout = 0; timeout < 5000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (lb_we && lb_layer == want_layer && lb_x == 0) begin
            found = 1;
            if (lb_pix !== want_pix) begin
                $display("FAIL layer %0d pixel: got %04x want %04x",
                         want_layer, lb_pix, want_pix);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin
        $display("FAIL no first pixel for layer %0d", want_layer);
        errors = errors + 1;
    end
end
endtask

task automatic expect_pixel(input [2:0] want_layer,
                            input [8:0] want_x,
                            input [13:0] want_pix);
begin
    found = 0;
    for (timeout = 0; timeout < 5000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (lb_we && lb_layer == want_layer && lb_x == want_x) begin
            found = 1;
            if (lb_pix !== want_pix) begin
                $display("FAIL layer %0d x=%0d pixel: got %04x want %04x",
                         want_layer, want_x, lb_pix, want_pix);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin
        $display("FAIL no pixel for layer %0d x=%0d", want_layer, want_x);
        errors = errors + 1;
    end
end
endtask

task automatic expect_first_request(input [18:0] want_addr);
begin
    found = 0;
    for (timeout = 0; timeout < 3000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (tile_req) begin
            found = 1;
            if (tile_addr !== want_addr) begin
                $display("FAIL first tile request: got %05x want %05x", tile_addr, want_addr);
                errors = errors + 1;
            end
        end
    end
    if (!found) begin
        $display("FAIL no tile request (want %05x)", want_addr);
        errors = errors + 1;
    end
end
endtask

task automatic wait_done;
begin
    found = 0;
    for (timeout = 0; timeout < 10000 && !found; timeout = timeout + 1) begin
        @(posedge clk_ram);
        if (line_done) found = 1;
    end
    if (!found) begin $display("FAIL renderer timeout"); errors = errors + 1; end
    last_render_cycles = sim_cycles - render_start_cycles;
    last_render_hash = render_hash;
    repeat (2) @(posedge clk_ram);
end
endtask

initial begin
    repeat (4) @(posedge clk_ram);
    rst = 0;

    // Register-map regression: rect 5 at byte $1FF80..$1FF86 must map to
    // clips[16..19], not alias rect 3 at clips[8..11].
    cpu_write(16'hffb8, 16'h8108);
    cpu_write(16'hffb9, 16'h9109);
    cpu_write(16'hffba, 16'ha10a);
    cpu_write(16'hffbb, 16'hb10b);
    cpu_write(16'hffc0, 16'h5a10);
    cpu_write(16'hffc1, 16'h5a11);
    cpu_write(16'hffc2, 16'h5a12);
    cpu_write(16'hffc3, 16'h5a13);
    if (clips[8] !== 16'h8108 || clips[9] !== 16'h9109 ||
        clips[10] !== 16'ha10a || clips[11] !== 16'hb10b) begin
        $display("FAIL fifth clip rectangle overwrote rect 3");
        errors = errors + 1;
    end
    if (clips[16] !== 16'h5a10 || clips[17] !== 16'h5a11 ||
        clips[18] !== 16'h5a12 || clips[19] !== 16'h5a13) begin
        $display("FAIL fifth clip rectangle address map");
        errors = errors + 1;
    end

    // Register shadows must merge byte writes exactly like the backing VRAM.
    cpu_be = 2'b01;
    cpu_write(16'hffc0, 16'h00aa);
    cpu_be = 2'b10;
    cpu_write(16'hffc0, 16'hbb00);
    cpu_be = 2'b11;
    if (clips[16] !== 16'hbbaa) begin
        $display("FAIL clip byte-enable merge: got %04x want bbaa", clips[16]);
        errors = errors + 1;
    end

    // Fractional NBG0 scroll words are real render inputs, not padding.
    // Preserve their full CPU-visible value; the renderer consumes X[15:8]
    // and Y[15:9] as MAME's 12.20 fractional coordinate.
    cpu_write(16'hff88, 16'ha500);
    cpu_write(16'hff8a, 16'h5a00);
    if (scrollfracx[0] !== 16'ha500 || scrollfracy[0] !== 16'h5a00) begin
        $display("FAIL fractional scroll shadows: x=%04x y=%04x",
                 scrollfracx[0], scrollfracy[0]);
        errors = errors + 1;
    end
    cpu_write(16'hff88, 16'h0000);
    cpu_write(16'hff8a, 16'h0000);

    // NBG0 name word 1 must request code 1, row 0 (address 0x10).
    cpu_write(16'h0000, 16'h0001);
    cpu_write(16'hff81, 16'h003e); // only NBG0 enabled
    start_render;
    expect_first_tile(19'h00010, 3'd1, 14'h2001);
    wait_done;

    // At neutral zoom MAME sign-extends the center as 9 bits.  Therefore
    // center $1ff means -1 and destination x=0 samples source x=1 (pen 2),
    // not source x=513 as a permanent 10-bit interpretation would produce.
    cpu_write(16'hff98, 16'h01ff);
    start_render;
    expect_first_request(19'h00010);
    expect_first_pixel(3'd1, 14'h2002);
    wait_done;
    cpu_write(16'hff98, 16'h0000);

    // Fractional scroll changes the fixed-point sample before integer
    // truncation.  At zoom 0x180, a 0.75-pixel X fraction makes destination
    // x=1 sample source x=2 instead of source x=1.
    cpu_write(16'hffa8, 16'h0180);
    cpu_write(16'hff88, 16'hc000);
    start_render;
    expect_first_pixel(3'd1, 14'h2001);
    expect_pixel(3'd1, 9'd1, 14'h2005);
    wait_done;
    begin : check_scale_cache
        integer miss_cycles;
        reg [31:0] miss_hash;
        miss_cycles = last_render_cycles;
        miss_hash = last_render_hash;
        start_render;
        expect_first_pixel(3'd1, 14'h2001);
        expect_pixel(3'd1, 9'd1, 14'h2005);
        wait_done;
        $display("TILEMAP SCALE CACHE cycles=%0d->%0d",
                 miss_cycles, last_render_cycles);
        if (last_render_hash !== miss_hash) begin
            $display("FAIL scale-cache pixel hash %08x != %08x",
                     last_render_hash, miss_hash);
            errors = errors + 1;
        end
        if ((miss_cycles - last_render_cycles) < 60) begin
            $display("FAIL scale-cache throughput %0d->%0d (want >=60 saved)",
                     miss_cycles, last_render_cycles);
            errors = errors + 1;
        end
    end
    cpu_write(16'hffa8, 16'h0200);
    cpu_write(16'hff88, 16'h0000);

    // A zoomed destination center uses the full signed 10-bit offset.  With
    // offsx=$200, zoom 0x180, the correct center is -512 and x=0 reaches
    // source x=682 (page 1, column 10 within the page), rather than source x=0 from a
    // neutral-zoom 9-bit sign extension.
    cpu_write(16'hff80, 16'h0000);
    cpu_write(16'hffa8, 16'h0180);
    cpu_write(16'hff98, 16'h0200);
    cpu_write(16'hffa0, 16'h0100); // NBG0 low page 0, high page 1
    cpu_write(16'h020a, 16'h0001); // page 1, row 0, column 10
    start_render;
    expect_first_request(19'h00010); // fetched tile code 1 from page 1
    wait_done;
    cpu_write(16'hffa8, 16'h0200);
    cpu_write(16'hff98, 16'h0000);
    cpu_write(16'hffa0, 16'h0000);

    // $1FF8E[8] makes NBG0 pen 0 opaque without changing its tile data.
    // The test tile's final pixel is pen 0, so the mixer-visible flag must be
    // set while the palette/name payload remains present.
    cpu_write(16'hffc7, 16'h0100);
    start_render;
    expect_first_pixel(3'd1, 14'h2001);
    expect_pixel(3'd1, 9'd15, 14'h2000);
    wait_done;
    cpu_write(16'hffc7, 16'h0000);

    // TEXT name and glyph are two distinct synchronous VRAM reads. Reproduce
    // Golden Axe's captured $1FF5C=$01F7: page $1F and character bank 7.
    cpu_write(16'h7800, 16'h0401); // wrong page $0F name
    cpu_write(16'hf800, 16'h0402); // correct page $1F name
    cpu_write(16'he020, 16'h00f0); // bank 7, char 2, row 0: x0 pen F
    // Bit 8 is the fifth text-page bit; dropping it redirects HUD/GO names
    // from word $F800 to $7800 and makes the dynamic text layer corrupt.
    cpu_write(16'hffae, 16'h01f7);
    cpu_write(16'hff81, 16'h002f); // only TEXT enabled
    start_render;
    expect_first_pixel(3'd0, 14'h202f);
    wait_done;
    cpu_write(16'hffae, 16'h0000);
    cpu_write(16'h0000, 16'h0402);

    // 4bpp bitmap words are little-endian nibble streams. Exercise all four
    // pixels rather than allowing a uniform test word to hide lane reversal.
    cpu_write(16'h0000, 16'h4321);
    cpu_write(16'hff81, 16'h001f); // only BITMAP enabled
    start_render;
    expect_first_pixel(3'd5, 14'h2001);
    expect_pixel(3'd5, 9'd1, 14'h2002);
    expect_pixel(3'd5, 9'd2, 14'h2003);
    expect_pixel(3'd5, 9'd3, 14'h2004);
    wait_done;
    $display("BITMAP 4BPP cycles=%0d", last_render_cycles);
    // A renderer that refetches the same synchronous VRAM word for every
    // nibble takes 969 clocks for this 320-pixel line. Tagged word reuse must
    // retain all four lane values above while completing within 500 clocks.
    if (last_render_cycles > 500) begin
        $display("FAIL bitmap throughput: %0d cycles (want <= 500)",
                 last_render_cycles);
        errors = errors + 1;
    end

    // 4bpp scroll and palette: source (x=5,y=2) is word $0101 nibble 1.
    // $1FF8C contributes all nine palette bits above the four-bit pen.
    cpu_write(16'h0101, 16'h00b0);
    cpu_write(16'hffc4, 16'h0005); // bitmap X scroll
    cpu_write(16'hffc5, 16'h0002); // bitmap Y scroll
    cpu_write(16'hffc6, 16'h0012); // 4bpp palette base
    render_line = 9'd0;
    start_render;
    expect_first_pixel(3'd5, 14'h212b);
    wait_done;

    // 8bpp mode uses little-endian bytes, wraps Y at 8 bits, and tests the
    // complete byte for transparency (pen $10 remains opaque even though its
    // low nibble is zero).  y=$ff + line 2 wraps to source row 1.
    cpu_write(16'h0100, 16'h3410); // row 1, x0=$10, x1=$34
    cpu_write(16'hff80, 16'h0800); // 8bpp bitmap
    cpu_write(16'hffc4, 16'h0000);
    cpu_write(16'hffc5, 16'h00ff);
    cpu_write(16'hffc6, 16'h0030); // 8bpp palette base bits [8:4] = 3
    render_line = 9'd2;
    start_render;
    expect_first_pixel(3'd5, 14'h2310);
    expect_pixel(3'd5, 9'd1, 14'h2334);
    wait_done;
    $display("BITMAP 8BPP cycles=%0d", last_render_cycles);
    if (last_render_cycles > 660) begin
        $display("FAIL 8bpp bitmap throughput: %0d cycles (want <= 660)",
                 last_render_cycles);
        errors = errors + 1;
    end

    // Bitmap clip rectangle is slot 4.  With clip-in, only x=1 is visible;
    // clip-out inverts the same union.  The pen data may remain in a
    // transparent line-buffer word, but bit 13 is the mixer-visible opacity.
    cpu_write(16'h0000, 16'h1111);
    cpu_write(16'hffc0, 16'h0001); // min X
    cpu_write(16'hffc1, 16'h0000); // min Y
    cpu_write(16'hffc2, 16'h0001); // max X (inclusive)
    cpu_write(16'hffc3, 16'h0000); // max Y (inclusive)
    cpu_write(16'hff80, 16'h0000); // 4bpp bitmap
    cpu_write(16'hffc4, 16'h0000);
    cpu_write(16'hffc5, 16'h0000);
    cpu_write(16'hffc6, 16'h0000);
    cpu_write(16'hff81, 16'h801f); // bitmap only, clip enabled, clip-in
    render_line = 9'd0;
    start_render;
    expect_first_pixel(3'd5, 14'h0001);
    expect_pixel(3'd5, 9'd1, 14'h2001);
    wait_done;
    cpu_write(16'hff81, 16'h841f); // same rectangle, clip-out
    start_render;
    expect_first_pixel(3'd5, 14'h2001);
    expect_pixel(3'd5, 9'd1, 14'h0001);
    wait_done;

    // Restore the default bitmap controls before the tilemap-specific cases.
    cpu_write(16'hff80, 16'h0000);
    cpu_write(16'hff81, 16'h003f); // all six rendered layers disabled
    cpu_write(16'hffc4, 16'h0000);
    cpu_write(16'hffc5, 16'h0000);
    cpu_write(16'hffc6, 16'h0000);


    // MAME update_tilemap_rowscroll uses distinct rowscroll (+0x000) and
    // rowselect (+0x200) tables. NBG2 x scroll also subtracts its X origin.
    cpu_write(16'h0042, 16'h0003); // src (x=0x20,y=0x25) -> code 3
    cpu_write(16'h0403, 16'h0010); // NBG2 rowscroll, ylookup 3
    cpu_write(16'h0603, 16'h0025); // NBG2 rowselect, ylookup 3
    cpu_write(16'hff82, 16'h0405); // table page 1, row scroll+select
    cpu_write(16'hff91, 16'h0020); // NBG2 X scroll
    cpu_write(16'hff93, 16'h0000); // NBG2 Y scroll
    cpu_write(16'hff9c, 16'h0010); // NBG2 X origin
    cpu_write(16'hff81, 16'h003b); // only NBG2 enabled
    render_line = 9'd3;
    start_render;
    expect_first_request(19'h00035);
    wait_done;

    // $1FF04 bit (bg+2) disables both per-row features. The screen-wide
    // offset remains active: x=0x20-0x10, y=3 -> name[1], code 4 row 3.
    cpu_write(16'h0001, 16'h0004);
    cpu_write(16'hff82, 16'h0415); // same enables plus NBG2 row disable
    start_render;
    expect_first_request(19'h00043);
    wait_done;

    // With independent-Y disabled, MAME uses zoom X on both axes. Enabling
    // $1FF00 bit 14 switches Y to its own 0x100 factor (2 source px/dest px).
    cpu_write(16'h0000, 16'h0001);
    cpu_write(16'hff82, 16'h0000);
    cpu_write(16'hff89, 16'h0000);
    cpu_write(16'hff8b, 16'h0000);
    cpu_write(16'hff98, 16'h0000);
    cpu_write(16'hff99, 16'h0000);
    cpu_write(16'hffa8, 16'h0200);
    cpu_write(16'hffa9, 16'h0100);
    cpu_write(16'hff80, 16'h0000);
    cpu_write(16'hff81, 16'h003e); // only NBG0 enabled
    render_line = 9'd2;
    start_render;
    expect_first_request(19'h00012);
    wait_done;
    cpu_write(16'hff80, 16'h4000);
    start_render;
    expect_first_request(19'h00014);
    wait_done;

    // NBG layer flip follows MAME compute_tilemap_flips. NBG2 layer flip at
    // dest (0,0) samples source (319,223): name word 0x1b3, code 5 row 15.
    cpu_write(16'h01b3, 16'h0005);
    cpu_write(16'hff80, 16'h0004);
    cpu_write(16'hff81, 16'h003b);
    cpu_write(16'hff91, 16'h0000);
    cpu_write(16'hff93, 16'h0000);
    cpu_write(16'hff9c, 16'h0000);
    render_line = 9'd0;
    start_render;
    expect_first_request(19'h0005f);
    wait_done;

    // Global flip maps the 64x32 text tilemap's first destination pixel to
    // source (511,255), including the character-internal X/Y coordinates.
    cpu_write(16'h07ff, 16'h0402); // palette 2, character 2
    cpu_write(16'h002f, 16'h0a00); // char 2, row 7, x group 1, col 3 = A
    cpu_write(16'hff80, 16'h0200);
    cpu_write(16'hff81, 16'h002f); // only TEXT enabled
    start_render;
    expect_first_pixel(3'd0, 14'h202a);
    wait_done;
    if (errors == 0) $display("TILEMAP VRAM PASS");
    else             $display("TILEMAP VRAM FAIL (%0d errors)", errors);
    $finish;
end

endmodule
