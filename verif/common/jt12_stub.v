module jt12 (
    input rst, input clk, input cen,
    input [7:0] din, input [1:0] addr,
    input cs_n, input wr_n,
    output [7:0] dout, output irq_n,
    input en_hifi_pcm,
    output signed [15:0] snd_left, output signed [15:0] snd_right,
    output snd_sample
);
assign dout = 8'h00; assign irq_n = 1'b1;
assign snd_left = 0; assign snd_right = 0; assign snd_sample = 0;
endmodule
