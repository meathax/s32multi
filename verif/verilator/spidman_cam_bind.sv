// Bind-only full-core monitor for Spider-Man's camera-gated enemy manager.
// Passed after scratch/romboot.f on the Verilator command line; no production
// RTL or shared ROM-boot testbench changes are required.
`timescale 1ns/1ps

module spidman_cam_monitor (
    input logic        clk,
    input logic        rst,
    input logic [31:0] frame_no,
    input logic [31:0] pc,
    input logic [31:0] r0,
    input logic [31:0] r20,
    input logic        wram_write,
    input logic [23:0] cpu_addr,
    input logic [15:0] cpu_wdata,
    input logic [1:0]  cpu_be,
    input logic [15:0] ptr_lo,
    input logic [15:0] ptr_hi,
    input logic [15:0] c340,
    input logic [15:0] c342,
    input logic [15:0] c344,
    input logic [15:0] c346,
    input logic [15:0] c348,
    input logic [15:0] c34a,
    input logic [15:0] c34c,
    input logic [15:0] c34e,
    input logic [15:0] c350,
    input logic [15:0] c352
);

integer gate_count = 0;
integer write_count = 0;
logic gate_seen = 0;
logic [31:0] last_frame = 32'hffff_ffff;

always_ff @(posedge clk) begin
    if (rst) begin
        gate_count <= 0;
        write_count <= 0;
        gate_seen <= 0;
        last_frame <= 32'hffff_ffff;
    end
    else begin
        if (pc != 32'h0008_7a99)
            gate_seen <= 0;
        else if (!gate_seen && gate_count < 256) begin
            gate_seen <= 1;
            gate_count <= gate_count + 1;
            $display("[spidgate] f=%0d pc=%08x ptr=%04x_%04x c340=%04x_%04x c344=%04x_%04x c348=%04x_%04x c34c=%04x_%04x c350=%04x_%04x r0=%08x r20=%08x",
                frame_no, pc, ptr_hi, ptr_lo, c342, c340, c346, c344,
                c34a, c348, c34e, c34c, c352, c350, r0, r20);
        end

        if (wram_write && cpu_addr >= 24'h208300 && cpu_addr < 24'h208360 &&
            write_count < 4096) begin
            write_count <= write_count + 1;
            $display("[spidwr] f=%0d pc=%08x addr=%06x data=%04x be=%b ptr=%04x_%04x c344=%04x_%04x c348=%04x_%04x c350=%04x_%04x",
                frame_no, pc, cpu_addr, cpu_wdata, cpu_be, ptr_hi, ptr_lo,
                c346, c344, c34a, c348, c352, c350);
        end

        if (frame_no != last_frame) begin
            last_frame <= frame_no;
            if ((|ptr_lo) || (|ptr_hi) || (|c340) || (|c342) || (|c344) ||
                (|c346) || (|c348) || (|c34a) || (|c34c) || (|c34e) ||
                (|c350) || (|c352))
                $display("[spidcam] f=%0d ptr=%04x_%04x c340=%04x_%04x c344=%04x_%04x c348=%04x_%04x c34c=%04x_%04x c350=%04x_%04x",
                    frame_no, ptr_hi, ptr_lo, c342, c340, c346, c344,
                    c34a, c348, c34e, c34c, c352, c350);
        end
    end
end

endmodule

bind tb_core_romboot spidman_cam_monitor spidman_cam_monitor_i (
    .clk(clk_sys),
    .rst(rst),
    .frame_no(cur_frame),
    .pc(core.v60.pc),
    .r0(core.v60.r[0]),
    .r20(core.v60.r[20]),
    .wram_write(core.m_req && core.m_we && core.sel_wram),
    .cpu_addr(core.A),
    .cpu_wdata(core.m_wdata),
    .cpu_be(core.m_be),
    .ptr_lo(core.work_ram.mem['h4158]),
    .ptr_hi(core.work_ram.mem['h4159]),
    .c340(core.work_ram.mem['h41a0]),
    .c342(core.work_ram.mem['h41a1]),
    .c344(core.work_ram.mem['h41a2]),
    .c346(core.work_ram.mem['h41a3]),
    .c348(core.work_ram.mem['h41a4]),
    .c34a(core.work_ram.mem['h41a5]),
    .c34c(core.work_ram.mem['h41a6]),
    .c34e(core.work_ram.mem['h41a7]),
    .c350(core.work_ram.mem['h41a8]),
    .c352(core.work_ram.mem['h41a9])
);
