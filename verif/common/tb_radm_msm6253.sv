`timescale 1ns/1ps

// Focused Rad Mobile analog-board check against MAME 0.288:
//   segas32.cpp system32_analog_map() maps the MSM6253 at 0xc00050-57;
//   msm6253.cpp address_w() selects ANALOG1..4 and d7_r() returns the
//   current MSB before shifting it left.
// Rad Mobile defines ANALOG1=wheel (0x80), ANALOG2=accelerator (0x00),
// ANALOG3=brake (0x00), and leaves ANALOG4 unassigned (MAME returns 0xff).
module tb_radm_msm6253;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [1:0] addr = 2'd0;
    wire dout_bit;

    s32_msm6253 dut (
        .clk(clk), .rst(rst), .cs(cs), .we(we), .addr(addr),
        .dout_bit(dout_bit),
        .an0(8'h80), .an1(8'h00), .an2(8'h00), .an3(8'hff)
    );

    integer errors = 0;

    task automatic select_channel(input [1:0] a);
        begin
            @(negedge clk);
            addr = a;
            cs = 1'b1;
            we = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cs = 1'b0;
            we = 1'b0;
            // Clear the one-shot read history before the next transaction.
            @(posedge clk);
        end
    endtask

    task automatic read_first_bit(input bit expected, input [1:0] a);
        begin
            @(negedge clk);
            addr = a;
            cs = 1'b1;
            we = 1'b0;
            // MAME d7_r() observes the MSB before applying its read shift.
            #1;
            if (dout_bit !== expected) begin
                $display("FAIL: channel %0d first D7=%0d expected=%0d",
                         a, dout_bit, expected);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            cs = 1'b0;
            // The device must not shift again while the same bus request is
            // held; then provide an idle edge for the next request.
            @(posedge clk);
        end
    endtask

    task automatic check_held_read;
        begin
            select_channel(2'd0);
            @(negedge clk);
            cs = 1'b1;
            we = 1'b0;
            #1;
            if (dout_bit !== 1'b1) begin
                $display("FAIL: held-read first bit=%0d expected=1", dout_bit);
                errors = errors + 1;
            end
            @(posedge clk);
            #1;
            if (dout_bit !== 1'b0) begin
                $display("FAIL: held-read shifted bit=%0d expected=0", dout_bit);
                errors = errors + 1;
            end
            // Keep CS asserted for another clock: one bus read must shift once.
            @(posedge clk);
            #1;
            if (dout_bit !== 1'b0) begin
                $display("FAIL: held-read shifted twice, bit=%0d", dout_bit);
                errors = errors + 1;
            end
            @(negedge clk);
            cs = 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // MAME's four Rad Mobile input channels: 0x80, 0x00, 0x00, 0xff.
        select_channel(2'd0); read_first_bit(1'b1, 2'd0);
        select_channel(2'd1); read_first_bit(1'b0, 2'd1);
        select_channel(2'd2); read_first_bit(1'b0, 2'd2);
        select_channel(2'd3); read_first_bit(1'b1, 2'd3);

        // 0x80 has a zero second bit. A held request must expose that bit,
        // not advance again; this is the transaction-side effect in MAME.
        check_held_read();

        if (errors != 0)
            $fatal(1, "Rad Mobile MSM6253 test failed with %0d errors", errors);
        $display("RAD MOBILE MSM6253 PASS");
        $finish;
    end
endmodule
