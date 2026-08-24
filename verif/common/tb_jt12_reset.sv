`timescale 1ns/1ps

// Production jt12 reset/idle determinism.  Unknown idle samples poison the
// signed System 32 output mixer even before the Z80 programs either YM3438.
module tb_jt12_reset;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg [2:0] div6 = 3'd0;
    reg cen = 1'b0;
    wire [7:0] dout;
    wire irq_n;
    wire signed [15:0] snd_l, snd_r;

    always @(posedge clk) begin
        div6 <= div6 == 3'd5 ? 3'd0 : div6 + 1'd1;
        cen <= div6 == 3'd0;
    end

    jt12 dut (
        .rst(rst), .clk(clk), .cen(cen), .din(8'd0), .addr(2'd0),
        .cs_n(1'b1), .wr_n(1'b1), .dout(dout), .irq_n(irq_n),
        .en_hifi_pcm(1'b1), .snd_left(snd_l), .snd_right(snd_r),
        .snd_sample()
    );

    initial begin
        // jt12's resettable operator/envelope rings are 24 stages deep and
        // advance on its internal /6 enable.  Flush the longest ring fully.
        repeat (2048) @(posedge clk);
        rst = 1'b0;
        // Two complete 24-operator frames are required before the registered
        // accumulator output has captured a post-reset known sum.
        repeat (5000) @(posedge clk);
        if (^{snd_l, snd_r, dout, irq_n} === 1'bx) begin
            $display("JT12 diag zero=%b rl=%b op=%h pre=%h/%h acc=%h/%h sum=%b/%b",
                     dut.u_jt12.zero, dut.u_jt12.rl, dut.u_jt12.op_result,
                     dut.u_jt12.gen_pcm_acc.u_acc.pre_left,
                     dut.u_jt12.gen_pcm_acc.u_acc.pre_right,
                     dut.u_jt12.gen_pcm_acc.u_acc.u_left.acc,
                     dut.u_jt12.gen_pcm_acc.u_acc.u_right.acc,
                     dut.u_jt12.gen_pcm_acc.u_acc.u_left.sum_en,
                     dut.u_jt12.gen_pcm_acc.u_acc.u_right.sum_en);
            $fatal(1, "JT12 idle output remains unknown l=%h r=%h dout=%h irq=%b",
                   snd_l, snd_r, dout, irq_n);
        end
        if (snd_l !== 16'sd0 || snd_r !== 16'sd0)
            $fatal(1, "JT12 idle output is not silent l=%0d r=%0d", snd_l, snd_r);
        $display("JT12 RESET PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "JT12 reset timeout");
    end
endmodule
