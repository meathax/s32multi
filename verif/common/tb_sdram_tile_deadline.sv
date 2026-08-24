//============================================================================
// Tile-fetch deadline priority and background-client fairness.
//
// The tile renderer has one scanline to fill its parity buffer.  A pending
// p1 burst therefore may wait for at most one already-earned background
// transaction, while repeated p1 bursts must still allow every other read
// client to advance.
//============================================================================
`timescale 1ns/1ps

module tb_sdram_tile_deadline;

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
reg [24:1] p0_addr = 24'h000020;
wire [63:0] p0_dout;
wire p0_ack;

reg p1_req = 1'b0;
reg [24:3] p1_addr = 22'h000008;
wire [63:0] p1_dout;
wire p1_ack;

reg p2_req = 1'b0;
reg [24:4] p2_addr = 21'h000008;
wire [127:0] p2_dout;
wire p2_ack;

reg p3_req = 1'b0;
reg [24:1] p3_addr = 24'h000060;
wire [15:0] p3_dout;
wire p3_ack;

reg p4_req = 1'b0;
reg [24:1] p4_addr = 24'h000080;
wire [15:0] p4_dout;
wire p4_ack;

reg p5_req = 1'b0;
reg [24:3] p5_addr = 22'h000028;
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

// Minimal CL2 SDRAM read source. Only completion timing matters here.
reg [1:0] read_valid_pipe = 2'b00;
reg [9:0] read_col_pipe [0:1];
wire read_cmd = ({SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} == 4'b0101);
always @(negedge clk) begin
    read_valid_pipe[1] <= read_valid_pipe[0];
    read_valid_pipe[0] <= read_cmd;
    read_col_pipe[1] <= read_col_pipe[0];
    read_col_pipe[0] <= SDRAM_A[9:0];
    mem_oe = read_valid_pipe[1];
    if (read_valid_pipe[1])
        mem_dq = 16'ha000 ^ {6'b0, read_col_pipe[1]};
end

wire [5:0] ack_vec = {p5_ack, p4_ack, p3_ack, p2_ack, p1_ack, p0_ack};

task automatic pulse_p1;
begin
    @(negedge clk); p1_req = 1'b1;
    @(negedge clk); p1_req = 1'b0;
end
endtask

task automatic pulse_all_reads;
begin
    @(negedge clk);
    p0_req = 1'b1; p1_req = 1'b1; p2_req = 1'b1;
    p3_req = 1'b1; p4_req = 1'b1; p5_req = 1'b1;
    @(negedge clk);
    p0_req = 1'b0; p1_req = 1'b0; p2_req = 1'b0;
    p3_req = 1'b0; p4_req = 1'b0; p5_req = 1'b0;
end
endtask

task automatic wait_all_ack_low;
integer timeout;
begin
    timeout = 0;
    while (ack_vec != 0 && timeout < 40) begin
        @(posedge clk); #1; timeout = timeout + 1;
    end
    if (ack_vec != 0)
        $fatal(1, "ack stretch did not clear");
end
endtask

// During the fairness phase, immediately chain another p1 request from each
// p1 ACK. This is more aggressive than the real tilemap, which performs pixel
// work between bursts, and therefore proves the background bound directly.
reg flood_p1 = 1'b0;
reg p1_ack_n = 1'b0;
always @(negedge clk) begin
    if (flood_p1) begin
        if (p1_ack && !p1_ack_n)
            p1_req <= 1'b1;
        else
            p1_req <= 1'b0;
    end
    p1_ack_n <= p1_ack;
end

integer timeout;
integer background_before_p1;
integer p1_between_background;
reg [5:0] previous_ack;
reg [5:0] rising_ack;
reg [5:0] seen;
reg [5:0] background_seen;

initial begin
    repeat (4) @(posedge clk);
    @(negedge clk); init = 1'b0;

    timeout = 0;
    while (!ready && timeout < 70000) begin
        @(posedge clk); #1; timeout = timeout + 1;
    end
    if (!ready)
        $fatal(1, "SDRAM initialization timed out");

    // Put the legacy round-robin pointer immediately after p1, then make all
    // ports pending together. A deadline-safe arbiter may honor one background
    // grant first for fairness, but p1 must be the next completed transaction.
    pulse_p1();
    timeout = 0;
    while (!p1_ack && timeout < 160) begin
        @(posedge clk); #1; timeout = timeout + 1;
    end
    if (!p1_ack)
        $fatal(1, "priming p1 burst timed out");
    wait_all_ack_low();

    pulse_all_reads();
    previous_ack = ack_vec;
    seen = 6'b000000;
    background_before_p1 = 0;
    timeout = 0;
    while (!seen[1] && timeout < 500) begin
        @(posedge clk); #1;
        rising_ack = ack_vec & ~previous_ack;
        previous_ack = ack_vec;
        seen = seen | rising_ack;
        if (rising_ack[0] || rising_ack[2] || rising_ack[3] ||
            rising_ack[4] || rising_ack[5])
            background_before_p1 = background_before_p1 + 1;
        timeout = timeout + 1;
    end
    if (!seen[1])
        $fatal(1, "tile p1 burst timed out under six-port contention");
    if (background_before_p1 > 1)
        $fatal(1, "tile deadline violated: %0d background grants completed before p1",
               background_before_p1);

    // Drain the one-shot requests before the sustained-p1 fairness phase.
    timeout = 0;
    while (seen != 6'b111111 && timeout < 500) begin
        @(posedge clk); #1;
        rising_ack = ack_vec & ~previous_ack;
        previous_ack = ack_vec;
        seen = seen | rising_ack;
        timeout = timeout + 1;
    end
    if (seen != 6'b111111)
        $fatal(1, "one-shot contention requests did not all complete: %b", seen);
    wait_all_ack_low();

    // Prime p1 again so the fairness credit starts consumed. Keep p1 flooded
    // while one request from every background client waits. Each background
    // client must finish, and no more than one p1 grant may separate them.
    pulse_p1();
    timeout = 0;
    while (!p1_ack && timeout < 160) begin
        @(posedge clk); #1; timeout = timeout + 1;
    end
    if (!p1_ack)
        $fatal(1, "fairness-prime p1 burst timed out");
    wait_all_ack_low();

    @(negedge clk);
    p0_req = 1'b1; p1_req = 1'b1; p2_req = 1'b1;
    p3_req = 1'b1; p4_req = 1'b1; p5_req = 1'b1;
    flood_p1 = 1'b1;
    @(negedge clk);
    p0_req = 1'b0; p1_req = 1'b0; p2_req = 1'b0;
    p3_req = 1'b0; p4_req = 1'b0; p5_req = 1'b0;

    previous_ack = ack_vec;
    background_seen = 6'b000000;
    p1_between_background = 0;
    timeout = 0;
    while ((background_seen & 6'b111101) != 6'b111101 && timeout < 900) begin
        @(posedge clk); #1;
        rising_ack = ack_vec & ~previous_ack;
        previous_ack = ack_vec;
        if (rising_ack[1])
            p1_between_background = p1_between_background + 1;
        if (rising_ack[0] || rising_ack[2] || rising_ack[3] ||
            rising_ack[4] || rising_ack[5]) begin
            if (p1_between_background > 1)
                $fatal(1, "background fairness violated: %0d consecutive p1 grants",
                       p1_between_background);
            p1_between_background = 0;
            background_seen = background_seen | rising_ack;
        end
        timeout = timeout + 1;
    end
    flood_p1 = 1'b0;
    @(negedge clk); p1_req = 1'b0;
    if ((background_seen & 6'b111101) != 6'b111101)
        $fatal(1, "background client starvation under sustained p1: %b",
               background_seen);

    $display("SDRAM TILE DEADLINE PASS");
    $finish;
end

endmodule
