// Directed ROM-download write-throughput regression.
// Same-row words must reuse the active SDRAM row; row changes must still
// precharge/activate explicitly and preserve every write.
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_write_throughput;
reg clk = 1'b0;
always #5 clk = ~clk;
reg init = 1'b1;
wire ready;
tri [15:0] dq;
wire [12:0] a;
wire [1:0] ba;
wire dqml, dqmh, ncs, ncas, nras, nwe, cke;
reg [15:0] dq_model = 16'h0000;
reg dq_oe = 1'b0;
assign dq = dq_oe ? dq_model : 16'hzzzz;
reg wr_req = 1'b0;
reg [24:1] wr_addr = '0;
reg [15:0] wr_din = '0;
reg [1:0] wr_be = 2'b11;
wire wr_ack;
wire p0_ack, p1_ack, p2_ack, p3_ack, p4_ack, p5_ack;
wire [15:0] p3_dout, p4_dout;
wire [63:0] p0_dout, p1_dout, p5_dout;
wire [127:0] p2_dout;
reg p0_req=0,p3_req=0,p4_req=0,p5_req=0,p1_req=0,p2_req=0;
reg [24:1] p0_addr=0,p3_addr=0,p4_addr=0;
reg [24:3] p1_addr=0,p5_addr=0;
reg [24:4] p2_addr=0;
wire [3:0] cmd = {ncs,nras,ncas,nwe};
localparam [3:0] C_ACT=4'b0011, C_PRE=4'b0010, C_WRITE=4'b0100;
integer acts=0, pres=0, writes=0, errors=0;
integer i, start_cycle, end_cycle, cyc=0, base_pre=0;
always @(posedge clk) begin
    cyc = cyc + 1;
    if (cmd == C_ACT) acts = acts + 1;
    if (cmd == C_PRE) pres = pres + 1;
    if (cmd == C_WRITE) writes = writes + 1;
end
always @(negedge clk) begin
    if (cmd == C_WRITE) begin
        if (writes < 16 && dq !== (16'hA000 + writes)) begin
            $display("FAIL same-row data word %0d got %h", writes, dq);
            errors = errors + 1;
        end
        if (writes == 16 && dq !== 16'hBEEF) begin
            $display("FAIL row-change data got %h", dq);
            errors = errors + 1;
        end
    end
end
sdram dut(
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba),
    .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs),
    .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nWE(nwe), .SDRAM_CKE(cke),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_burst(1'b0), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);
task automatic write_word(input [24:1] addr, input [15:0] data);
    integer guard;
    begin
        @(negedge clk);
        wr_addr = addr; wr_din = data; wr_req = 1'b1;
        @(negedge clk); wr_req = 1'b0;
        guard = 0;
        while (!wr_ack && guard < 100) begin @(posedge clk); guard = guard + 1; end
        if (!wr_ack) begin $display("FAIL write timeout addr=%h", addr); errors = errors + 1; end
        while (wr_ack && guard < 110) begin @(posedge clk); guard = guard + 1; end
    end
endtask
initial begin
    repeat (8) @(posedge clk);
    init = 1'b0;
    while (!ready) @(posedge clk);
    base_pre = pres;
    // One row, sequential words: exactly one ACT and no inter-word PRE.
    start_cycle = cyc;
    for (i = 0; i < 16; i = i + 1) write_word(24'h001000 + i, 16'hA000 + i);
    end_cycle = cyc;
    if (writes !== 16) begin $display("FAIL write count %0d", writes); errors = errors + 1; end
    if (acts !== 1) begin $display("FAIL same-row ACT count %0d", acts); errors = errors + 1; end
    if (pres !== base_pre) begin $display("FAIL same-row PRE count %0d (base %0d)", pres, base_pre); errors = errors + 1; end
    $display("ROWOPEN same-row cycles=%0d ACT=%0d PREdelta=%0d WRITE=%0d", end_cycle-start_cycle, acts, pres-base_pre, writes);
    // A different row must explicitly close/reopen, then continue safely.
    write_word(24'h002000, 16'hBEEF);
    if (acts !== 2 || pres !== base_pre + 1) begin
        $display("FAIL row-change ACT/PRE counts ACT=%0d PREdelta=%0d", acts, pres-base_pre);
        errors = errors + 1;
    end
    if (errors == 0) $display("SDRAM WRITE THROUGHPUT PASS");
    else $display("SDRAM WRITE THROUGHPUT FAIL (%0d errors)", errors);
    $finish;
end
initial begin #2000000; $display("SDRAM WRITE THROUGHPUT FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
