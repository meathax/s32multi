`timescale 1ns/1ps

module tb_sdram;

reg clk = 1'b0;
always #5 clk = ~clk;

reg init = 1'b1;
wire ready;

tri [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0] SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH;
wire SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

reg [15:0] mem_dq = 16'h0000;
reg mem_oe = 1'b0;
assign SDRAM_DQ = mem_oe ? mem_dq : 16'hzzzz;

reg wr_req = 1'b0;
reg [24:1] wr_addr = '0;
reg [15:0] wr_din = '0;
reg [1:0] wr_be = 2'b11;
wire wr_ack;

reg p0_req = 1'b0;
reg [24:1] p0_addr = '0;
wire [63:0] p0_dout;
wire p0_ack;

reg p1_req = 1'b0;
reg [24:3] p1_addr = '0;
wire [63:0] p1_dout;
wire p1_ack;

reg p2_req = 1'b0;
reg [24:4] p2_addr = '0;
wire [127:0] p2_dout;
wire p2_ack;

reg p3_req = 1'b0;
reg [24:1] p3_addr = '0;
wire [15:0] p3_dout;
wire p3_ack;

reg p4_req = 1'b0;
reg [24:1] p4_addr = '0;
wire [15:0] p4_dout;
wire p4_ack;

reg p5_req = 1'b0;
reg [24:3] p5_addr = '0;
wire [63:0] p5_dout;
wire p5_ack;

sdram dut (
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din),
    .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_burst(1'b0), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

function automatic [15:0] word_for_col(input [9:0] col);
    word_for_col = 16'ha000 ^ {6'b0, col};
endfunction

// Compact CL2 SDRAM read model. The controller presents READ and column ahead
// of the forwarded +90-degree SDRAM edge. Model the returned word as stable
// before the controller's following posedge IOE sample.
reg [1:0] read_valid_pipe = 2'b00;
reg [9:0] read_col_pipe [0:1];
wire read_cmd = ({SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} == 4'b0101);

always @(negedge clk) begin
    read_valid_pipe[1] <= read_valid_pipe[0];
    read_valid_pipe[0] <= read_cmd;
    read_col_pipe[1] <= read_col_pipe[0];
    read_col_pipe[0] <= SDRAM_A[9:0];
    mem_oe = read_valid_pipe[1];
    if (read_valid_pipe[1]) mem_dq = word_for_col(read_col_pipe[1]);
end

task automatic wait_ack_p0(input [24:1] addr);
    integer timeout;
    reg [15:0] expected;
    begin
        expected = word_for_col(addr[10:1]);
        @(negedge clk); p0_addr = addr; p0_req = 1'b1;
        @(negedge clk); p0_req = 1'b0;
        timeout = 0;
        while (!p0_ack && timeout < 100) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        if (!p0_ack) $fatal(1, "p0 read timed out");
        if (p0_dout[15:0] !== expected)
            $fatal(1, "p0 stale/wrong word: got %h expected %h", p0_dout[15:0], expected);
        while (p0_ack) begin @(posedge clk); #1; end
    end
endtask

task automatic wait_ack_p1(input [24:3] addr);
    integer timeout;
    reg [9:0] col;
    reg [63:0] expected;
    begin
        col = {addr[8:3], 2'b00};
        expected = {word_for_col(col + 3), word_for_col(col + 2),
                    word_for_col(col + 1), word_for_col(col)};
        @(negedge clk); p1_addr = addr; p1_req = 1'b1;
        @(negedge clk); p1_req = 1'b0;
        timeout = 0;
        while (!p1_ack && timeout < 120) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        if (!p1_ack) $fatal(1, "p1 burst timed out");
        if (p1_dout !== expected)
            $fatal(1, "p1 burst order/data wrong: got %h expected %h", p1_dout, expected);
        while (p1_ack) begin @(posedge clk); #1; end
    end
endtask

task automatic wait_ack_p2(input [24:4] addr);
    integer timeout;
    reg [9:0] col;
    reg [127:0] expected;
    begin
        col = {addr[7:4], 3'b000};
        expected = {word_for_col(col + 7), word_for_col(col + 6),
                    word_for_col(col + 5), word_for_col(col + 4),
                    word_for_col(col + 3), word_for_col(col + 2),
                    word_for_col(col + 1), word_for_col(col)};
        @(negedge clk); p2_addr = addr; p2_req = 1'b1;
        @(negedge clk); p2_req = 1'b0;
        timeout = 0;
        while (!p2_ack && timeout < 160) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        if (!p2_ack) $fatal(1, "p2 burst timed out");
        if (p2_dout !== expected)
            $fatal(1, "p2 burst order/data wrong: got %h expected %h", p2_dout, expected);
        while (p2_ack) begin @(posedge clk); #1; end
    end
endtask

integer init_timeout;
integer delayed_timeout;
reg [15:0] delayed_expected;
reg [15:0] concurrent_p0_expected;
reg [63:0] delayed_p5_expected;
reg saw_concurrent_p0;
reg saw_concurrent_p5;
reg starve_p5_done;
reg p0_regap;
initial begin
    repeat (4) @(posedge clk);
    @(negedge clk); init = 1'b0;

    init_timeout = 0;
    while (!ready && init_timeout < 70000) begin
        @(posedge clk); #1; init_timeout = init_timeout + 1;
    end
    if (!ready) $fatal(1, "SDRAM initialization timed out");

    // Make the very first single-word read non-zero so stale cap_buf data is
    // guaranteed to fail, then cover both burst widths and lane ordering.
    wait_ack_p0(24'h000025);
    wait_ack_p1(22'h000009);
    wait_ack_p2(21'h000005);

    // A per-port mailbox must retain both the request and its metadata.  Hold
    // p4 behind an already-started p2 burst, pulse it for one clock, then
    // deliberately move the live p4 address before arbitration reaches it.
    delayed_expected = word_for_col(10'h055);
    @(negedge clk); p2_addr = 21'h000008; p2_req = 1'b1;
    @(negedge clk); p2_req = 1'b0;
                    p4_addr = 24'h000055; p4_req = 1'b1;
    @(negedge clk); p4_req = 1'b0; p4_addr = 24'h000199;
    delayed_timeout = 0;
    while (!p4_ack && delayed_timeout < 240) begin
        @(posedge clk); #1; delayed_timeout = delayed_timeout + 1;
    end
    if (!p4_ack) $fatal(1, "delayed p4 read timed out");
    if (p4_dout !== delayed_expected)
        $fatal(1, "p4 request metadata changed while pending: got %h expected %h",
               p4_dout, delayed_expected);
    while (p4_ack) begin @(posedge clk); #1; end

    // Hold the lowest-priority V25 line fill behind an in-flight sprite burst
    // and a later V60 read. Its one-cycle request and aligned line address must
    // survive both waits even after the live address bus changes.
    delayed_p5_expected = {
        word_for_col(10'h0a7), word_for_col(10'h0a6),
        word_for_col(10'h0a5), word_for_col(10'h0a4)
    };
    concurrent_p0_expected = word_for_col(10'h055);
    @(negedge clk); p2_addr = 21'h000010; p2_req = 1'b1;
    @(negedge clk); p2_req = 1'b0;
                    p5_addr = 22'h000029; p5_req = 1'b1;
    @(negedge clk); p5_req = 1'b0; p5_addr = 22'h00007c;
                    p0_addr = 24'h000055; p0_req = 1'b1;
    @(negedge clk); p0_req = 1'b0; p0_addr = 24'h000199;
    saw_concurrent_p0 = 1'b0;
    saw_concurrent_p5 = 1'b0;
    delayed_timeout = 0;
    while (!(saw_concurrent_p0 && saw_concurrent_p5) && delayed_timeout < 300) begin
        @(posedge clk); #1;
        delayed_timeout = delayed_timeout + 1;
        if (p0_ack) begin
            saw_concurrent_p0 = 1'b1;
            if (p0_dout[15:0] !== concurrent_p0_expected)
                $fatal(1, "concurrent p0 data wrong: got %h expected %h",
                       p0_dout[15:0], concurrent_p0_expected);
        end
        if (p5_ack) begin
            saw_concurrent_p5 = 1'b1;
            if (p5_dout !== delayed_p5_expected)
                $fatal(1, "p5 burst metadata/order wrong: got %h expected %h",
                       p5_dout, delayed_p5_expected);
        end
    end
    if (!saw_concurrent_p0) $fatal(1, "concurrent p0 read timed out");
    if (!saw_concurrent_p5) $fatal(1, "bounded p5 read timed out");

    // Continuous p0 demand must not starve a one-cycle low-priority p5 line
    // fill.  Under the rising-edge request contract a held level is serviced
    // exactly once, so sustained demand means RE-PULSING p0 off every ack —
    // the V60 icache fill chain pattern.  Require the p5 grant within a
    // small, implementation-independent transaction bound.
    @(negedge clk); p0_addr = 24'h000033; p0_req = 1'b1;
                    p5_addr = 22'h000012; p5_req = 1'b1;
    @(negedge clk); p5_req = 1'b0;
    delayed_timeout = 0;
    starve_p5_done = 1'b0;
    p0_regap = 1'b0;
    while (!starve_p5_done && delayed_timeout < 300) begin
        @(posedge clk); #1; delayed_timeout = delayed_timeout + 1;
        if (p5_ack) starve_p5_done = 1'b1;
        // one-cycle req gap after each p0 ack, then chain the next request
        if (p0_ack && p0_req) begin p0_req = 1'b0; p0_regap = 1'b1; end
        else if (p0_regap) begin
            p0_addr = p0_addr + 24'h2; p0_req = 1'b1; p0_regap = 1'b0;
        end
    end
    if (!starve_p5_done) $fatal(1, "round-robin starvation bound violated");
    @(negedge clk); p0_req = 1'b0;
    while (p0_ack || p5_ack) begin @(posedge clk); #1; end

    $display("SDRAM CAPTURE PASS");
    $finish;
end

endmodule
