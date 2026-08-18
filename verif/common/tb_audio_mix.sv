`timescale 1ns/1ps

// s32_audio_mix is now Multi 32-only (no System32 routing arm exists -- the
// real board has no RF5C68 and no second YM3438, see rtl/audio/s32_audio_mix.sv).
module tb_audio_mix;
    logic signed [15:0] fm1_l, fm1_r, mp_l, mp_r;
    wire  signed [15:0] audio_l, audio_r;
    integer errors = 0;

    s32_audio_mix dut (.*);

    task automatic check_output(input signed [15:0] want_l, input signed [15:0] want_r, input [255:0] label_text);
        begin
            #1;
            if ((audio_l !== want_l) || (audio_r !== want_r)) begin
                $display("FAIL %0s: got L=%0d R=%0d want L=%0d R=%0d",
                         label_text, audio_l, audio_r, want_l, want_r);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        fm1_l = '0; fm1_r = '0; mp_l = '0; mp_r = '0;
        check_output(16'sd0, 16'sd0, "zero");

        // Multi 32 (MAME segas32.cpp): BOTH the YM and the MultiPCM cross-route
        // identically -- stream 1 -> sleft, stream 0 -> sright (add_route(1,"sleft")
        // / add_route(0,"sright") for ymsnd and m_multipcm alike).  So the system
        // LEFT output takes each device's RIGHT channel and vice versa (audit AU-N1;
        // the MultiPCM used to be routed straight, mirroring its stereo image).
        //   mix_l = 3*fm1_r + 7*mp_r = 3*800 + 7*(-1000) = -4600; /20 -> -230
        //   mix_r = 3*fm1_l + 7*mp_l = 3*400 + 7*( 1000) =  8200; /20 ->  410
        fm1_l = 16'sd400; fm1_r = 16'sd800;
        mp_l = 16'sd1000; mp_r = -16'sd1000;
        check_output(-16'sd230, 16'sd410, "Multi32 MAME cross-route gains");

        fm1_l = 16'sh7fff; fm1_r = 16'sh7fff;
        mp_l = 16'sh7fff; mp_r = 16'sh7fff;
        check_output(16'sd16383, 16'sd16383, "Multi32 routed gain");

        // Full-scale negative in both channels: mix_l = 3*fm1_r + 7*mp_r =
        // 3*(-32768) + 7*(-32768) = -327680; /20 (exact, truncating toward
        // zero) = -16384. Below the clamp floor (-32768), so this exercises
        // the divide path, not the saturation path.
        fm1_l = 16'sh8000; fm1_r = 16'sh8000;
        mp_l = 16'sh8000; mp_r = 16'sh8000;
        check_output(-16'sd16384, -16'sd16384, "Multi32 full-scale negative");

        if (errors == 0) $display("AUDIO MIX PASS");
        else             $display("AUDIO MIX FAIL errors=%0d", errors);
        $finish;
    end
endmodule
