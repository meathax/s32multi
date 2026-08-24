`timescale 1ns/1ps

module tb_sdram_write_mux2;
reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;
reg c0_req = 1'b0, c1_req = 1'b0, d_ack = 1'b0;
reg [24:1] c0_addr = 24'd0, c1_addr = 24'd0;
reg [15:0] c0_data = 16'd0, c1_data = 16'd0;
reg [1:0] c0_be = 2'd0, c1_be = 2'd0;
wire c0_ack, c1_ack, d_req;
wire [24:1] d_addr;
wire [15:0] d_data;
wire [1:0] d_be;

s32_sdram_write_mux2 dut (
    .clk(clk), .rst(rst),
    .c0_req(c0_req), .c0_addr(c0_addr), .c0_data(c0_data), .c0_be(c0_be), .c0_ack(c0_ack),
    .c1_req(c1_req), .c1_addr(c1_addr), .c1_data(c1_data), .c1_be(c1_be), .c1_ack(c1_ack),
    .d_req(d_req), .d_addr(d_addr), .d_data(d_data), .d_be(d_be), .d_ack(d_ack)
);

initial begin
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    // Both clients request together: loader/client 0 wins.
    @(negedge clk);
    c0_req = 1'b1; c0_addr = 24'h001234; c0_data = 16'ha55a; c0_be = 2'b11;
    c1_req = 1'b1; c1_addr = 24'h005678; c1_data = 16'h00cc; c1_be = 2'b01;
    @(posedge clk); #1;
    if (!d_req || d_addr != 24'h001234 || d_data != 16'ha55a || d_be != 2'b11)
        $fatal(1, "client-0 priority/payload mismatch");

    // Upstream movement cannot corrupt the accepted transaction.
    @(negedge clk); c0_addr = 24'h00ffff; c0_data = 16'hdead; c0_be = 2'b10;
    repeat (2) begin
        @(posedge clk); #1;
        if (d_addr != 24'h001234 || d_data != 16'ha55a || d_be != 2'b11)
            $fatal(1, "downstream payload was not held");
    end
    @(negedge clk); d_ack = 1'b1;
    #1;
    if (!c0_ack || c1_ack) $fatal(1, "client-0 ACK isolation failed");
    @(posedge clk); #1;
    @(negedge clk); d_ack = 1'b0; c0_req = 1'b0;

    // Client 1 was already waiting and must be accepted after owner rearm.
    repeat (3) @(posedge clk);
    #1;
    if (!d_req || d_addr != 24'h005678 || d_data != 16'h00cc || d_be != 2'b01)
        $fatal(1, "waiting client-1 transaction was lost");
    @(negedge clk); d_ack = 1'b1;
    #1;
    if (c0_ack || !c1_ack) $fatal(1, "client-1 ACK isolation failed");
    @(posedge clk); #1;
    @(negedge clk); d_ack = 1'b0; c1_req = 1'b0;
    repeat (2) @(posedge clk);

    $display("SDRAM WRITE MUX2 PASS");
    $finish;
end
endmodule
