// MAME-exact System 32 tilemap reciprocal gate (12.20 source coordinates).
`timescale 1ns/1ps

module tb_tilemap_scale;
reg clk = 0, rst = 1, start = 0;
reg [11:0] xden = 0, yden = 0;
wire busy, done;
wire [22:0] xquot, yquot;
integer errors = 0;

always #5 clk = ~clk;

s32_tilemap_scale_div dut (
    .clk(clk), .rst(rst), .start(start),
    .xden(xden), .yden(yden), .busy(busy), .done(done),
    .xquot(xquot), .yquot(yquot)
);

task automatic check_pair(
    input [11:0] xd, input [11:0] yd,
    input [22:0] want_x, input [22:0] want_y
);
begin
    @(negedge clk);
    xden = xd; yden = yd; start = 1;
    @(negedge clk);
    start = 0;
    wait (done);
    if (xquot !== want_x || yquot !== want_y) begin
        $display("FAIL scale x %03x -> %06x (want %06x), y %03x -> %06x (want %06x)",
                 xd, xquot, want_x, yd, yquot, want_y);
        errors = errors + 1;
    end
end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 0;
    check_pair(11'h200, 11'h100, 23'h100000, 23'h200000);
    check_pair(11'h080, 11'h400, 23'h400000, 23'h080000);
    check_pair(12'hfff, 12'h200, 23'h020020, 23'h100000);
    // floor(0x20000000 / denominator), including non-power-of-two cases.
    check_pair(11'h123, 11'h37b, 23'h1c26b5, 23'h0931b4);
    if (errors == 0) $display("TILEMAP SCALE PASS");
    else $fatal(1, "TILEMAP SCALE FAIL (%0d errors)", errors);
    $finish;
end
endmodule
