//============================================================================
// Tile scanline scheduler deadline/backpressure test.
//
// Models a tile renderer whose SDRAM acknowledgement is delayed across whole
// scanline boundaries.  Source controls continue changing while it is busy;
// the accepted line, parity bank, and captured controls must remain stable.
//============================================================================
`timescale 1ns/1ps

module tb_tile_scheduler;

reg clk = 0;
always #5 clk = ~clk;

reg        rst = 1;
reg        line_kick = 0;
reg  [8:0] next_line = 0;
reg        line_done = 0;
wire       line_start;
wire [8:0] render_line;
wire       lb_bank;
wire       busy;

s32_tile_line_scheduler dut (
    .clk(clk), .rst(rst),
    .line_kick(line_kick), .next_line(next_line),
    .line_done(line_done), .line_start(line_start),
    .render_line(render_line), .lb_bank(lb_bank), .busy(busy)
);

// This is the same capture relationship used by s32_core: source controls
// may change at any time, but the renderer consumes only the line-start copy.
reg [15:0] source_control = 16'h0000;
reg [15:0] captured_control = 16'h0000;
always @(posedge clk)
    if (line_start)
        captured_control <= source_control;

integer errors = 0;
integer start_count = 0;
always @(posedge clk)
    if (line_start)
        start_count = start_count + 1;

task automatic fail(input [8*96-1:0] message);
begin
    $display("FAIL %0s", message);
    errors = errors + 1;
end
endtask

task automatic hold_check(
    input [8:0] expected_line,
    input       expected_bank,
    input [15:0] expected_control
);
begin
    if (render_line !== expected_line)
        fail("render line changed while renderer was stalled");
    if (lb_bank !== expected_bank)
        fail("line-buffer bank changed while renderer was stalled");
    if (captured_control !== expected_control)
        fail("captured video controls changed while renderer was stalled");
end
endtask

initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // The crossed-domain boundary level is deliberately two clocks wide.
    // It must produce exactly one accepted launch.
    source_control = 16'ha55a;
    next_line = 9'd5;
    line_kick = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!line_start || !busy || render_line !== 9'd5 || lb_bank !== 1'b1)
        fail("first boundary was not accepted correctly");
    @(posedge clk);
    @(negedge clk);
    line_kick = 1'b0;
    source_control = 16'h1111;
    @(posedge clk);
    @(negedge clk);
    if (start_count != 1)
        fail("multi-cycle line_kick produced duplicate starts");
    hold_check(9'd5, 1'b1, 16'ha55a);

    // Delay completion as an SDRAM stall would.  A new boundary is dropped
    // and counted, without retargeting the current line or its control copy.
    source_control = 16'h2222;
    next_line = 9'd6;
    line_kick = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hold_check(9'd5, 1'b1, 16'ha55a);
    @(posedge clk);
    @(negedge clk);
    line_kick = 1'b0;
    source_control = 16'h3333;
    @(posedge clk);
    @(negedge clk);
    hold_check(9'd5, 1'b1, 16'ha55a);
    if (start_count != 1)
        fail("busy renderer accepted a second line");

    // Completion without a boundary only releases busy; it must not launch
    // the stale line that was dropped above.
    line_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    line_done = 1'b0;
    @(posedge clk);
    @(negedge clk);
    if (busy || start_count != 1)
        fail("completion launched a stale pending line");
    hold_check(9'd5, 1'b1, 16'ha55a);

    // A later real boundary starts the current line normally.
    source_control = 16'h1234;
    next_line = 9'd6;
    line_kick = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!line_start || render_line !== 9'd6 || lb_bank !== 1'b0)
        fail("idle scheduler did not accept next boundary");
    line_kick = 1'b0;
    @(posedge clk);
    @(negedge clk);
    if (start_count != 2 || captured_control !== 16'h1234 || !busy)
        fail("second launch/control snapshot was incorrect");

    // The tilemap exposes line_done as a one-cycle pulse after returning to
    // idle.  A boundary on that cycle must replace the completed job without
    // an idle bubble or a false overrun.
    source_control = 16'hcafe;
    next_line = 9'd7;
    line_done = 1'b1;
    line_kick = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!line_start || !busy || render_line !== 9'd7 || lb_bank !== 1'b1)
        fail("simultaneous done/boundary was not accepted");
    line_done = 1'b0;
    line_kick = 1'b0;
    @(posedge clk);
    @(negedge clk);
    if (start_count != 3 || captured_control !== 16'hcafe || !busy)
        fail("back-to-back launch lost its control snapshot");

    // The accepted state remains fixed until the final delayed completion.
    source_control = 16'hdead;
    next_line = 9'd20;
    repeat (8) begin
        @(posedge clk);
        @(negedge clk);
        hold_check(9'd7, 1'b1, 16'hcafe);
    end
    line_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    line_done = 1'b0;
    if (busy)
        fail("final completion did not release scheduler");

    if (errors == 0)
        $display("TILE SCHEDULER PASS");
    else
        $display("TILE SCHEDULER FAIL (%0d errors)", errors);
    $finish;
end

endmodule
