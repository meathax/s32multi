`timescale 1ns/1ps

module spidman_gate_monitor (
    input logic clk,
    input logic rst,
    input logic [31:0] frame_no,
    input logic [31:0] pc,
    input logic [31:0] r0,
    input logic [31:0] r20,
    input logic [31:0] psw,
    input logic [15:0] ptr_lo,
    input logic [15:0] ptr_hi,
    input logic [15:0] cam_x,
    input logic [15:0] cam_y,
    input logic [15:0] t38,
    input logic [15:0] t3a,
    input logic [15:0] t3c,
    input logic [15:0] t3e
);
    logic [31:0] last_entry_r20 = 32'hffff_ffff;
    logic [31:0] last_admit_r20 = 32'hffff_ffff;
    logic entry_armed = 1'b1;
    logic admit_armed = 1'b1;
    integer entries = 0;
    integer admits = 0;

    always_ff @(posedge clk) begin
        if (rst) begin
            last_entry_r20 <= 32'hffff_ffff;
            last_admit_r20 <= 32'hffff_ffff;
            entry_armed <= 1'b1;
            admit_armed <= 1'b1;
            entries <= 0;
            admits <= 0;
        end
        else begin
            if (pc != 32'h0008_7a99) entry_armed <= 1'b1;
            else if (entry_armed && entries < 1024) begin
                entry_armed <= 1'b0;
                last_entry_r20 <= r20;
                entries <= entries + 1;
                $display("[gatewin] f=%0d r20=%08x ptr=%04x_%04x cam=%04x,%04x x=%04x..%04x y=%04x..%04x r0=%08x psw=%08x",
                    frame_no, r20, ptr_hi, ptr_lo, cam_x, cam_y,
                    t3a, t38, t3e, t3c, r0, psw);
            end

            if (pc != 32'h0008_7abf) admit_armed <= 1'b1;
            else if (admit_armed && admits < 256) begin
                admit_armed <= 1'b0;
                last_admit_r20 <= r20;
                admits <= admits + 1;
                $display("[gateadmit] f=%0d n=%0d r20=%08x cam=%04x,%04x x=%04x..%04x y=%04x..%04x psw=%08x",
                    frame_no, admits + 1, r20, cam_x, cam_y,
                    t3a, t38, t3e, t3c, psw);
            end
        end
    end
endmodule

bind tb_core_romboot spidman_gate_monitor spidman_gate_monitor_i (
    .clk(clk_sys),
    .rst(rst),
    .frame_no(cur_frame),
    .pc(core.v60.pc),
    .r0(core.v60.r[0]),
    .r20(core.v60.r[20]),
    .psw(core.v60.psw),
    .ptr_lo(core.work_ram.mem['h4158]),
    .ptr_hi(core.work_ram.mem['h4159]),
    .cam_x(core.work_ram.mem['h41a2]),
    .cam_y(core.work_ram.mem['h41a3]),
    .t38(core.work_ram.mem[core.v60.r[20][15:1] + 15'h001c]),
    .t3a(core.work_ram.mem[core.v60.r[20][15:1] + 15'h001d]),
    .t3c(core.work_ram.mem[core.v60.r[20][15:1] + 15'h001e]),
    .t3e(core.work_ram.mem[core.v60.r[20][15:1] + 15'h001f])
);
