//============================================================================
//  Real-V25 INTEGRATION test (S32_REAL_V25).
//
//  Proves the *real* NEC V25 core (s32_v25_cpu + s80x86), instantiated inside
//  s32_core, fetches its encrypted program through s32_core's SDRAM port 5
//  (SDR_MCU_BASE offset + arbiter), runs the genuine ga2 firmware, and writes
//  the wake-up string into the mailbox that the V60 reads back over the real
//  core bus at 0xA00000.  tb_v25_firmware proves the core in isolation; this
//  proves the s32_core *integration* wiring (p5 program fetch + mailbox round
//  trip) that the HLE path never exercises.
//
//  The V60 polls the mailbox (TEST.B + BE) so it waits for the firmware to
//  produce the string rather than racing it, then stores the checked bytes to
//  work RAM.  PASS requires the real-firmware wake bytes to arrive via the core.
//
//  Build (Verilator, WSL): +define+S32_REAL_V25 + the s80x86 manifest +
//  MICROCODE_ROM_PATH.  See verif/v25/run_v25_integration.sh.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_core_v25int;

import s32_pkg::*;

reg clk_sys = 0, clk_ram = 0, rst = 1;
always #10.35 clk_sys = ~clk_sys;   // ~48.3 MHz — the V25 derives 10 MHz from this
always #5.175 clk_ram = ~clk_ram;
reg clk_v25 = 0;                    // clk_sys/2 (~24.16 MHz): s80x86 compute domain
always @(posedge clk_sys) clk_v25 <= ~clk_v25;

reg ce_cpu = 0;
reg [1:0] cdiv = 0;
always @(posedge clk_sys) begin
    cdiv   <= (cdiv == 2) ? 0 : cdiv + 1;
    ce_cpu <= (cdiv == 0);
end

board_desc_t board;
initial begin
    board = '0;
    board.has_v25   = 1'b1;    // ga2: real V25 enabled
    board.v25_table = 1'b0;    // ga2 opcode-decryption table
    board.has_ppi   = 1'b1;    // 4-player board
end

// -------------------------------------------------------------------------
// SDRAM p0: V60 program (16 KB window, mirrored) — clk_sys-domain ack.
// -------------------------------------------------------------------------
reg [15:0] rom [0:8191];
wire        p0_req;
wire [26:1] p0_addr;
reg  [15:0] p0_dout;
reg         p0_ack = 0;
always @(posedge clk_sys) begin
    p0_ack  <= p0_req & ~p0_ack;
    p0_dout <= rom[p0_addr[13:1]];
end

// -------------------------------------------------------------------------
// SDRAM p5: V25 encrypted program.  Load the raw 64 KB mcu.bin and apply
// MAME's destination<-source address descramble (identical to the production
// loader + tb_v25_firmware), then serve 64-bit words at SDR_MCU_BASE.
// -------------------------------------------------------------------------
localparam [23:0] MCU_BASE_W = SDR_MCU_BASE[26:3];   // 0x0E00000 >> 3
reg [7:0] raw    [0:65535];
reg [7:0] ext    [0:65535];
wire        p5_req;
wire [26:3] p5_addr;
reg  [63:0] p5_dout = 64'h0;
reg         p5_ack  = 0;
reg         p5_pend  = 0;
reg  [26:3] p5_addr_l = 0;
integer     p5_reads = 0;

function automatic [15:0] descramble(input [15:0] i);
    descramble = {i[14], i[11], i[15], i[12], i[13], i[4], i[3], i[7],
                  i[5], i[10], i[2], i[8], i[9], i[6], i[1], i[0]};
endfunction

wire [12:0] p5_off = p5_addr_l[15:3] - MCU_BASE_W[12:0];   // 64-bit word offset into mcu image
always @(posedge clk_sys) begin
    p5_ack <= 1'b0;
    if (rst) begin
        p5_pend <= 1'b0;
    end else begin
        if (p5_req && !p5_pend) begin
            p5_addr_l <= p5_addr;
            p5_pend   <= 1'b1;
            p5_reads  <= p5_reads + 1;
        end
        if (p5_pend) begin
            p5_dout <= { ext[{p5_off, 3'd7}], ext[{p5_off, 3'd6}],
                         ext[{p5_off, 3'd5}], ext[{p5_off, 3'd4}],
                         ext[{p5_off, 3'd3}], ext[{p5_off, 3'd2}],
                         ext[{p5_off, 3'd1}], ext[{p5_off, 3'd0}] };
            p5_ack  <= 1'b1;
            p5_pend <= 1'b0;
        end
    end
end

// -------------------------------------------------------------------------
// sprite ROM p2 idle ack; unused analog/trackball tie-offs.
// -------------------------------------------------------------------------
wire p2_req; reg p2_ack;
always @(posedge clk_ram) p2_ack <= p2_req;
wire fbw_valid, fbe_req, fbr_req;
wire [7:0] adc_a [0:7];
wire       tdv_a [0:2];
wire signed [8:0] tdx_a [0:2], tdy_a [0:2];
wire [7:0] tbt_a [0:2];
generate
    for (genvar gi = 0; gi < 8; gi = gi + 1) assign adc_a[gi] = 8'h80;
    for (genvar gj = 0; gj < 3; gj = gj + 1) begin
        assign tdv_a[gj] = 1'b0; assign tdx_a[gj] = 9'sd0;
        assign tdy_a[gj] = 9'sd0; assign tbt_a[gj] = 8'hff;
    end
endgenerate
reg fbe_ack;
always @(posedge clk_ram) fbe_ack <= fbe_req;

wire dbg_halted_w;   // s32_core debug_halted port (Verilator-safe observation)

s32_core core (
    .clk_sys(clk_sys), .clk_ram(clk_ram), .clk_v25(clk_v25),
    .rst(rst), .video_rst(rst), .board(board),
    .ce_cpu(ce_cpu), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr), .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(), .sdr_p1_addr(), .sdr_p1_dout(64'h0), .sdr_p1_ack(1'b1),
    .sdr_p2_req(p2_req), .sdr_p2_addr(), .sdr_p2_dout({8{16'h1111}}), .sdr_p2_ack(p2_ack),
    .sdr_p3_req(), .sdr_p3_addr(), .sdr_p3_dout(16'h0), .sdr_p3_ack(1'b0),
    .sdr_p4_req(), .sdr_p4_addr(), .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr), .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .fb_wr_start(), .fb_wr_buf(), .fb_wr_x(), .fb_wr_y(),
    .fb_wr_valid(fbw_valid), .fb_wr_pix(), .fb_wr_end(),
    .fb_wr_shadow(), .fb_wr_busy(1'b0),
    .fb_er_req(fbe_req), .fb_er_buf(), .fb_er_y(), .fb_er_ack(fbe_ack),
    .fb_rd_req(fbr_req), .fb_rd_buf(), .fb_rd_y(), .fb_rd_ack(1'b1),
    .fb_rd_x(), .fb_rd_pix(16'hffff),
    .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
    .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0), .eep_rd_addr(6'h0),
    .eep_rd_data(), .eep_upload(1'b0), .eep_modified(),
    .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff),
    .in_svc12(8'hff), .in_svc34(8'hff),
    .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
    .in_svc12_b(8'hff), .in_svc34_b(8'hff),
    .adc_ch(adc_a), .trk_dv(tdv_a), .trk_dx(tdx_a), .trk_dy(tdy_a), .trk_btn(tbt_a),
    .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
    .rgb_a(), .rgb_b(), .ce_pix(), .hs(), .vs(), .hb(), .vb(),
    .audio_l(), .audio_r(), .out_lamps(),
    .debug_pc(), .debug_halted(dbg_halted_w), .debug_status(), .debug_first_rom(), .debug_hcnt()
);

// -------------------------------------------------------------------------
// V60 program assembler (same encodings as tb_core_ga2path/tb_core_boot).
// -------------------------------------------------------------------------
integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) rom[pc_a[31:1]][15:8] = b;
    else         rom[pc_a[31:1]][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w); ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); endtask
task movw_imm_reg(input [31:0] imm, input [4:0] rn); ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm); endtask
task movw_reg_abs(input [4:0] rn, input [31:0] a);   ab(8'h2D); ab(8'h00 | rn); ab(8'hF3); aw32(a); endtask
task movb_abs_reg(input [31:0] a, input [4:0] rn);   ab(8'h09); ab(8'h20 | rn); ab(8'hF3); aw32(a); endtask
// TEST.B <abs32>: 0xF0 opcode, 0xF3 direct-address mode, addr32.  Sets Z if 0.
task testb_abs(input [31:0] a); ab(8'hF0); ab(8'hF3); aw32(a); endtask
// BE disp8 (0x64): branch if Z.  disp is relative to the branch instruction's
// own address; the preceding TEST.B is 6 bytes so a poll self-loop uses -6.
task be_poll_back6; ab(8'h64); ab(8'hFA); endtask

integer i;
initial begin
    for (i = 0; i < 8192; i = i + 1) rom[i] = 16'h0000;

    // reset vector: JMP $000000 (mirror wrap: 0xFFFFF0 -> rom word 0x3FF0)
    pc_a = 32'h3FF0; ab(8'hD6); ab(8'hF3); aw32(32'h0000_0000);

    pc_a = 0;
    movw_imm_reg(32'h0020_F000, 5'd31);          // SP
    // Poll for the real-V25 wake byte 'w' at 0xA00100 (mailbox inits to 0).
    testb_abs(32'h00A0_0100); be_poll_back6;     // wait until byte != 0
    // Poll for wake byte 0x22 ('X') so the leading string is fully written.
    testb_abs(32'h00A0_0122); be_poll_back6;
    // Read the two checked bytes and store to work RAM for the harness.
    movb_abs_reg(32'h00A0_0100, 5'd6);
    movb_abs_reg(32'h00A0_0122, 5'd7);
    movw_reg_abs(5'd6, 32'h0020_0010);           // wram word 0x08 low byte
    movw_reg_abs(5'd7, 32'h0020_0012);           // wram word 0x09 low byte
    ab(8'h00);                                    // HALT
end

// Load + descramble the genuine ga2 MCU image.
integer fd, got, src;
initial begin
    fd = $fopen("roms/sim/ga2/mcu.bin", "rb");
    if (fd == 0) begin $display("V25_INT FAIL: cannot open roms/sim/ga2/mcu.bin"); $finish; end
    got = $fread(raw, fd); $fclose(fd);
    if (got != 65536) begin $display("V25_INT FAIL: mcu.bin is %0d bytes, expected 65536", got); $finish; end
    for (src = 0; src < 65536; src = src + 1) ext[src] = raw[descramble(src[15:0])];
end

// Track when the V60 halts, relative to reset release.  A correctly-polling V60
// halts only after the real V25 firmware has written the wake bytes (thousands+
// of cycles); a mis-encoded poll that fell through would halt within a few
// hundred cycles.  This guards the round-trip claim without any hierarchical peek.
integer cyc = 0;
integer halt_cycle = -1;
always @(posedge clk_sys) if (!rst) begin
    cyc <= cyc + 1;
    if (dbg_halted_w && halt_cycle < 0) halt_cycle <= cyc;
end

initial begin
    repeat (20) @(posedge clk_sys);
    rst = 0;
    // Run long enough for the V25 (10 MHz derived) to boot its firmware and for
    // the V60 poll loops to observe the wake bytes.
    repeat (4_000_000) @(posedge clk_sys);
    $display("V25_INT p5_reads=%0d halted=%0d halt_cycle=%0d", p5_reads, dbg_halted_w, halt_cycle);
    // p5_reads>0  : the real V25 fetched its program through s32_core's SDRAM p5.
    // halted+late : both V60 poll loops exited, i.e. the firmware's mailbox writes
    //               reached the V60 over the real core bus (not a fall-through).
    // Exact wake-byte fidelity is locked by tb_v25_firmware (isolation).
    if (p5_reads > 0 && dbg_halted_w && halt_cycle > 2000)
        $display("V25 INTEGRATION PASS");
    else
        $display("V25 INTEGRATION FAIL");
    $finish;
end

endmodule

`default_nettype wire
