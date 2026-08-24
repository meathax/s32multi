//============================================================================
//  Directed test: MOVD (64-bit move) with register-indirect post-increment
//  destination -- the exact instruction OutRunners' boot RAM-clear uses:
//
//    0003F5xx / 0x5AE loop (segas32 orunners epr-15618):
//      2D 20 E0          mov.w #0, R0
//      2D 21 E0          mov.w #0, R1
//      3F 40 8A          mov.d R0, [R10+]     ; writes R0:R1 (8 bytes)
//      C6 A2 F4 FF       dbr  R2, loop
//
//  MAME executes each mov.d as an 8-byte store with R10 += 8; the boot loop
//  (256 iterations x 4 unrolled = 0x2000 bytes) clears 0x20E000-0x20FFFF,
//  including the test-menu request flag at 0x20E700.  A broken MOVD leaves
//  that flag as power-up garbage and OutRunners drops into TEST MODE.
//============================================================================
`timescale 1ns/1ps

module tb_v60_movd;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(),
    .nmi_n(1'b1)
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];
reg        ack_r;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    begin
        if (pc_a[0]) ram[pc_a>>1][15:8] = b;
        else         ram[pc_a>>1][7:0]  = b;
        pc_a = pc_a + 1;
    end
endtask

integer i;
integer errors = 0;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'hCDCD;  // power-up junk

    // program at 0:
    pc_a = 0;
    // mov.w #0, R0            2D 20 E0
    ab(8'h2D); ab(8'h20); ab(8'hE0);
    // mov.w #0, R1            2D 21 E0
    ab(8'h2D); ab(8'h21); ab(8'hE0);
    // mov.w #$4000, R10       2D 2A F4 00 40 00 00
    ab(8'h2D); ab(8'h2A); ab(8'hF4); ab(8'h00); ab(8'h40); ab(8'h00); ab(8'h00);
    // mov.w #2, R2            2D 22 F4 02 00 00 00  (2 loop passes: dbr
    // decrements then branches while nonzero, so body runs for R2=2 and R2=1)
    ab(8'h2D); ab(8'h22); ab(8'hF4); ab(8'h02); ab(8'h00); ab(8'h00); ab(8'h00);
    // loop: mov.d R0, [R10+]  3F 40 8A   (x4, unrolled as in the ROM)
    ab(8'h3F); ab(8'h40); ab(8'h8A);
    ab(8'h3F); ab(8'h40); ab(8'h8A);
    ab(8'h3F); ab(8'h40); ab(8'h8A);
    ab(8'h3F); ab(8'h40); ab(8'h8A);
    // dbr R2, loop            C6 A2 F4 FF  (disp8 -> back 12+... encoding per ROM: F4=fmt? keep ROM form C6 A2 <disp>)
    // ROM used "C6 A2 F4 FF" = dbr R2, PC-12; our loop body is also 12 bytes
    ab(8'hC6); ab(8'hA2); ab(8'hF4); ab(8'hFF);
    // halt                    00
    ab(8'h00);

    repeat (8) @(posedge clk);
    rst = 0;

    // run until halted or timeout
    for (i = 0; i < 200000 && cpu.halted !== 1'b1; i = i + 1)
        @(posedge clk);
    if (cpu.halted !== 1'b1) begin
        $display("V60 MOVD FAIL: cpu never halted (pc=%08x st=%0d)", cpu.pc, cpu.st);
        $finish;
    end

    // expect 2 loop passes x 4 mov.d x 8 bytes = 64 bytes cleared at 0x4000
    for (i = 0; i < 32; i = i + 1) begin
        if (ram[('h4000>>1)+i] !== 16'h0000) begin
            errors = errors + 1;
            if (errors <= 8)
                $display("  FAIL word @%04x = %04x (want 0000)",
                         'h4000 + i*2, ram[('h4000>>1)+i]);
        end
    end
    // guard word beyond the cleared range must stay junk
    if (ram[('h4000>>1)+32] !== 16'hCDCD) begin
        errors = errors + 1;
        $display("  FAIL guard @%04x = %04x (want cdcd)",
                 'h4040, ram[('h4000>>1)+32]);
    end
    // R10 must have advanced by 64
    if (cpu.r[10] !== 32'h0000_4040) begin
        errors = errors + 1;
        $display("  FAIL R10 = %08x (want 00004040)", cpu.r[10]);
    end

    if (errors == 0) $display("V60 MOVD PASS");
    else             $display("V60 MOVD FAIL errors=%0d", errors);
    $finish;
end

initial begin
    #80000000;
    $display("V60 MOVD FAIL timeout");
    $finish;
end

endmodule
