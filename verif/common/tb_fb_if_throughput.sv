//============================================================================
// Focused throughput regression for the System 32 DDR sprite framebuffer.
//
// Each case starts from the same deterministic DDR backpressure phase.  The
// reported cycle counts cover the service interval (not renderer pixel input),
// while transaction counts expose useless zero-byte-enable traffic directly.
//============================================================================
`timescale 1ns/1ps

module tb_fb_if_throughput;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

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
    .DDRAM_BUSY(DD_BUSY), .DDRAM_BURSTCNT(DD_BURST),
    .DDRAM_ADDR(DD_ADDR), .DDRAM_DOUT(DD_DOUT),
    .DDRAM_DOUT_READY(DD_READY), .DDRAM_RD(DD_RD),
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

reg [63:0] ddr [0:131071];
integer di;
initial for (di = 0; di < 131072; di = di + 1) ddr[di] = 64'd0;

wire [16:0] locaddr = DD_ADDR[16:0];
integer model_cycle = 0;
integer write_accepts = 0;
integer zero_be_accepts = 0;
integer read_accepts = 0;
integer read_beats = 0;
integer stalled_request_cycles = 0;
integer errors = 0;

// Regular and irregular stalls make both isolated and consecutive requests
// prove their hold behavior without tying the result to a random seed.
assign DD_BUSY = !rst && (((model_cycle % 7) == 2) ||
                          ((model_cycle % 11) == 5));

reg        stall_seen = 0;
reg        stall_rd, stall_we;
reg [28:0] stall_addr;
reg  [7:0] stall_burst, stall_be;
reg [63:0] stall_din;
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
            $display("  FAIL DDR write payload changed while BUSY");
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

reg [16:0] rd_addr_model = 0;
reg  [7:0] rd_left = 0;
reg  [2:0] rd_delay = 0;
always @(posedge clk) begin
    DD_READY <= 1'b0;
    if (rst) begin
        model_cycle <= 0;
        write_accepts <= 0;
        zero_be_accepts <= 0;
        read_accepts <= 0;
        read_beats <= 0;
        stalled_request_cycles <= 0;
        rd_addr_model <= 0;
        rd_left <= 0;
        rd_delay <= 0;
    end
    else begin
        model_cycle <= model_cycle + 1;
        if (DD_WE && !DD_BUSY) begin
            write_accepts <= write_accepts + 1;
            if (DD_BE == 8'h00)
                zero_be_accepts <= zero_be_accepts + 1;
            if (DD_BURST !== 8'd1) begin
                errors = errors + 1;
                $display("  FAIL write burstcount=%0d", DD_BURST);
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
            read_accepts <= read_accepts + 1;
            if (rd_left != 0) begin
                errors = errors + 1;
                $display("  FAIL overlapping DDR read request");
            end
            else begin
                rd_addr_model <= locaddr;
                rd_left <= DD_BURST;
                rd_delay <= 3;
            end
        end
        else if (rd_left != 0) begin
            if (rd_delay != 0) begin
                rd_delay <= rd_delay - 1'd1;
            end
            else if ((model_cycle % 5) != 1) begin
                DD_DOUT <= ddr[rd_addr_model];
                DD_READY <= 1'b1;
                rd_addr_model <= rd_addr_model + 1'd1;
                rd_left <= rd_left - 1'd1;
                read_beats <= read_beats + 1;
            end
        end
    end
end

function [16:0] word_index(input [1:0] buf_i, input [7:0] y,
                           input [6:0] x_word);
    word_index = {buf_i, 15'b0} + ({9'b0, y} << 7) + x_word;
endfunction

function [15:0] ddr_pix(input [1:0] buf_i, input [7:0] y,
                        input [8:0] x);
    ddr_pix = ddr[word_index(buf_i, y, x[8:2])] >> {x[1:0], 4'b0000};
endfunction

task reset_case;
    begin
        wr_start <= 0; wr_valid <= 0; wr_end <= 0; wr_shadow <= 0;
        er_req <= 0; rd_req <= 0; rd_x <= 0;
        rst <= 1;
        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (3) @(posedge clk);
    end
endtask

task check_pixel(input [1:0] buf_i, input [7:0] y, input [8:0] x,
                 input [15:0] want);
    reg [15:0] got;
    begin
        got = ddr_pix(buf_i, y, x);
        if (got !== want) begin
            errors = errors + 1;
            $display("  FAIL buf=%0d y=%0d x=%0d got=%04x want=%04x",
                     buf_i, y, x, got, want);
        end
    end
endtask

integer i;
integer start_cycle;
integer op_cycles;
integer op_writes;
integer op_zero_be;
integer op_reads;
integer op_beats;
initial begin
    // Full-line erase: 128 legal pipelined single writes.
    reset_case();
    start_cycle = model_cycle;
    er_buf <= 0; er_y <= 8'd10; er_req <= 1;
    @(posedge er_ack);
    op_cycles = model_cycle - start_cycle;
    er_req <= 0; wait (!er_ack);
    $display("FB PERF erase cycles=%0d writes=%0d stalls=%0d",
             op_cycles, write_accepts, stalled_request_cycles);
    if (write_accepts != 128) begin
        errors = errors + 1;
        $display("  FAIL erase writes=%0d want=128", write_accepts);
    end
    check_pixel(0, 8'd10, 9'd0, 16'hffff);
    check_pixel(0, 8'd10, 9'd511, 16'hffff);

    // Dense 512-pixel run: the combining RAM must sustain one accepted DDR
    // word per available clock after its single prefetch cycle.
    reset_case();
    for (i = 0; i < 128; i = i + 1)
        ddr[word_index(0, 8'd11, i[6:0])] = 64'hffff_ffff_ffff_ffff;
    @(posedge clk); wr_start <= 1; wr_buf <= 0; wr_y <= 8'd11;
    @(posedge clk); wr_start <= 0;
    for (i = 0; i < 512; i = i + 1) begin
        wr_valid <= 1; wr_x <= i[8:0]; wr_pix <= 16'h8000 | i[15:0];
        @(posedge clk);
    end
    wr_valid <= 0; wr_end <= 1;
    start_cycle = model_cycle;
    @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait ((dut.dst == 0) && !dut.flush_req && !wr_end);
    op_cycles = model_cycle - start_cycle;
    $display("FB PERF dense_flush cycles=%0d writes=%0d zero_be=%0d stalls=%0d",
             op_cycles, write_accepts, zero_be_accepts,
             stalled_request_cycles);
    if ((write_accepts != 128) || (zero_be_accepts != 0)) begin
        errors = errors + 1;
        $display("  FAIL dense writes=%0d zero_be=%0d want=128/0",
                 write_accepts, zero_be_accepts);
    end
    check_pixel(0, 8'd11, 9'd0, 16'h8000);
    check_pixel(0, 8'd11, 9'd511, 16'h81ff);

    // Sparse normal run spanning the line. Empty qwords are legal no-ops but
    // consume DDR acceptance slots; the metric makes them visible.
    reset_case();
    for (i = 0; i < 128; i = i + 1)
        ddr[word_index(0, 8'd12, i[6:0])] = 64'h1111_2222_3333_4444;
    @(posedge clk); wr_start <= 1; wr_buf <= 0; wr_y <= 8'd12;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd0; wr_pix <= 16'ha000; @(posedge clk);
    wr_x <= 9'd511; wr_pix <= 16'hb1ff; @(posedge clk);
    wr_valid <= 0; wr_end <= 1;
    start_cycle = model_cycle;
    @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait ((dut.dst == 0) && !dut.flush_req && !wr_end);
    op_cycles = model_cycle - start_cycle;
    op_writes = write_accepts;
    op_zero_be = zero_be_accepts;
    $display("FB PERF sparse_flush cycles=%0d writes=%0d zero_be=%0d stalls=%0d",
             op_cycles, op_writes, op_zero_be, stalled_request_cycles);
    if ((op_writes != 2) || (op_zero_be != 0) || (op_cycles > 140)) begin
        errors = errors + 1;
        $display("  FAIL sparse flush writes/zero_be/cycles=%0d/%0d/%0d want 2/0/<=140",
                 op_writes, op_zero_be, op_cycles);
    end
    check_pixel(0, 8'd12, 9'd0, 16'ha000);
    check_pixel(0, 8'd12, 9'd4, 16'h4444);
    check_pixel(0, 8'd12, 9'd511, 16'hb1ff);

    // Multiple separated islands, supplied right-to-left, exercise resuming
    // the synchronous read pipeline and then sustaining an adjacent word.
    reset_case();
    for (i = 0; i < 128; i = i + 1)
        ddr[word_index(0, 8'd15, i[6:0])] = 64'h7004_7003_7002_7001;
    @(posedge clk); wr_start <= 1; wr_buf <= 0; wr_y <= 8'd15;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd31; wr_pix <= 16'hd01f; @(posedge clk);
    wr_x <= 9'd16; wr_pix <= 16'hd010; @(posedge clk);
    wr_x <= 9'd12; wr_pix <= 16'hd00c; @(posedge clk);
    wr_x <= 9'd0;  wr_pix <= 16'hd000; @(posedge clk);
    wr_valid <= 0; wr_end <= 1;
    @(posedge clk); wr_end <= 0;
    @(posedge clk);
    wait ((dut.dst == 0) && !dut.flush_req && !wr_end);
    if ((write_accepts != 4) || (zero_be_accepts != 0)) begin
        errors = errors + 1;
        $display("  FAIL segmented flush writes/zero_be=%0d/%0d want=4/0",
                 write_accepts, zero_be_accepts);
    end
    check_pixel(0, 8'd15, 9'd0,  16'hd000);
    check_pixel(0, 8'd15, 9'd12, 16'hd00c);
    check_pixel(0, 8'd15, 9'd13, 16'h7002);
    check_pixel(0, 8'd15, 9'd16, 16'hd010);
    check_pixel(0, 8'd15, 9'd31, 16'hd01f);

    // Sparse shadow run has the same mask, but each retained qword requires a
    // read/modify/write because bit 15 is cleared from existing pixels.
    reset_case();
    for (i = 0; i < 128; i = i + 1)
        ddr[word_index(0, 8'd13, i[6:0])] = 64'h8004_8003_8002_8001;
    @(posedge clk); wr_start <= 1; wr_buf <= 0; wr_y <= 8'd13;
    wr_shadow <= 1;
    @(posedge clk); wr_start <= 0;
    wr_valid <= 1; wr_x <= 9'd0; wr_pix <= 16'hdead; @(posedge clk);
    wr_x <= 9'd511; @(posedge clk);
    wr_valid <= 0; wr_end <= 1;
    start_cycle = model_cycle;
    @(posedge clk); wr_end <= 0; wr_shadow <= 0;
    @(posedge clk);
    wait ((dut.dst == 0) && !dut.flush_req && !wr_end);
    op_cycles = model_cycle - start_cycle;
    op_writes = write_accepts;
    op_reads = read_accepts;
    $display("FB PERF sparse_shadow cycles=%0d reads=%0d writes=%0d zero_be=%0d stalls=%0d",
             op_cycles, op_reads, op_writes, zero_be_accepts,
             stalled_request_cycles);
    if ((op_reads != 2) || (op_writes != 2) ||
        (zero_be_accepts != 0) || (op_cycles > 160)) begin
        errors = errors + 1;
        $display("  FAIL sparse shadow reads/writes/zero_be/cycles=%0d/%0d/%0d/%0d want 2/2/0/<=160",
                 op_reads, op_writes, zero_be_accepts, op_cycles);
    end
    check_pixel(0, 8'd13, 9'd0, 16'h0001);
    check_pixel(0, 8'd13, 9'd4, 16'h8001);
    check_pixel(0, 8'd13, 9'd511, 16'h0004);

    // Scanout is already a single 128-beat DDR read burst. The complete line
    // is published atomically at x=0 after all response bubbles.
    reset_case();
    for (i = 0; i < 128; i = i + 1)
        ddr[word_index(0, 8'd14, i[6:0])] = {4{16'hc000 | i[15:0]}};
    rd_x <= 0; rd_buf <= 0; rd_y <= 8'd14; rd_req <= 1;
    start_cycle = model_cycle;
    @(posedge rd_ack);
    op_cycles = model_cycle - start_cycle;
    op_reads = read_accepts;
    op_beats = read_beats;
    rd_req <= 0; wait (!rd_ack);
    repeat (2) @(posedge clk);
    rd_x <= 9'd511; @(posedge clk); #1;
    if (rd_pix !== 16'hc07f) begin
        errors = errors + 1;
        $display("  FAIL scanout x=511 got=%04x want=c07f", rd_pix);
    end
    $display("FB PERF scanout cycles=%0d requests=%0d beats=%0d stalls=%0d",
             op_cycles, op_reads, op_beats, stalled_request_cycles);
    if ((op_reads != 1) || (op_beats != 128)) begin
        errors = errors + 1;
        $display("  FAIL scanout requests/beats=%0d/%0d want=1/128",
                 op_reads, op_beats);
    end

    if (errors == 0) $display("FB THROUGHPUT PASS");
    else             $display("FB THROUGHPUT FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #2000000;
    $display("FB THROUGHPUT FAIL (timeout)");
    $finish;
end

endmodule
