`timescale 1ns/1ps

// Independent differential oracle for s32_audio_mix, which is now Multi
// 32-only (no System32 routing arm exists -- the real Multi 32 board has no
// RF5C68 and no second YM3438). Kept deliberately separate from the DUT's
// own divide_by_20_exact implementation: this reference divides with `/`
// directly, so a bug in the DUT's shift/add reciprocal network shows up as a
// mismatch here rather than agreeing with itself.
module s32_audio_mix_reference (
    input  signed     [15:0] fm1_l,
    input  signed     [15:0] fm1_r,
    input  signed     [15:0] mp_l,
    input  signed     [15:0] mp_r,
    output signed     [15:0] audio_l,
    output signed     [15:0] audio_r
);

localparam logic signed [19:0] AUDIO_MAX = 20'sd32767;
localparam logic signed [19:0] AUDIO_MIN = -20'sd32768;

wire signed [19:0] fm1_l_w = {{4{fm1_l[15]}}, fm1_l};
wire signed [19:0] fm1_r_w = {{4{fm1_r[15]}}, fm1_r};
wire signed [19:0] mp_l_w  = {{4{mp_l[15]}},  mp_l};
wire signed [19:0] mp_r_w  = {{4{mp_r[15]}},  mp_r};

wire signed [19:0] mix_l = (fm1_r_w <<< 1) + fm1_r_w + (mp_r_w <<< 3) - mp_r_w;
wire signed [19:0] mix_r = (fm1_l_w <<< 1) + fm1_l_w + (mp_l_w <<< 3) - mp_l_w;

function automatic signed [15:0] scale_and_clip(input logic signed [19:0] sample);
    logic signed [19:0] scaled;
    begin
        scaled = sample / 20'sd20;
        if (scaled > AUDIO_MAX)      scale_and_clip = 16'sh7fff;
        else if (scaled < AUDIO_MIN) scale_and_clip = 16'sh8000;
        else                         scale_and_clip = scaled[15:0];
    end
endfunction

assign audio_l = scale_and_clip(mix_l);
assign audio_r = scale_and_clip(mix_r);

endmodule

module tb_audio_mix_diff;

logic signed      [15:0] fm1_l;
logic signed      [15:0] fm1_r;
logic signed      [15:0] mp_l;
logic signed      [15:0] mp_r;
wire  signed      [15:0] dut_l;
wire  signed      [15:0] dut_r;
wire  signed      [15:0] ref_l;
wire  signed      [15:0] ref_r;

integer errors = 0;
integer checks = 0;
integer seed = 32'h32a0_10d5;
integer i;

s32_audio_mix dut (
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .mp_l(mp_l), .mp_r(mp_r),
    .audio_l(dut_l), .audio_r(dut_r)
);

s32_audio_mix_reference reference (
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .mp_l(mp_l), .mp_r(mp_r),
    .audio_l(ref_l), .audio_r(ref_r)
);

task automatic check_current(input [8*48-1:0] label_text);
begin
    #1;
    checks = checks + 1;
    if (dut_l !== ref_l || dut_r !== ref_r) begin
        if (errors < 16)
            $display("FAIL %0s got=%0d,%0d want=%0d,%0d inputs=%0d,%0d,%0d,%0d",
                     label_text, dut_l, dut_r, ref_l, ref_r,
                     fm1_l, fm1_r, mp_l, mp_r);
        errors = errors + 1;
    end
end
endtask

task automatic set_all(input signed [15:0] value);
begin
    fm1_l = value; fm1_r = value;
    mp_l  = value; mp_r  = value;
end
endtask

initial begin
    // Prove the DUT's shift/add divide_by_20_exact against the language's
    // signed division semantics for every possible 20-bit input, including
    // -2^19, before any mixer-arithmetic comparison.
    begin : exhaustive_div20
        logic signed [19:0] sample;
        logic signed [19:0] got;
        logic signed [19:0] want;
        integer n;
        for (n = -524288; n <= 524287; n = n + 1) begin
            sample = n;
            got = dut.divide_by_20_exact(sample);
            want = sample / 20'sd20;
            if (got !== want) begin
                $display("FAIL exhaustive /20 sample=%0d got=%0d want=%0d", sample, got, want);
                errors = errors + 1;
                n = 524288;
            end
        end
    end

    set_all(16'sd0);
    check_current("all zero");
    set_all(16'sh7fff);
    check_current("all positive full scale");
    set_all(16'sh8000);
    check_current("all negative full scale");

    fm1_l = 16'sh7fff; fm1_r = 16'sh8000;
    mp_l  = 16'sd19;   mp_r  = -16'sd19;
    check_current("mixed signed edges");

    fm1_l = 16'sd1;  fm1_r = -16'sd1;
    mp_l  = 16'sd10; mp_r  = -16'sd10;
    check_current("division truncation below zero");

    fm1_l = 16'sd32760; fm1_r = -16'sd32760;
    mp_l  = 16'sd32763; mp_r  = -16'sd32763;
    check_current("near saturation limits");

    for (i = 0; i < 20006; i = i + 1) begin
        fm1_l = $random(seed); fm1_r = $random(seed);
        mp_l  = $random(seed); mp_r  = $random(seed);
        check_current("random differential");
    end

    if (errors == 0)
        $display("PASS: audio mixer differential checks=%0d", checks);
    else
        $fatal(1, "FAIL: audio mixer differential errors=%0d checks=%0d", errors, checks);
    $finish;
end

endmodule
