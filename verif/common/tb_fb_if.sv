//============================================================================
//  Directed test: s32_fb_if (sprite framebuffer DDR interface)
//  1. held erase request -> exactly one 128-word erase, all 0xFFFF
//  2. pixel run with partial head/tail words -> only touched pixels change
//     (byte-enable mask; untouched neighbours keep 0xFFFF)
//  3. shadow run -> dest &= 0x7fff ONLY on the run's pixels (V-10 RMW)
//  4. line read-back through the rd port matches DDR contents
//  5. display read wins over a simultaneous deferred sprite flush, and the
//     sprite write remains queued and completes afterward
//     complete line, retaining shadow pixels as authoritative
//  7. fetching the next line never overwrites the line still being scanned;
//     the completed replacement becomes visible only at a raster boundary
//
//  The DDR model applies deterministic pseudo-random backpressure and
//  variable read-response latency/bubbles.  Writes are deliberately modelled
//  as single-beat transactions: every asserted write must advertise
//  burstcount=1, and all request signals must remain stable while stalled.
//============================================================================
`timescale 1ns/1ps

module tb_fb_if;

reg clk = 0, rst = 1;
always #5 clk = ~clk;

// DUT wires
reg         wr_start = 0, wr_valid = 0, wr_end = 0, wr_shadow = 0;
reg  [1:0]  wr_buf = 0;
reg  [8:0]  wr_x = 0;
reg  [7:0]  wr_y = 0;
reg  [15:0] wr_pix = 0;
wire        wr_busy;
wire        wr_can_start;
reg         er_req = 0;
reg  [1:0]  er_buf = 0;
reg  [7:0]  er_y = 0;
wire        er_ack;
reg         rd_req = 0;
reg  [1:0]  rd_buf = 0;
reg  [7:0]  rd_y = 0;
wire        rd_ack;
reg  [8:0]  rd_x = 0;
wire [15:0] rd_pix;
reg         rd2_req = 0;
reg  [1:0]  rd2_buf = 0;
reg  [7:0]  rd2_y = 0;
wire        rd2_ack;
wire [15:0] rd2_pix;

// DDR behavioral model (64MB window as 64-bit words)
wire        DD_BUSY;
wire [7:0]  DD_BURST;
wire [28:0] DD_ADDR;
reg  [63:0] DD_DOUT = 0;
reg         DD_READY = 0;
wire        DD_RD, DD_WE;
wire [63:0] DD_DIN;
wire [7:0]  DD_BE;

s32_fb_if #(.FB_BASE(32'h3000_0000)) dut (
    .clk(clk), .rst(rst),
    .DDRAM_BUSY(DD_BUSY), .DDRAM_BURSTCNT(DD_BURST), .DDRAM_ADDR(DD_ADDR),
    .DDRAM_DOUT(DD_DOUT), .DDRAM_DOUT_READY(DD_READY), .DDRAM_RD(DD_RD),
    .DDRAM_DIN(DD_DIN), .DDRAM_BE(DD_BE), .DDRAM_WE(DD_WE),
    .wr_start(wr_start), .wr_buf(wr_buf), .wr_x(wr_x), .wr_y(wr_y),
    .wr_valid(wr_valid), .wr_pix(wr_pix), .wr_end(wr_end),
    .wr_shadow(wr_shadow), .wr_busy(wr_busy),
    .wr_can_start(wr_can_start),
    .er_req(er_req), .er_buf(er_buf), .er_y(er_y), .er_ack(er_ack),
    .rd_req(rd_req), .rd_buf(rd_buf), .rd_y(rd_y), .rd_ack(rd_ack),
    .rd_x(rd_x), .rd_pix(rd_pix),
    .rd2_req(rd2_req), .rd2_buf(rd2_buf), .rd2_y(rd2_y),
    .rd2_ack(rd2_ack), .rd2_pix(rd2_pix)
);

// DDR memory + burst engine
reg [63:0] ddr [0:131071];   // 1MB window (offset from FB_BASE>>3)
integer di;
initial for (di = 0; di < 131072; di = di + 1) ddr[di] = 64'h0;

wire [16:0] locaddr = DD_ADDR[16:0];  // FB_BASE>>3 = 0x6000000; low bits index
integer errors = 0;
integer write_accepts = 0;
integer read_accepts = 0;
integer model_cycle = 0;

// Reproducible backpressure.  The periodic term guarantees regular stalls;
// the LFSR term varies their placement without making the test non-deterministic.
reg       dd_busy = 0;
reg [7:0] busy_lfsr = 8'hA5;
assign DD_BUSY = dd_busy;
always @(posedge clk) begin
    if (rst) begin
        dd_busy   <= 0;
        busy_lfsr <= 8'hA5;
        model_cycle <= 0;
    end
    else begin
        model_cycle <= model_cycle + 1;
        busy_lfsr <= {busy_lfsr[6:0],
                      busy_lfsr[7] ^ busy_lfsr[5] ^ busy_lfsr[4] ^ busy_lfsr[3]};
        dd_busy <= ((model_cycle % 13) == 4) ||
                   (busy_lfsr[0] && busy_lfsr[3]);
    end
end

// Check that a request held off by DDRAM_BUSY is genuinely held.  Sampling on
// the falling edge observes the DUT's settled, post-NBA outputs.
reg        stall_seen = 0;
reg        stall_rd, stall_we;
reg [28:0] stall_addr;
reg  [7:0] stall_burst, stall_be;
reg [63:0] stall_din;
integer    stalled_request_cycles = 0;
always @(negedge clk) begin
    if (rst || !DD_BUSY) begin
        stall_seen = 0;
    end
    else if (stall_seen) begin
        stalled_request_cycles = stalled_request_cycles + 1;
        if ({DD_RD, DD_WE, DD_ADDR, DD_BURST} !==
            {stall_rd, stall_we, stall_addr, stall_burst}) begin
            errors = errors + 1;
            $display("  FAIL DDR request changed while BUSY");
        end
        if (stall_we && {DD_DIN, DD_BE} !== {stall_din, stall_be}) begin
            errors = errors + 1;
            $display("  FAIL DDR write data/BE changed while BUSY");
        end
    end
    else if (DD_RD || DD_WE) begin
        stall_seen  = 1;
        stall_rd    = DD_RD;
        stall_we    = DD_WE;
        stall_addr  = DD_ADDR;
        stall_burst = DD_BURST;
        stall_din   = DD_DIN;
        stall_be    = DD_BE;
        stalled_request_cycles = stalled_request_cycles + 1;
    end
end

reg [16:0] rd_a = 0;
reg  [7:0] rd_n = 0;
reg  [3:0] rd_delay = 0;
always @(posedge clk) begin
    DD_READY <= 0;
    if (rst) begin
        rd_a <= 0;
        rd_n <= 0;
        rd_delay <= 0;
    end
    else begin
        if (DD_WE && !DD_BUSY) begin
            write_accepts = write_accepts + 1;
            if (DD_BURST !== 8'd1) begin
                errors = errors + 1;
                $display("  FAIL write burstcount=%0d, expected 1 (addr=%08x)",
                         DD_BURST, DD_ADDR);
            end
            if (DD_BE[0]) ddr[locaddr][ 7: 0] <= DD_DIN[ 7: 0];
            if (DD_BE[1]) ddr[locaddr][15: 8] <= DD_DIN[15: 8];
            if (DD_BE[2]) ddr[locaddr][23:16] <= DD_DIN[23:16];
            if (DD_BE[3]) ddr[locaddr][31:24] <= DD_DIN[31:24];
            if (DD_BE[4]) ddr[locaddr][39:32] <= DD_DIN[39:32];
            if (DD_BE[5]) ddr[locaddr][47:40] <= DD_DIN[47:40];
            if (DD_BE[6]) ddr[locaddr][55:48] <= DD_DIN[55:48];
            if (DD_BE[7]) ddr[locaddr][63:56] <= DD_DIN[63:56];
        end
        if (DD_RD && !DD_BUSY) begin
            read_accepts = read_accepts + 1;
            if (rd_n != 0) begin
                errors = errors + 1;
                $display("  FAIL overlapping DDR read request");
            end
            else begin
                rd_a <= locaddr;
                rd_n <= DD_BURST;
                // Each burst starts after 2..5 cycles, based on a free-running
                // phase so shadow reads and line reads exercise different gaps.
                rd_delay <= 4'd2 + model_cycle[1:0];
            end
        end
        else if (rd_n != 0) begin
            if (rd_delay != 0) begin
                rd_delay <= rd_delay - 1'd1;
            end
            else if (model_cycle[2:0] != 3'b101) begin
                // Intentional bubbles occur whenever the low phase is 3'b101.
                DD_DOUT  <= ddr[rd_a];
                DD_READY <= 1;
                rd_a <= rd_a + 1'd1;
                rd_n <= rd_n - 1'd1;
            end
        end
    end
end

// helper: pixel from ddr (buf 0, y, x); line stride 512 px
function [15:0] ddr_pix(input [7:0] y, input [8:0] x);
    logic [16:0] w;
    w = ({2'b00, y} * 512 + x) >> 2;
    ddr_pix = ddr[w] >> {x[1:0], 4'b0000};
endfunction

task check(input [15:0] got, input [15:0] want, input [8:0] x);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL x=%0d got=%04x want=%04x", x, got, want);
    end
endtask

// all DUT inputs are driven with nonblocking assigns so they change after
// the clock edge, like real registered outputs (avoids TB/DUT races)
integer i;
integer erase_write_start;
integer line_read_start;
integer arb_read_start;
integer arb_write_start;
integer stable_read_start;
integer sparse_write_start;
integer sparse_shadow_read_start;
integer sparse_shadow_write_start;
initial begin
    repeat (5) @(posedge clk);
    rst <= 0;
    repeat (2) @(posedge clk);

    // 1: erase line 5.  Keep er_req asserted well past er_ack: a level-held
    // request is one transaction and must not start a second erase.
    erase_write_start = write_accepts;
    er_y <= 8'd5; er_req <= 1;
    @(posedge er_ack);
    repeat (48) @(posedge clk);
    er_req <= 0;
    wait (!er_ack);
    repeat (4) @(posedge clk);
    if ((write_accepts - erase_write_start) != 128) begin
        errors = errors + 1;
        $display("  FAIL held erase accepted %0d writes, expected exactly 128",
                 write_accepts - erase_write_start);
    end
    for (i = 0; i < 512; i = i + 1)
        check(ddr_pix(5, i[8:0]), 16'hFFFF, i[8:0]);

    // 2: run x=3..9, pix = 0x8000|x -> head word px3 only, tail word px8,9
    @(posedge clk); wr_start <= 1; wr_y <= 8'd5; wr_buf <= 0; wr_shadow <= 0;
    @(posedge clk); wr_start <= 0;
    for (i = 3; i <= 9; i = i + 1) begin
        wr_valid <= 1; wr_x <= i[8:0]; wr_pix <= 16'h8000 | i[15:0];
        @(posedge clk);
    end
    wr_valid <= 0; wr_end <= 1; @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait (!wr_busy); repeat (4) @(posedge clk);
    check(ddr_pix(5, 2), 16'hFFFF, 2);       // head partial word untouched
    for (i = 3; i <= 9; i = i + 1) check(ddr_pix(5, i[8:0]), 16'h8000 | i[15:0], i[8:0]);
    check(ddr_pix(5, 10), 16'hFFFF, 10);     // tail partial word untouched
    check(ddr_pix(5, 11), 16'hFFFF, 11);

    // 2b: reversed-order run with a gap (flipped sprite + clip-out hole):
    // pixels at x=20,18,17 written right-to-left; x=19 untouched
    @(posedge clk); wr_start <= 1; wr_y <= 8'd5;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd20; wr_pix <= 16'h9020; @(posedge clk);
    wr_valid <= 1; wr_x <= 9'd18; wr_pix <= 16'h9018; @(posedge clk);
    wr_valid <= 1; wr_x <= 9'd17; wr_pix <= 16'h9017; @(posedge clk);
    wr_valid <= 0; wr_end <= 1; @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait (!wr_busy); repeat (4) @(posedge clk);
    check(ddr_pix(5, 16), 16'hFFFF, 16);
    check(ddr_pix(5, 17), 16'h9017, 17);
    check(ddr_pix(5, 18), 16'h9018, 18);
    check(ddr_pix(5, 19), 16'hFFFF, 19);     // the gap stays erased
    check(ddr_pix(5, 20), 16'h9020, 20);
    check(ddr_pix(5, 21), 16'hFFFF, 21);

    // 2c: empty run (fully transparent row) -> flush is a no-op
    @(posedge clk); wr_start <= 1; wr_y <= 8'd5;
    @(posedge clk); wr_start <= 0;
    wr_end <= 1; @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait (!wr_busy); repeat (4) @(posedge clk);
    check(ddr_pix(5, 0), 16'hFFFF, 0);
    check(ddr_pix(5, 3), 16'h8003, 3);       // earlier data intact

    // 2d: two populated qwords separated by a whole-line transparent hole.
    // Empty qwords must be skipped locally instead of issuing zero-BE writes.
    sparse_write_start = write_accepts;
    @(posedge clk); wr_start <= 1; wr_y <= 8'd5; wr_buf <= 0; wr_shadow <= 0;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd0;   wr_pix <= 16'h9234; @(posedge clk);
    wr_valid <= 1; wr_x <= 9'd511; wr_pix <= 16'h9567; @(posedge clk);
    wr_valid <= 0; wr_end <= 1; @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait (!wr_busy);
    repeat (4) @(posedge clk);
    if ((write_accepts - sparse_write_start) != 2) begin
        errors = errors + 1;
        $display("  FAIL sparse run accepted %0d writes, expected 2",
                 write_accepts - sparse_write_start);
    end
    check(ddr_pix(5, 0),   16'h9234, 0);
    check(ddr_pix(5, 256), 16'hFFFF, 256);
    check(ddr_pix(5, 511), 16'h9567, 511);

    // 3: shadow run x=5..6 -> those two lose bit15, neighbours keep it
    @(posedge clk); wr_start <= 1; wr_shadow <= 1;
    @(posedge clk); wr_start <= 0;
    for (i = 5; i <= 6; i = i + 1) begin
        wr_valid <= 1; wr_x <= i[8:0]; wr_pix <= 16'hDEAD;  // value ignored
        @(posedge clk);
    end
    wr_valid <= 0; wr_end <= 1; @(posedge clk); wr_end <= 0; wr_shadow <= 0;
    @(posedge clk);
    wait (!wr_busy); repeat (4) @(posedge clk);
    check(ddr_pix(5, 4), 16'h8004, 4);
    check(ddr_pix(5, 5), 16'h0005, 5);       // bit15 cleared, pen kept
    check(ddr_pix(5, 6), 16'h0006, 6);
    check(ddr_pix(5, 7), 16'h8007, 7);

    // 3b: sparse shadow spans preserve the exact RMW result while avoiding
    // reads and zero-BE writes for words containing no shadow pixels.
    sparse_shadow_read_start = read_accepts;
    sparse_shadow_write_start = write_accepts;
    @(posedge clk); wr_start <= 1; wr_shadow <= 1;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd0;   wr_pix <= 16'hDEAD; @(posedge clk);
    wr_valid <= 1; wr_x <= 9'd511; wr_pix <= 16'hDEAD; @(posedge clk);
    wr_valid <= 0; wr_end <= 1; @(posedge clk); wr_end <= 0; wr_shadow <= 0;
    @(posedge clk);
    wait (!wr_busy);
    repeat (4) @(posedge clk);
    if ((read_accepts - sparse_shadow_read_start) != 2 ||
        (write_accepts - sparse_shadow_write_start) != 2) begin
        errors = errors + 1;
        $display("  FAIL sparse shadow accepted %0d reads/%0d writes, expected 2/2",
                 read_accepts - sparse_shadow_read_start,
                 write_accepts - sparse_shadow_write_start);
    end
    check(ddr_pix(5, 0),   16'h1234, 0);
    check(ddr_pix(5, 256), 16'hFFFF, 256);
    check(ddr_pix(5, 511), 16'h1567, 511);

    // 4: read line back through rd port.  Hold rd_req across ack as a second
    // check of the request/ack level protocol.
    line_read_start = read_accepts;
    rd_y <= 8'd5; rd_buf <= 0; rd_req <= 1;
    @(posedge rd_ack); repeat (4) @(posedge clk); rd_req <= 0;
    wait (!rd_ack); repeat (2) @(posedge clk);
    if ((read_accepts - line_read_start) != 1) begin
        errors = errors + 1;
        $display("  FAIL held line-read accepted %0d requests, expected exactly 1",
                 read_accepts - line_read_start);
    end
    rd_x = 9'd3;  @(posedge clk); #1; check(rd_pix, 16'h8003, 3);
    rd_x = 9'd5;  @(posedge clk); #1; check(rd_pix, 16'h0005, 5);
    rd_x = 9'd9;  @(posedge clk); #1; check(rd_pix, 16'h8009, 9);
    rd_x = 9'd10; @(posedge clk); #1; check(rd_pix, 16'hFFFF, 10);

    // 5: present a completed sprite run and a display-line request together.
    // Scanout must launch first, but deferring the run must not drop it.
    arb_read_start  = read_accepts;
    arb_write_start = write_accepts;
    @(posedge clk); wr_start <= 1; wr_y <= 8'd6; wr_buf <= 0; wr_shadow <= 0;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd30; wr_pix <= 16'hABCD; @(posedge clk);
    wr_valid <= 0; wr_end <= 1;
    rd_y <= 8'd5; rd_buf <= 0; rd_req <= 1;
    @(posedge clk); wr_end <= 0;

    wait (read_accepts > arb_read_start);
    if (write_accepts != arb_write_start) begin
        errors = errors + 1;
        $display("  FAIL sprite flush reached DDR before display read");
    end
    @(posedge rd_ack); rd_req <= 0;
    wait (!rd_ack);
    rd_x = 9'd0; @(posedge clk);
    rd_x = 9'd3; @(posedge clk); #1; check(rd_pix, 16'h8003, 3);
    wait (!wr_busy); repeat (4) @(posedge clk);
    if ((write_accepts - arb_write_start) != 1) begin
        errors = errors + 1;
        $display("  FAIL deferred sprite flush accepted %0d writes, expected 1",
                 write_accepts - arb_write_start);
    end
    check(ddr_pix(6, 30), 16'hABCD, 30);

    // 7: keep line 8 displayed while line 9 is fetched. The next-line DDR
    // burst completes while rd_x remains in the middle of the current raster;
    // scanout must still see line 8 until rd_x=0 publishes the completed bank.
    // A single shared line RAM fails this by exposing line 9 immediately.
    for (i = 0; i < 128; i = i + 1) begin
        ddr[8 * 128 + i] = 64'h8a08_8a08_8a08_8a08;
        ddr[9 * 128 + i] = 64'h9b09_9b09_9b09_9b09;
    end

    rd_x <= 9'd0;
    rd_y <= 8'd8; rd_buf <= 2'd0; rd_req <= 1'b1;
    @(posedge rd_ack); rd_req <= 1'b0;
    wait (!rd_ack); repeat (2) @(posedge clk);
    rd_x <= 9'd200; @(posedge clk); #1;
    check(rd_pix, 16'h8a08, 200);

    stable_read_start = read_accepts;
    rd_y <= 8'd9; rd_req <= 1'b1;
    @(posedge rd_ack); rd_req <= 1'b0;
    wait (!rd_ack); repeat (2) @(posedge clk);
    if ((read_accepts - stable_read_start) != 1) begin
        errors = errors + 1;
        $display("  FAIL stable-line read accepted %0d bursts, expected 1",
                 read_accepts - stable_read_start);
    end
    check(rd_pix, 16'h8a08, 200);

    rd_x <= 9'd0; @(posedge clk);
    rd_x <= 9'd200; @(posedge clk); #1;
    check(rd_pix, 16'h9b09, 200);

    if (stalled_request_cycles == 0) begin
        errors = errors + 1;
        $display("  FAIL DDR backpressure was not exercised");
    end

    if (errors == 0) $display("FB IF PASS");
    else             $display("FB IF FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #400000;
    $display("FB IF FAIL (timeout)");
    $finish;
end

endmodule
