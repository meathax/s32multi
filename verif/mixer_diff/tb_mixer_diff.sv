`timescale 1ns/1ps

module tb_mixer_diff;

localparam integer VECTOR_BITS = 1179;

reg clk = 0;
always #5 clk = ~clk;
reg clk_sys = 0;
always @(posedge clk) clk_sys = ~clk_sys;

reg rst = 1;
reg [8:0] disp_x = 0;
reg [8:0] disp_y = 0;
reg [5:0] layer_off = 0;
reg [15:0] bg_ctrl = 0;
reg [13:0] px [0:5];
reg [15:0] spr_pix = 16'hffff;
reg reg_we = 0;
reg [5:0] reg_addr = 0;
reg [15:0] reg_wdata = 0;
reg [1:0] reg_be = 0;
reg frame_latch = 1'b0;
wire [13:0] pal_addr;
reg [15:0] pal_data = 0;
wire [23:0] rgb;

s32_mixer dut (
    .clk(clk), .rst(rst),
    .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_be(reg_be),
    .reg_rdata(), .reg_raddr(6'd0), .reg_r4e(),
    .disp_x(disp_x), .disp_y(disp_y), .disp_active(1'b1),
    .display_en(1'b1), .flip_y(1'b0), .frame_latch(frame_latch),
    .layer_off(layer_off), .bg_ctrl(bg_ctrl),
    .px_text(px[0]), .px_nbg0(px[1]), .px_nbg1(px[2]),
    .px_nbg2(px[3]), .px_nbg3(px[4]), .px_bmp(px[5]),
    .spr_pix(spr_pix), .pal_addr(pal_addr), .pal_data(pal_data), .rgb(rgb)
);

function automatic [15:0] palette_of(input [13:0] index);
    logic [31:0] value;
    begin
        value = ({18'd0, index} * 32'h00001f35)
              ^ ({18'd0, index} << 7)
              ^ ({18'd0, index} >> 3);
        palette_of = {1'b0, value[14:0]};
    end
endfunction

// The mixer's palette read port is registered on the mixer clock, not on
// clk_sys: s32_palette drives both mix_bank_q and the RAM's q_b_r from
// "always @(posedge mix_clk)", and s32_core wires mix_clk to clk_ram — the
// same clock this bench calls clk.  Responding on clk_sys modelled a two-
// clk_ram palette instead of the one-clk_ram port the core actually builds,
// which let the bench pass a mixer that depends on latency the hardware does
// not have.  Model the real port.
always @(posedge clk)
    pal_data <= palette_of(pal_addr);

reg [VECTOR_BITS-1:0] vector;
reg [23:0] expected;
reg toggle_x = 0;
integer fd;
integer scan_result;
integer count = 0;
integer errors = 0;
integer top2_checks = 0;
integer pos;
integer i;
string vector_path;

reg [10:0] ref_first;
reg [10:0] ref_second;

task automatic consider_candidate(input [6:0] key, input [3:0] selector);
    reg [10:0] candidate;
begin
    candidate = {key, selector};
    if (key > ref_first[10:4]) begin
        ref_second = ref_first;
        ref_first = candidate;
    end
    else if (key > ref_second[10:4]) begin
        ref_second = candidate;
    end
end
endtask

// Check the priority pipeline independently of the final RGB oracle. This
// catches runner-up selection errors even when the winning layer does not
// enable blending and the second palette lookup cannot affect the pixel.
always @(negedge clk) if (dut.second_pending) begin
    // Background is the legacy no-partner sentinel when every opponent key is
    // zero. All non-zero keys include the unique layer rank.
    ref_first = {7'd0, 4'd7};
    ref_second = {7'd0, 4'd7};
    consider_candidate(dut.ep_spr_s,  4'd6);
    consider_candidate(dut.ep_text_s, 4'd0);
    consider_candidate(dut.ep_nbg0_s, 4'd1);
    consider_candidate(dut.ep_nbg1_s, 4'd2);
    consider_candidate(dut.ep_nbg2_s, 4'd3);
    consider_candidate(dut.ep_nbg3_s, 4'd4);
    consider_candidate(dut.ep_bmp_s,  4'd5);
    consider_candidate(dut.ep_bg,     4'd7);
    top2_checks = top2_checks + 1;
    if ({dut.best_hold, dut.bestsel_hold} !== ref_first ||
        {dut.best2, dut.best2sel} !== ref_second) begin
        errors = errors + 1;
        if (errors <= 20)
            $display("MIXER TOP2 mismatch check=%0d first=%02x/%0d want=%02x/%0d second=%02x/%0d want=%02x/%0d",
                     top2_checks, dut.best_hold, dut.bestsel_hold,
                     ref_first[10:4], ref_first[3:0],
                     dut.best2, dut.best2sel,
                     ref_second[10:4], ref_second[3:0]);
    end
end

task automatic unpack_vector;
begin
    pos = VECTOR_BITS;
    expected = vector[pos-1 -: 24]; pos = pos - 24;
    layer_off = vector[pos-1 -: 6]; pos = pos - 6;
    bg_ctrl = vector[pos-1 -: 16]; pos = pos - 16;
    disp_y = vector[pos-1 -: 9]; pos = pos - 9;
    spr_pix = vector[pos-1 -: 16]; pos = pos - 16;
    for (i = 0; i < 6; i = i + 1) begin
        px[i] = vector[pos-1 -: 14];
        pos = pos - 14;
    end
    for (i = 0; i < 64; i = i + 1) begin
        dut.mreg[i] = vector[pos-1 -: 16];
        pos = pos - 16;
    end
    if (pos != 0) begin
        $display("MIXER DIFF FAIL vector unpack ended at bit %0d", pos);
        $finish;
    end
end
endtask

initial begin
    for (i = 0; i < 6; i = i + 1) px[i] = 0;
    if (!$value$plusargs("VECTORS=%s", vector_path)) begin
        $display("MIXER DIFF FAIL missing +VECTORS");
        $finish;
    end
    fd = $fopen(vector_path, "r");
    if (fd == 0) begin
        $display("MIXER DIFF FAIL cannot open %s", vector_path);
        $finish;
    end

    repeat (4) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);

    while (!$feof(fd)) begin
        scan_result = $fscanf(fd, "%h\n", vector);
        if (scan_result == 1) begin
            @(negedge clk);
            unpack_vector();
            // The vector loader sets the RAM directly for speed. Replay 0x4C
            // through the real write port so its registered decode mirrors
            // hardware, where software can only update it via reg_we.
            reg_we = 1'b1;
            reg_addr = 6'h26;
            reg_wdata = dut.mreg[6'h26];
            reg_be = 2'b01;
            @(negedge clk);
            reg_we = 1'b0;
            reg_be = 2'b00;
            // s32_mixer's color-offset select ($3E) and both offset banks
            // are whole-frame quantities: coloroffs_bank0/1 (and r3e_f/
            // r4c15_f/layer_color_flags_f) only latch from the live mreg
            // array on a frame_latch pulse. unpack_vector() pokes mreg
            // directly per vector, so without a pulse here they stay frozen
            // at whatever the previous vector (or the power-up 0xFFFF
            // uninitialized-register model) left them at, while the Python
            // reference model in verif/reference/s32_mixer_ref.py reads the
            // vector's regs fresh every time -- a near-total mismatch, not
            // an edge case.
            @(posedge clk); frame_latch = 1'b1;
            @(posedge clk); frame_latch = 1'b0;
            toggle_x = ~toggle_x;
            disp_x = toggle_x ? 9'd510 : 9'd511;
            repeat (16) @(posedge clk);
            #1;
            if (rgb !== expected) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("MIXER DIFF mismatch case=%0d got=%06x want=%06x first=%0d second=%0d idx1=%04x idx2=%04x blend=%0d shadow=%0d co=%0d/%0d pal=%04x/%04x factor=%0d r=%0d,%0d g=%0d,%0d b=%0d,%0d sum=%0d,%0d,%0d",
                             count, rgb, expected, dut.bestsel_hold,
                             dut.best2sel, dut.idx_winner, dut.idx2_hold,
                             dut.blend_hold, dut.shadow_hold,
                             dut.co1_hold, dut.co2_hold,
                             dut.first_pal, dut.pal_data_r, dut.blendfactor_s,
                             dut.r1_pipe, dut.r2_pipe, dut.g1_pipe, dut.g2_pipe,
                             dut.b1_pipe, dut.b2_pipe,
                             dut.rr_pipe, dut.gg_pipe, dut.bb_pipe);
            end
            count = count + 1;
        end
    end
    $fclose(fd);
    if (top2_checks != count) begin
        errors = errors + 1;
        $display("MIXER TOP2 FAIL checks=%0d vectors=%0d", top2_checks, count);
    end
    if (count == 0)
        $display("MIXER DIFF FAIL no vectors");
    else if (errors == 0)
        $display("MIXER DIFF PASS cases=%0d top2=%0d", count, top2_checks);
    else
        $display("MIXER DIFF FAIL cases=%0d errors=%0d", count, errors);
    $finish;
end

initial begin
    #5000000;
    $display("MIXER DIFF FAIL timeout");
    $finish;
end

endmodule
