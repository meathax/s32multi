// Directed V60-ROM SDRAM transport regression.
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_p0_throughput;

reg clk = 1'b0;
always #5 clk = ~clk;
reg init = 1'b1;
wire ready;
tri [15:0] dq;
wire [12:0] a;
wire [1:0] ba;
wire dqml, dqmh, ncs, ncas, nras, nwe, cke;
reg [15:0] mem_dq = 16'h0000;
reg mem_oe = 1'b0;
assign dq = mem_oe ? mem_dq : 16'hzzzz;

reg wr_req=0; reg [24:1] wr_addr=0; reg [15:0] wr_din=0; reg [1:0] wr_be=0; wire wr_ack;
reg p0_req=0; reg p0_burst=0; reg [24:1] p0_addr=0; wire [63:0] p0_dout; wire p0_ack;
reg p1_req=0; reg [24:3] p1_addr=0; wire [63:0] p1_dout; wire p1_ack;
reg p2_req=0; reg [24:4] p2_addr=0; wire [127:0] p2_dout; wire p2_ack;
reg p3_req=0; reg [24:1] p3_addr=0; wire [15:0] p3_dout; wire p3_ack;
reg p4_req=0; reg [24:1] p4_addr=0; wire [15:0] p4_dout; wire p4_ack;
reg p5_req=0; reg [24:3] p5_addr=0; wire [63:0] p5_dout; wire p5_ack;

sdram dut (
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba),
    .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs),
    .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nWE(nwe), .SDRAM_CKE(cke),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_burst(p0_burst), .p0_addr(p0_addr),
    .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

function automatic [15:0] word_for_col(input [9:0] col);
    word_for_col = 16'ha000 ^ {6'b0, col};
endfunction

reg [1:0] read_valid_pipe = 2'b00;
reg [9:0] read_col_pipe [0:1];
wire [3:0] cmd = {ncs,nras,ncas,nwe};
wire read_cmd = cmd == 4'b0101;
integer cycles=0, acts=0, reads=0, errors=0;
always @(posedge clk) begin
    cycles = cycles + 1;
    if (cmd == 4'b0011) acts = acts + 1;
    if (read_cmd) reads = reads + 1;
end
always @(negedge clk) begin
    read_valid_pipe[1] <= read_valid_pipe[0];
    read_valid_pipe[0] <= read_cmd;
    read_col_pipe[1] <= read_col_pipe[0];
    read_col_pipe[0] <= a[9:0];
    mem_oe = read_valid_pipe[1];
    if (read_valid_pipe[1]) mem_dq = word_for_col(read_col_pipe[1]);
end

task automatic read_word(input [24:1] addr);
integer guard;
begin
    @(negedge clk); p0_addr=addr; p0_burst=1'b0; p0_req=1'b1;
    @(negedge clk); p0_req=1'b0;
    guard=0;
    while (!p0_ack && guard < 100) begin @(posedge clk); #1; guard=guard+1; end
    if (!p0_ack) begin $display("FAIL p0 timeout"); errors=errors+1; end
    else if (p0_dout[15:0] !== word_for_col(addr[10:1])) begin
        $display("FAIL p0 data %h expected %h", p0_dout[15:0], word_for_col(addr[10:1]));
        errors=errors+1;
    end
    else if (p0_dout[63:16] !== 48'd0) begin
        $display("FAIL exact p0 word returned nonzero upper lanes %012h", p0_dout[63:16]);
        errors=errors+1;
    end
    while (p0_ack) begin @(posedge clk); #1; end
end
endtask

task automatic read_line_behind_p2(input [24:1] addr);
integer guard;
reg [9:0] col;
reg [63:0] expected;
begin
    col = {addr[10:3], 2'b00};
    expected = {word_for_col(col+3), word_for_col(col+2),
                word_for_col(col+1), word_for_col(col)};
    // rr_next is 1 after the preceding p0 transaction, so simultaneous p2
    // and p0 requests service p2 first.  Change both live p0 metadata fields
    // immediately after the request edge; the delayed p0 transaction must use
    // the address and burst mode captured in its mailbox.
    @(negedge clk);
    p2_addr=21'h00080; p2_req=1'b1;
    p0_addr=addr; p0_burst=1'b1; p0_req=1'b1;
    @(negedge clk);
    p2_req=1'b0; p0_req=1'b0;
    p0_addr=24'h000055; p0_burst=1'b0;
    guard=0;
    while (!p2_ack && !p0_ack && guard < 160) begin
        @(posedge clk); #1; guard=guard+1;
    end
    if (p0_ack) begin
        $display("FAIL p0 bypassed earlier round-robin p2 contention");
        errors=errors+1;
    end
    if (!p2_ack) begin
        $display("FAIL p2 contention transaction timed out");
        errors=errors+1;
    end
    guard=0;
    while (!p0_ack && guard < 160) begin @(posedge clk); #1; guard=guard+1; end
    if (!p0_ack) begin
        $display("FAIL delayed p0 line timeout"); errors=errors+1;
    end
    else if (p0_dout !== expected) begin
        $display("FAIL delayed p0 mailbox line %h expected %h", p0_dout, expected);
        errors=errors+1;
    end
    while (p0_ack) begin @(posedge clk); #1; end
end
endtask

task automatic read_line(input [24:1] addr);
integer guard;
reg [9:0] col;
reg [63:0] expected;
begin
    col = {addr[10:3], 2'b00};
    expected = {word_for_col(col+3), word_for_col(col+2),
                word_for_col(col+1), word_for_col(col)};
    @(negedge clk); p0_addr=addr; p0_burst=1'b1; p0_req=1'b1;
    @(negedge clk); p0_req=1'b0; p0_burst=1'b0;
    guard=0;
    while (!p0_ack && guard < 100) begin @(posedge clk); #1; guard=guard+1; end
    if (!p0_ack) begin $display("FAIL p0 line timeout"); errors=errors+1; end
    else if (p0_dout !== expected) begin
        $display("FAIL p0 line %h expected %h", p0_dout, expected);
        errors=errors+1;
    end
    while (p0_ack) begin @(posedge clk); #1; end
end
endtask

integer i, start_cycles, start_acts, start_reads;
integer word_cycles, line_cycles;
initial begin
    repeat (4) @(posedge clk);
    @(negedge clk); init=1'b0;
    while (!ready) @(posedge clk);
    start_cycles=cycles; start_acts=acts; start_reads=reads;
    for (i=0; i<4; i=i+1) read_word(24'h001000+i);
    word_cycles=cycles-start_cycles;
    $display("P0 WORDS cycles=%0d ACT=%0d READ=%0d",
             word_cycles, acts-start_acts, reads-start_reads);
    start_cycles=cycles; start_acts=acts; start_reads=reads;
    read_line(24'h001003); // controller must align the cache-line request
    line_cycles=cycles-start_cycles;
    $display("P0 LINE cycles=%0d ACT=%0d READ=%0d speedup_x100=%0d",
             line_cycles, acts-start_acts, reads-start_reads,
             (word_cycles*100)/line_cycles);
    if ((reads-start_reads) != 4) begin
        $display("FAIL p0 line did not issue four CAS beats"); errors=errors+1;
    end
    if (line_cycles * 2 >= word_cycles) begin
        $display("FAIL p0 line transport less than 2x faster"); errors=errors+1;
    end
    read_line_behind_p2(24'h001123);
    $display("P0 MAILBOX contention=p2 burst_metadata=preserved");
    if (errors == 0) $display("SDRAM P0 THROUGHPUT PASS");
    else $display("SDRAM P0 THROUGHPUT FAIL (%0d errors)", errors);
    $finish;
end
initial begin #2000000; $display("SDRAM P0 THROUGHPUT FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
