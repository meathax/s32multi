`timescale 1ns/1ps

// Simulation-only wrapper for long Spider-Man gameplay traces.  It preserves
// the CPU/audio-to-pixel ratios while advancing all clock enables three times
// faster, reducing a 760-frame diagnostic from ~20 minutes to ~7 minutes.
// No production RTL is changed and the normal tb_core_romboot path remains the
// reference used to validate the accelerated trajectory.
module tb_spidman_fast3;
    tb_core_romboot harness();

    reg [1:0] pix_div = 0;
    reg       pix_ce = 0;
    reg       z80_phase = 0;
    reg       z80_ce = 0;
    reg [15:0] fm_acc = 0;
    reg       fm_ce = 0;
    reg [15:0] pcm_acc = 0;
    reg       pcm_ce = 0;
    reg [7:0] p1a = 8'hff;
    reg [7:0] svc = 8'hff;
    integer frame_no = 0;
    integer max_frames = 760;

    // 320 mode is normally one pixel CE per 7.5 system clocks.  Alternating
    // 2/3 clocks yields one per 2.5 clocks (exactly 3x).  416 mode is not used
    // by spidman, but the accumulator form below also handles a future switch.
    reg [7:0] pix_acc = 0;
    always @(posedge harness.clk_sys) begin
        reg [8:0] pix_sum;
        reg [16:0] fm_sum;
        reg [16:0] pcm_sum;
        pix_sum = pix_acc + (harness.core.crt.mode_active ? 9'd120 : 9'd96);
        pix_ce <= (pix_sum >= 9'd240);
        pix_acc <= (pix_sum >= 9'd240) ? pix_sum - 9'd240 : pix_sum[7:0];

        z80_phase <= ~z80_phase;
        z80_ce <= ~z80_phase;

        fm_sum = fm_acc + 17'd32769;
        fm_ce <= fm_sum[16];
        fm_acc <= fm_sum[15:0];

        pcm_sum = pcm_acc + 17'd50856;
        pcm_ce <= pcm_sum[16];
        pcm_acc <= pcm_sum[15:0];
    end

    initial begin
        if (!$value$plusargs("FASTFRAMES=%d", max_frames)) max_frames = 760;
        wait (!harness.rst);
        force harness.ce_cpu = 1'b1;
        force harness.ce_z80 = z80_ce;
        force harness.ce_fm = fm_ce;
        force harness.ce_pcm = pcm_ce;
        force harness.core.crt.ce_pix = pix_ce;
        force harness.in_p1a_r = p1a;
        force harness.in_svc12_r = svc;
    end

    always @(posedge harness.core.vbl_end) begin
        frame_no <= frame_no + 1;
        p1a <= 8'hff;
        svc <= 8'hff;

        // Same gameplay trajectory as +PLAYFIGHT in tb_core_romboot.
        if (frame_no >= 64 && frame_no < 70) svc[2] <= 1'b0;
        if (frame_no >= 84 && frame_no < 90) svc[4] <= 1'b0;
        if (frame_no >= 470 && frame_no < 600 && (frame_no % 40) < 6) begin
            p1a[0] <= 1'b0;
            svc[4] <= 1'b0;
        end
        if (frame_no >= 680) p1a[6] <= 1'b0;
        if (frame_no >= 700 && (frame_no % 25) < 5) p1a[0] <= 1'b0;

        if (frame_no == max_frames) begin
            $display("SPIDMAN FAST3 reached frame %0d", frame_no);
            $finish;
        end
    end
endmodule
