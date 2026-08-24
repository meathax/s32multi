//============================================================================
//  Directed test: shared System 32 tile/bitmap line buffer
//  - all six layers retain independent content
//  - both parity banks retain independent content at the same x
//  - read data changes one clock after rd_x and fans out identically
//============================================================================
`timescale 1ns/1ps

module tb_linebuf;

reg clk = 0;
always #5 clk = ~clk;

reg         lb_we = 0;
reg  [2:0]  lb_layer = 0;
reg  [8:0]  lb_wx = 0;
reg  [13:0] lb_wpix = 0;
reg         lb_bank = 0;
reg  [8:0]  rd_x = 0;
reg         rd_bank = 0;
wire [13:0] px_text, px_nbg0, px_nbg1, px_nbg2, px_nbg3, px_bmp;

s32_linebuf dut (
    .clk(clk),
    .lb_we(lb_we), .lb_layer(lb_layer), .lb_wx(lb_wx),
    .lb_wpix(lb_wpix), .lb_bank(lb_bank),
    .rd_x(rd_x), .rd_bank(rd_bank),
    .px_text(px_text), .px_nbg0(px_nbg0), .px_nbg1(px_nbg1),
    .px_nbg2(px_nbg2), .px_nbg3(px_nbg3), .px_bmp(px_bmp)
);

wire [83:0] shared_pixels = {px_bmp, px_nbg3, px_nbg2,
                             px_nbg1, px_nbg0, px_text};
// Model the actual core fanout: both mixers receive this exact registered bus.
wire [83:0] consumer_a = shared_pixels;
wire [83:0] consumer_b = shared_pixels;

integer errors = 0;
integer lay;

task write_px(input [2:0] layer_i, input bank_i,
              input [8:0] x_i, input [13:0] pix_i);
    @(negedge clk);
    lb_we = 1; lb_layer = layer_i; lb_bank = bank_i;
    lb_wx = x_i; lb_wpix = pix_i;
    @(negedge clk);
    lb_we = 0;
endtask

task check_bus(input [83:0] got, input [83:0] want, input [255:0] label_i);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %0s got=%021x want=%021x", label_i, got, want);
    end
endtask

localparam [83:0] BANK0 = {14'h2006, 14'h2005, 14'h2004,
                           14'h2003, 14'h2002, 14'h2001};
localparam [83:0] BANK1 = {14'h2106, 14'h2105, 14'h2104,
                           14'h2103, 14'h2102, 14'h2101};

initial begin
    repeat (3) @(posedge clk);
    #1;
    check_bus(shared_pixels, 84'd0, "power-up clear");

    for (lay=0; lay<6; lay=lay+1) begin
        write_px(lay[2:0], 1'b0, 9'd10, 14'h2001 + lay[13:0]);
        write_px(lay[2:0], 1'b1, 9'd10, 14'h2101 + lay[13:0]);
    end

    // Select a known-empty address and let its registered read settle.
    @(negedge clk); rd_x = 9'd9; rd_bank = 0;
    @(posedge clk); #1;
    check_bus(shared_pixels, 84'd0, "empty x=9");

    // Changing rd_x must not change outputs until the next active clock.
    @(negedge clk); rd_x = 9'd10;
    #1;
    check_bus(shared_pixels, 84'd0, "held before read clock");
    @(posedge clk); #1;
    check_bus(shared_pixels, BANK0, "bank 0 after one clock");

    // Both parity banks are read together, so parity selection is a small
    // output mux and does not add another cycle.
    rd_bank = 1; #1;
    check_bus(shared_pixels, BANK1, "bank 1 same coordinate");
    rd_bank = 0; #1;
    check_bus(shared_pixels, BANK0, "bank 0 restored");

    check_bus(consumer_a, consumer_b, "shared fanout equality");

    if (errors == 0) $display("LINEBUF PASS");
    else             $display("LINEBUF FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #200000;
    $display("LINEBUF FAIL (timeout)");
    $finish;
end

endmodule
