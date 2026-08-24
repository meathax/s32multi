`timescale 1ns/1ps

module tb_video_mode;
reg clk = 1'b0;
reg rst = 1'b1;
reg mode_416 = 1'b1;
always #5 clk = ~clk;

wire ce_pix, mode_active;
wire [8:0] hcnt, vcnt;
wire hb, vb, hs, vs, vb_start, vb_end;

s32_video dut (
    .clk(clk), .rst(rst), .mode_416(mode_416),
    .ce_pix(ce_pix), .mode_active(mode_active),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb), .vblank(vb),
    .hsync(hs), .vsync(vs), .vblank_start(vb_start), .vblank_end(vb_end)
);

integer errors = 0;
integer sim_cycle = 0;
reg saw_416_end = 1'b0;
reg saw_320_end = 1'b0;

localparam integer LINE_416_CYCLES = 512 * 6;
localparam integer LINE_320_CYCLES = 410 * 15 / 2;

integer last_416_end = -1;
integer count_416_lines = 0;
integer last_320_end = -1;
integer count_320_lines = 0;
reg hs_prev = 1'b0;
integer hs_rise_cycle = -1;
reg hs_mode = 1'b0;
integer last_416_hs_width = -1;
integer last_320_hs_width = -1;

always @(posedge clk) begin
    sim_cycle = sim_cycle + 1;

    // The direct-video sync source must have a repeatable line period.  The
    // old NCO implementation failed this invariant on consumer CRTs because
    // its accumulator did not repeat within one 320-mode line.
    if (ce_pix && mode_active && hcnt == 9'd511) begin
        saw_416_end = 1'b1;
        if (last_416_end >= 0 && sim_cycle - last_416_end != LINE_416_CYCLES) begin
            errors = errors + 1;
            $display("  FAIL 416 line period %0d, expected %0d",
                     sim_cycle - last_416_end, LINE_416_CYCLES);
        end
        last_416_end = sim_cycle;
        count_416_lines = count_416_lines + 1;
    end
    if (ce_pix && !mode_active && hcnt == 9'd409) begin
        saw_320_end = 1'b1;
        if (last_320_end >= 0 && sim_cycle - last_320_end != LINE_320_CYCLES) begin
            errors = errors + 1;
            $display("  FAIL 320 line period %0d, expected %0d",
                     sim_cycle - last_320_end, LINE_320_CYCLES);
        end
        last_320_end = sim_cycle;
        count_320_lines = count_320_lines + 1;
    end
    // Require the fixed OutRunners raw HSync pulse to occupy the same number
    // of clk_sys cycles on every line.
    if (hs && !hs_prev) begin
        hs_rise_cycle = sim_cycle;
        hs_mode = mode_active;
    end
    else if (!hs && hs_prev && hs_rise_cycle >= 0) begin
        if (hs_mode) begin
            if (last_416_hs_width >= 0 &&
                sim_cycle - hs_rise_cycle != last_416_hs_width) begin
                errors = errors + 1;
                $display("  FAIL 416 HSync width %0d, previous %0d clk_sys cycles",
                         sim_cycle - hs_rise_cycle, last_416_hs_width);
            end
            last_416_hs_width = sim_cycle - hs_rise_cycle;
        end
        else begin
            if (last_320_hs_width >= 0 &&
                sim_cycle - hs_rise_cycle != last_320_hs_width) begin
                errors = errors + 1;
                $display("  FAIL 320 HSync width %0d, previous %0d clk_sys cycles",
                         sim_cycle - hs_rise_cycle, last_320_hs_width);
            end
            last_320_hs_width = sim_cycle - hs_rise_cycle;
        end
        hs_rise_cycle = -1;
    end
    hs_prev = hs;
end

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
    wait (vcnt == 9'd3 && hcnt == 9'd100);
    while (count_416_lines < 5) @(posedge clk);
    while (count_416_lines < 8) @(posedge clk);
    if (!saw_416_end) begin
        errors = errors + 1;
        $display("  FAIL missing complete-width 416 line endpoint");
    end
    mode_416 = 1'b0;
    wait (!mode_active);
    while (count_320_lines < 8) @(posedge clk);
    if (!saw_320_end) begin
        errors = errors + 1;
        $display("  FAIL missing complete-width 320 line endpoint");
    end
    if (last_320_hs_width != 240) begin
        errors = errors + 1;
        $display("  FAIL 320 HSync width %0d, expected 240", last_320_hs_width);
    end
    if (errors == 0) begin
        $display("VIDEO TIMING STABLE 416_LINE=%0d HSYNC_416=%0d 320_LINE=%0d HSYNC_320=%0d",
                 LINE_416_CYCLES, last_416_hs_width,
                 LINE_320_CYCLES, last_320_hs_width);
        $display("VIDEO MODE LATCH PASS");
    end
    else $display("VIDEO MODE LATCH FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #30000000;
    $display("VIDEO MODE LATCH FAIL (timeout)");
    $finish;
end
endmodule
