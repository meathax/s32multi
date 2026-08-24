// V60 internal/external cadence regression.
//
// Dark Edge's gameplay timer exposed the failure mode this protects: putting
// the serial CPU FSM on the 16.108 MHz physical-bus CE made its VBlank work
// overrun and coalesce every other pending edge.  Internal execution must run
// at clk_sys/2 (24.158653 MHz), while the physical BCU stays at the production
// 21848/65536 NCO cadence (16.10795 MHz).  The alternating internal CE also
// guarantees the idle edge required by s32.sdc's two-cycle V60 paths.
`timescale 1ns/1ps

module tb_v60_exec_cadence;
reg clk = 1'b0;
reg rst = 1'b1;
reg pause = 1'b0;
wire exec_ce;
always #5 clk = ~clk;

s32_v60_exec_cadence dut (
    .clk(clk), .rst(rst), .pause(pause), .ce(exec_ce)
);

localparam integer WINDOW = 65536;
localparam [15:0] BUS_INC = s32_pkg::PCB_V60_CE_INC;
integer edge_count = 0;
integer exec_count = 0;
integer bus_count = 0;
integer errors = 0;
reg exec_q = 1'b0;
reg [15:0] bus_acc = 16'd0;
reg [16:0] bus_sum;

task automatic check_window;
    integer i;
    begin
        edge_count = 0;
        exec_count = 0;
        bus_count = 0;
        exec_q = 1'b0;
        bus_acc = 16'd0;
        for (i = 0; i < WINDOW; i = i + 1) begin
            @(negedge clk);
            edge_count = edge_count + 1;
            if (exec_ce) exec_count = exec_count + 1;
            if (exec_ce && exec_q) begin
                errors = errors + 1;
                $display("FAIL adjacent execution enables at edge %0d", i);
            end
            exec_q = exec_ce;
            bus_sum = {1'b0, bus_acc} + {1'b0, BUS_INC};
            bus_acc = bus_sum[15:0];
            if (bus_sum[16]) bus_count = bus_count + 1;
        end
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 1'b0;
    check_window();

    if (exec_count != 32768) begin
        errors = errors + 1;
        $display("FAIL exec count %0d != 32768", exec_count);
    end
    if (bus_count != 21848) begin
        errors = errors + 1;
        $display("FAIL bus count %0d != 21848", bus_count);
    end

    @(negedge clk); pause = 1'b1;
    repeat (17) begin
        @(negedge clk);
        if (exec_ce !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL execution enable active while paused");
        end
    end
    @(negedge clk); pause = 1'b0;
    #1; // allow the combinational CE to settle after pause changes
    if (exec_ce !== 1'b1) begin
        errors = errors + 1;
        $display("FAIL cadence did not restart on its first phase");
    end
    @(negedge clk);
    if (exec_ce !== 1'b0) begin
        errors = errors + 1;
        $display("FAIL cadence did not alternate after pause release");
    end

    $display("V60 EXEC CADENCE SUMMARY raw=%0d exec=%0d bus=%0d",
             edge_count, exec_count, bus_count);
    if (errors == 0)
        $display("V60 EXEC CADENCE PASS");
    else
        $fatal(1, "V60 EXEC CADENCE FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "V60 EXEC CADENCE FAIL (timeout)");
end
endmodule
