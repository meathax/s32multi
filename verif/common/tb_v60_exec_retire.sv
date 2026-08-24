// V60 simple-register execute/retire overlap regression.
//
// Runs the same register-only instruction stream through a sequential-
// retirement CPU and the production overlap path.  PASS requires architectural equality and
// an identical ordered physical-bus transaction signature as well as a real
// cycle reduction.  This makes the intended contract explicit: internal IDU/
// EXU overlap is faster, but no external access may be removed or reordered.
`timescale 1ns/1ps

module v60_exec_retire_fixture #(
    parameter EXEC_RETIRE = 1'b0
)(
    input              clk,
    input              rst,
    output             done,
    output     [31:0]  cycles,
    output     [31:0]  reads,
    output     [31:0]  writes,
    output     [31:0]  bus_signature,
    output     [31:0]  r0,
    output     [31:0]  r1,
    output     [31:0]  r2
);
localparam integer ITERATIONS = 256;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire  [1:0] c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire  [1:0] m_be;

s32_v60 #(
    .START_PC(32'h0000_0000),
    .EXEC_RETIRE(EXEC_RETIRE)
) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr),
    .bus_size(c_size), .bus_wdata(c_wdata),
    .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1)
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];
reg ack_r = 1'b0;
reg [31:0] cycle_count = 32'd0;
reg [31:0] read_count = 32'd0;
reg [31:0] write_count = 32'd0;
reg [31:0] signature = 32'h7061_0016;
reg [41:0] trace [0:1023];
integer trace_count = 0;

assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;
assign done = cpu.halted;
assign cycles = cycle_count;
assign reads = read_count;
assign writes = write_count;
assign bus_signature = signature;
assign r0 = cpu.r[0];
assign r1 = cpu.r[1];
assign r2 = cpu.r[2];

always @(posedge clk) begin
    if (rst) begin
        ack_r <= 1'b0;
        cycle_count <= 32'd0;
        read_count <= 32'd0;
        write_count <= 32'd0;
        signature <= 32'h7061_0016;
        trace_count = 0;
    end
    else begin
        ack_r <= m_req & ~ack_r;
        if (!cpu.halted) cycle_count <= cycle_count + 32'd1;
        if (m_req && !ack_r) begin
            if (m_we) write_count <= write_count + 32'd1;
            else      read_count <= read_count + 32'd1;
            trace[trace_count] <= {m_we, m_be, m_addr, m_wdata};
            trace_count = trace_count + 1;
            // Order-sensitive signature over the physical transaction payload.
            signature <= {signature[26:0], signature[31:27]} ^
                         {6'b0, m_be, m_addr, m_we} ^
                         {16'b0, m_wdata};
        end
    end
end

integer i;
initial begin : init_program
    reg [7:0] p [0:1023];
    integer k;
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    for (i = 0; i < 1024; i = i + 1) p[i] = 8'h00;
    k = 0;

    // MOVW #$12345678,R1 followed by an unrolled INC.W R2 stream.  The F12
    // retained-loop fixture remains separately covered by tb_v60_fetch; this
    // stream isolates the common short-format retirement bubble without a
    // branch-cache effect.
    p[k]=8'h2d; k=k+1; p[k]=8'h21; k=k+1; p[k]=8'hf4; k=k+1;
    p[k]=8'h78; k=k+1; p[k]=8'h56; k=k+1;
    p[k]=8'h34; k=k+1; p[k]=8'h12; k=k+1;
    for (i = 0; i < ITERATIONS; i = i + 1) begin
        p[k]=8'hdd; k=k+1; p[k]=8'h62; k=k+1; // INC.W R2
    end
    p[k]=8'h00;

    for (i = 0; i < 512; i = i + 1)
        ram[i] = {p[2*i+1], p[2*i]};
end
endmodule

module tb_v60_exec_retire;
reg clk = 1'b0;
reg rst = 1'b1;
always #10 clk = ~clk;

wire base_done, fast_done;
wire [31:0] base_cycles, fast_cycles;
wire [31:0] base_reads, fast_reads, base_writes, fast_writes;
wire [31:0] base_signature, fast_signature;
wire [31:0] base_r0, fast_r0, base_r1, fast_r1, base_r2, fast_r2;

v60_exec_retire_fixture #(.EXEC_RETIRE(1'b0)) base (
    .clk(clk), .rst(rst), .done(base_done), .cycles(base_cycles),
    .reads(base_reads), .writes(base_writes),
    .bus_signature(base_signature), .r0(base_r0), .r1(base_r1), .r2(base_r2)
);
v60_exec_retire_fixture #(.EXEC_RETIRE(1'b1)) fast (
    .clk(clk), .rst(rst), .done(fast_done), .cycles(fast_cycles),
    .reads(fast_reads), .writes(fast_writes),
    .bus_signature(fast_signature), .r0(fast_r0), .r1(fast_r1), .r2(fast_r2)
);

integer timeout;
integer errors = 0;
integer tx;
initial begin
    repeat (8) @(posedge clk);
    rst = 1'b0;
    timeout = 0;
    while (!(base_done && fast_done) && timeout < 100000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    $display("V60 EXEC RETIRE SUMMARY baseline=%0d overlap=%0d saved=%0d reads=%0d signature=%08x",
             base_cycles, fast_cycles, base_cycles-fast_cycles,
             fast_reads, fast_signature);
    if (!(base_done && fast_done)) begin
        errors = errors + 1;
        $display("FAIL timeout base_done=%0d fast_done=%0d", base_done, fast_done);
    end
    if (base_r0 != 0 || fast_r0 != 0 ||
        base_r1 != 32'h1234_5678 || fast_r1 != 32'h1234_5678 ||
        base_r2 != 32'd256 || fast_r2 != 32'd256) begin
        errors = errors + 1;
        $display("FAIL architecture base=%08x/%08x/%08x fast=%08x/%08x/%08x",
                 base_r0, base_r1, base_r2, fast_r0, fast_r1, fast_r2);
    end
    if (base_reads != fast_reads || base_writes != fast_writes ||
        base_signature != fast_signature) begin
        errors = errors + 1;
        $display("FAIL physical bus differs reads=%0d/%0d writes=%0d/%0d sig=%08x/%08x",
                 base_reads, fast_reads, base_writes, fast_writes,
                 base_signature, fast_signature);
    end
    if (base.trace_count != fast.trace_count) begin
        errors = errors + 1;
        $display("FAIL physical transaction counts differ %0d/%0d",
                 base.trace_count, fast.trace_count);
    end
    else begin
        for (tx = 0; tx < base.trace_count; tx = tx + 1) begin
            if (base.trace[tx] !== fast.trace[tx]) begin
                errors = errors + 1;
                $display("FAIL physical transaction %0d differs %011x/%011x",
                         tx, base.trace[tx], fast.trace[tx]);
            end
        end
    end
    if (fast_cycles + 32'd250 > base_cycles) begin
        errors = errors + 1;
        $display("FAIL throughput gain too small: baseline=%0d overlap=%0d",
                 base_cycles, fast_cycles);
    end

    if (errors == 0)
        $display("V60 EXEC RETIRE PASS");
    else
        $fatal(1, "V60 EXEC RETIRE FAIL (%0d errors)", errors);
    $finish;
end
endmodule
