//============================================================================
// Integrated sprite framebuffer stress test.
//
// Unlike tb_core_romboot (which uses a behavioral framebuffer service), this
// bench connects the real s32_sprite and s32_fb_if modules to a backpressured
// MiSTer-style DDR model.  It proves that repeated erase -> render -> flush
// passes complete and that rendered pixels survive the physical DDR protocol.
//============================================================================
`timescale 1ns/1ps

module tb_sprite_fb;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// Registered sprite-list RAM port, matching the dual-port BRAM in s32_core.
reg [15:0] sram [0:16383];
wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr[13:0]];

// One 4-bpp source word containing pens 1..8 in big-endian pixel order.
wire        srom_req;
wire [23:4] srom_addr;
reg         srom_ack = 0;
reg [127:0] srom_data = 128'h0;
always @(posedge clk) begin
    srom_ack <= srom_req;
    if (srom_req) begin
        srom_data <= 128'h0;
        srom_data[31:0] <= 32'h7856_3412;
    end
end

// Sprite -> framebuffer run/erase ports.
wire        fbw_start, fbw_valid, fbw_end, fbw_shadow, fbw_busy, fbw_can_start;
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

reg vblank = 0;
reg present = 0;
s32_sprite sprite (
    .clk(clk), .rst(rst), .is_multi32(1'b0), .screen_sel(1'b0),
    .present(present),
    .verify_srom(1'b0),
    .srom_bank_mask(2'b11),
    .vblank(vblank),
    .ctl_we(1'b0), .ctl_addr(3'd0), .ctl_wdata(8'd0),
    .ctl_rdata(), .ctl_raddr(3'd0),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fbw_start), .fb_wr_buf(fbw_buf),
    .fb_wr_x(fbw_x), .fb_wr_y(fbw_y), .fb_wr_valid(fbw_valid),
    .fb_wr_pix(fbw_pix), .fb_wr_end(fbw_end),
    .fb_wr_shadow(fbw_shadow), .fb_busy(fbw_busy), .fb_can_start(fbw_can_start),
    .fb_er_req(fbe_req), .fb_er_buf(fbe_buf), .fb_er_y(fbe_y),
    .fb_er_ack(fbe_ack), .disp_buf(disp_buf), .scan_buf(scan_buf)
);
assign rendering = sprite.rs != 0;

// MiSTer DDR interface.
wire        dd_busy;
wire [7:0]  dd_burst;
wire [28:0] dd_addr;
reg  [63:0] dd_dout = 0;
reg         dd_ready = 0;
wire        dd_rd, dd_we;
wire [63:0] dd_din;
wire [7:0]  dd_be;

s32_fb_if #(.FB_BASE(32'h3000_0000)) fb (
    .clk(clk), .rst(rst),
    .DDRAM_BUSY(dd_busy), .DDRAM_BURSTCNT(dd_burst),
    .DDRAM_ADDR(dd_addr), .DDRAM_DOUT(dd_dout),
    .DDRAM_DOUT_READY(dd_ready), .DDRAM_RD(dd_rd),
    .DDRAM_DIN(dd_din), .DDRAM_BE(dd_be), .DDRAM_WE(dd_we),
    .wr_start(fbw_start), .wr_buf(fbw_buf), .wr_x(fbw_x), .wr_y(fbw_y),
    .wr_valid(fbw_valid), .wr_pix(fbw_pix), .wr_end(fbw_end),
    .wr_shadow(fbw_shadow), .wr_busy(fbw_busy), .wr_can_start(fbw_can_start),
    .er_req(fbe_req), .er_buf(fbe_buf), .er_y(fbe_y), .er_ack(fbe_ack),
    .rd_req(1'b0), .rd_buf(2'd0),
    .rd_y(8'd0), .rd_ack(),
    .rd_x(9'd0), .rd_pix()
);

// Four complete 512x256x16bpp buffers, indexed as 64-bit words relative to
// FB_BASE.  Random-looking deterministic backpressure stresses request hold.
reg [63:0] ddr [0:131071];
integer di;
initial for (di = 0; di < 131072; di = di + 1) ddr[di] = 64'h0;

reg [7:0] busy_lfsr = 8'hd3;
integer model_cycle = 0;
assign dd_busy = (model_cycle[3:0] == 4'h5) ||
                 (busy_lfsr[0] && busy_lfsr[3]);
always @(posedge clk) begin
    if (rst) begin
        busy_lfsr <= 8'hd3;
        model_cycle <= 0;
    end
    else begin
        model_cycle <= model_cycle + 1;
        busy_lfsr <= {busy_lfsr[6:0],
                      busy_lfsr[7] ^ busy_lfsr[5] ^
                      busy_lfsr[4] ^ busy_lfsr[3]};
    end
end

wire [16:0] ddr_index = dd_addr[16:0];
integer errors = 0;
integer write_accepts = 0;
always @(posedge clk) begin
    dd_ready <= 1'b0;
    if (!rst && dd_we && !dd_busy) begin
        write_accepts = write_accepts + 1;
        if (dd_burst !== 8'd1) begin
            errors = errors + 1;
            $display("  FAIL write burst=%0d addr=%08x", dd_burst, dd_addr);
        end
        if (dd_be[0]) ddr[ddr_index][ 7: 0] <= dd_din[ 7: 0];
        if (dd_be[1]) ddr[ddr_index][15: 8] <= dd_din[15: 8];
        if (dd_be[2]) ddr[ddr_index][23:16] <= dd_din[23:16];
        if (dd_be[3]) ddr[ddr_index][31:24] <= dd_din[31:24];
        if (dd_be[4]) ddr[ddr_index][39:32] <= dd_din[39:32];
        if (dd_be[5]) ddr[ddr_index][47:40] <= dd_din[47:40];
        if (dd_be[6]) ddr[ddr_index][55:48] <= dd_din[55:48];
        if (dd_be[7]) ddr[ddr_index][63:56] <= dd_din[63:56];
    end
    if (!rst && dd_rd) begin
        errors = errors + 1;
        $display("  FAIL unexpected DDR read");
    end
end

task entry(input [13:0] e, input [15:0] w0, w1, w2, w3, w4, w5, w6, w7);
    sram[{e[10:0], 3'd0}]     = w0;
    sram[{e[10:0], 3'd0} + 1] = w1;
    sram[{e[10:0], 3'd0} + 2] = w2;
    sram[{e[10:0], 3'd0} + 3] = w3;
    sram[{e[10:0], 3'd0} + 4] = w4;
    sram[{e[10:0], 3'd0} + 5] = w5;
    sram[{e[10:0], 3'd0} + 6] = w6;
    sram[{e[10:0], 3'd0} + 7] = w7;
endtask

function [15:0] ddr_pix(input [1:0] bufsel, input [7:0] y, input [8:0] x);
    logic [16:0] word_index;
    word_index = {bufsel, 15'b0} + ({9'b0, y} << 7) + x[8:2];
    ddr_pix = ddr[word_index] >> {x[1:0], 4'b0000};
endfunction

task check_pix(input [1:0] bufsel, input [7:0] y, input [8:0] x,
               input [15:0] want);
    reg [15:0] got;
    got = ddr_pix(bufsel, y, x);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL buf=%0d y=%0d x=%0d got=%04x want=%04x",
                 bufsel, y, x, got, want);
    end
endtask

task run_frame(input [1:0] expected_back_buf);
    integer x;
    // Publish the prior completed frame at vblank start, then launch the next
    // logical erase/swap/render at vblank end.
    @(posedge clk); present <= 1'b1;
    @(posedge clk); present <= 1'b0;
    @(posedge clk); vblank <= 1'b1;
    @(posedge clk); vblank <= 1'b0;
    wait (rendering === 1'b1);
    wait (rendering === 1'b0);
    wait (!fbw_busy);
    repeat (4) @(posedge clk);

    check_pix(expected_back_buf, 8'd20, 9'd29, 16'hffff);
    for (x = 0; x < 8; x = x + 1)
        check_pix(expected_back_buf, 8'd20, 9'd30 + x,
                  16'h8101 + x);
    check_pix(expected_back_buf, 8'd20, 9'd38, 16'hffff);
endtask

integer si;
initial begin
    for (si = 0; si < 16384; si = si + 1) sram[si] = 16'hc000;

    // One 8x1 direct sprite at (30,20), alignment=start, followed by END.
    entry(0, 16'h000a, 16'h0102, 16'h0001, 16'h0008,
          16'd20, 16'd30, 16'h0000, 16'h0100);
    entry(1, 16'hc000, 0,0,0,0,0,0,0);

    repeat (6) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);

    // Physical scanout and logical A/B ownership are separate. The first
    // hidden render uses slot 1, then publication rotates work safely.
    run_frame(2'd1);
    run_frame(2'd0);
    run_frame(2'd1);

    if (write_accepts < (3 * 224 * 128)) begin
        errors = errors + 1;
        $display("  FAIL too few DDR writes: %0d", write_accepts);
    end

    if (errors == 0) $display("SPRITE FB PASS");
    else             $display("SPRITE FB FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #10000000;
    $display("SPRITE FB FAIL (timeout)");
    $finish;
end

endmodule
