`timescale 1ns/1ps

module tb_monitor_audio_route;

reg signed [15:0] monitor_a;
reg signed [15:0] monitor_b;
reg               screen_sel;
reg               splitscreen;
wire signed [15:0] audio_l;
wire signed [15:0] audio_r;

integer errors = 0;

s32_monitor_audio_route dut (.*);

task automatic check_route(
    input select_b,
    input split,
    input signed [15:0] expected_l,
    input signed [15:0] expected_r
);
begin
    screen_sel = select_b;
    splitscreen = split;
    #1;
    if (audio_l !== expected_l || audio_r !== expected_r) begin
        $display("FAIL select_b=%0d split=%0d got=%0d/%0d expected=%0d/%0d",
                 select_b, split, audio_l, audio_r, expected_l, expected_r);
        errors = errors + 1;
    end
end
endtask

initial begin
    monitor_a = 16'sd1234;
    monitor_b = -16'sd2345;

    check_route(1'b0, 1'b0, monitor_a, monitor_a);
    check_route(1'b1, 1'b0, monitor_b, monitor_b);
    check_route(1'b0, 1'b1, monitor_a, monitor_b);
    check_route(1'b1, 1'b1, monitor_a, monitor_b);

    if (errors == 0) $display("MONITOR AUDIO ROUTE PASS");
    else $fatal(1, "MONITOR AUDIO ROUTE FAIL errors=%0d", errors);
    $finish;
end

endmodule
