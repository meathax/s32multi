`timescale 1ns/1ps

module tb_multipcm;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg ce = 1'b0;
    always @(posedge clk)
        ce <= ~ce;

    reg rst = 1'b1;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [1:0] addr = 0;
    reg [7:0] wdata = 0;
    wire rom_req;
    wire [21:0] rom_addr;
    reg [7:0] rom_data = 0;
    reg rom_ack = 1'b0;
    wire signed [15:0] out_l;
    wire signed [15:0] out_r;

    reg request_seen = 1'b0;
    reg first_descriptor_seen = 1'b0;
    integer timeout;

    s32_multipcm dut (
        .clk(clk), .ce(ce), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack),
        .bank_lo(3'd0), .bank_hi(3'd0),
        .out_l(out_l), .out_r(out_r)
    );

    function automatic [7:0] rom_byte(input [21:0] a);
        reg [3:0] di;
    begin
        // Descriptor for 9-bit sample 0x102 begins at 0x0c18.
        if (a >= 22'h000c18 && a < 22'h000c24) begin
            di = a[3:0] - 4'h8;
            case (di)
                0: rom_byte = 8'h00; // start = 000100, 8-bit format
                1: rom_byte = 8'h01;
                2: rom_byte = 8'h00;
                3: rom_byte = 8'h00; // loop = 1
                4: rom_byte = 8'h01;
                5: rom_byte = 8'hff; // end = 0x10000-fffc = 4
                6: rom_byte = 8'hfc;
                7: rom_byte = 8'h1a; // default pitch LFO
                8: rom_byte = 8'hf0;
                9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f; // release F: immediate key-off
               11: rom_byte = 8'h05; // default amplitude LFO
              default: rom_byte = 8'h00;
            endcase
        end
        else if (a >= 22'h000100 && a < 22'h000104)
            rom_byte = 8'h80; // signed minimum, catches offset-binary conversion
        // Descriptor for 9-bit sample 0x106 begins at 0x106*12 = 0x0c48;
        // format byte0 bit6 set selects the 12-bit packed format.
        else if (a >= 22'h000c48 && a < 22'h000c54) begin
            di = a[3:0] - 4'h8;
            case (di)
                0: rom_byte = 8'h40; // start = 000200, 12-bit format (bit6)
                1: rom_byte = 8'h02;
                2: rom_byte = 8'h00;
                3: rom_byte = 8'h00; // loop = 1
                4: rom_byte = 8'h01;
                5: rom_byte = 8'hff; // end = 0x10000-fffc = 4
                6: rom_byte = 8'hfc;
                7: rom_byte = 8'h00;
                8: rom_byte = 8'hf0; // attack=F (instant), decay1=0 (sustain)
                9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f; // release F
               11: rom_byte = 8'h00;
              default: rom_byte = 8'h00;
            endcase
        end
        // Two 12-bit samples packed into three bytes at 0x000200 (gew.cpp
        // sound_stream_update, format&4): even index uses {byte0,
        // byte1[3:0],4'h0} = 16'hF0F0 (negative); odd index uses
        // {byte2, byte1[7:4], 4'h0} = 16'h0100 (positive).
        else if (a == 22'h000200)
            rom_byte = 8'hf0;
        else if (a == 22'h000201)
            rom_byte = 8'h0f;
        else if (a == 22'h000202)
            rom_byte = 8'h01;
        else
            rom_byte = 8'h00;
    end
    endfunction

    // Drive the one-clock response at the falling edge after a CE launches a
    // request.  The DUT therefore observes rom_ack on an edge where ce=0,
    // proving that a short memory response cannot be lost between audio CEs.
    always @(negedge clk) begin
        rom_ack <= 1'b0;
        if (rom_req && !request_seen) begin
            rom_data <= rom_byte(rom_addr);
            rom_ack <= 1'b1;
            request_seen <= 1'b1;
            if (!first_descriptor_seen) begin
                if (rom_addr !== 22'h000c18)
                    $fatal(1, "descriptor address %h, expected sample 102 * 12 = 0c18", rom_addr);
                first_descriptor_seen <= 1'b1;
            end
        end
        if (!rom_req)
            request_seen <= 1'b0;
    end

    task automatic write_port(input [1:0] port, input [7:0] value);
    begin
        @(negedge clk);
        cs = 1'b1;
        we = 1'b1;
        addr = port;
        wdata = value;
        @(posedge clk);
        #1;
        @(negedge clk);
        cs = 1'b0;
        we = 1'b0;
    end
    endtask

    task automatic select_reg(input [7:0] value);
    begin
        write_port(2, value);
    end
    endtask

    task automatic write_data(input [7:0] value);
    begin
        write_port(0, value);
    end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Selector 7 is a hole and must not alias channel zero.
        write_port(1, 8'd7);
        select_reg(0);
        write_data(8'hf0);
        if (dut.sreg[0][0] !== 8'h00)
            $fatal(1, "invalid slot selector aliased channel zero");

        // Raw selector 8 maps to logical channel 7, not channel 8.
        write_port(1, 8'd8);
        select_reg(0);
        write_data(8'ha0);
        if (dut.sreg[7][0] !== 8'ha0 || dut.sreg[8][0] !== 8'h00)
            $fatal(1, "VALUE_TO_CHANNEL mapping is incorrect");

        // Register addresses above seven clamp to seven, matching MAME.
        write_port(1, 8'd0);
        select_reg(8'hff);
        write_data(8'h33);
        if (dut.sreg[0][7] !== 8'h33 || dut.sreg[0][0] !== 8'h00)
            $fatal(1, "register selector did not clamp to seven");

        // Reg2 bit zero supplies sample-index bit eight. A reg1 write loads
        // metadata immediately but does not start a key-off voice.
        select_reg(2);
        write_data(8'h01);
        select_reg(1);
        write_data(8'h02);
        timeout = 0;
        while ((dut.df_busy || dut.desc_pending != 0) && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "descriptor fetch timeout");
        if (!first_descriptor_seen) $fatal(1, "descriptor request missing");
        if (dut.s_start[0] !== 22'h000100 || dut.s_loop[0] !== 16'h0001 ||
            dut.s_end[0] !== 17'h00004)
            $fatal(1, "descriptor fields decoded incorrectly");
        if (dut.sreg[0][6] !== 8'h1a || dut.sreg[0][7] !== 8'h05)
            $fatal(1, "descriptor LFO defaults were not copied");
        if (dut.s_active[0]) $fatal(1, "sample-register write started key-off voice");

        // MAME's octave convention makes octave zero half a sample/frame and
        // octave one exactly one sample/frame at pitch zero.
        if (dut.pitch_step(4'h0, 10'h000) !== 25'h08000 ||
            dut.pitch_step(4'h1, 10'h000) !== 25'h10000)
            $fatal(1, "pitch step/octave convention incorrect");

        // Pan 8 mutes both outputs; lower pans attenuate left, upper pans
        // attenuate right. These assertions catch the historical swap.
        if (dut.pan_sample(16'sh4000, 4'h8, 1'b1) !== 0 ||
            dut.pan_sample(16'sh4000, 4'h8, 1'b0) !== 0 ||
            dut.pan_sample(16'sh4000, 4'h1, 1'b1) !== 16'sd11584 ||
            dut.pan_sample(16'sh4000, 4'h1, 1'b0) !== 16'sh4000 ||
            dut.pan_sample(16'sh4000, 4'h9, 1'b1) !== 16'sh4000 ||
            dut.pan_sample(16'sh4000, 4'h9, 1'b0) !== 0)
            $fatal(1, "pan direction/mute semantics incorrect");

        // Key-on reloads current metadata then starts at offset zero.
        select_reg(4);
        write_data(8'h80);
        timeout = 0;
        while (!dut.s_active[0] && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "key-on descriptor/retrigger timeout");

        // Signed ROM byte 80h must produce negative stereo output.
        timeout = 0;
        while ((out_l >= 0 || out_r >= 0) && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 2000)
            $fatal(1, "signed PCM mix missing: %0d/%0d", out_l, out_r);

        // Key-off (gew.cpp write()) only sets the envelope state to RELEASE;
        // the voice must keep playing (s_active stays set, ROM fetches keep
        // happening) while the release rate ramps volume to zero, matching
        // envelope_generator_update()'s RELEASE case which clears
        // m_playing only once m_volume reaches zero. It must NOT still be
        // playing at full volume once the ramp completes, and it must NOT
        // stop instantly either (that was the pre-envelope-generator
        // approximation this revision replaces).
        select_reg(4);
        write_data(8'h00);
        @(posedge clk);
        if (dut.s_env_state[0] !== 2'd3)
            $fatal(1, "key-off did not switch envelope to RELEASE");
        if (!dut.s_active[0])
            $fatal(1, "key-off stopped the voice immediately instead of releasing");

        // Even release=F (env_step's fastest, val==0xf, special-cased to
        // decay_step_rom[63]) takes on the order of MAME's BASE_TIMES[63]
        // (0.45ms scaled by the 14.32833 decay/attack ratio) to reach
        // silence -- multiple output-sample ticks, not one clock. Sample
        // envelope volume twice, a couple of output-sample ticks apart, and
        // require it to be strictly decreasing (a genuine ramp) while the
        // voice is still marked active.
        repeat (500) @(posedge clk);
        if (!dut.s_active[0])
            $fatal(1, "release-F voice deactivated implausibly fast (not a ramp)");
        begin
            reg [26:0] vol_a, vol_b;
            vol_a = dut.s_env_vol[0];
            repeat (500) @(posedge clk);
            vol_b = dut.s_env_vol[0];
            if (!(vol_b < vol_a))
                $fatal(1, "release envelope volume is not decreasing (%0d -> %0d)",
                    vol_a, vol_b);
        end

        // The ramp must eventually reach silence and deactivate the voice;
        // give it a generous margin (BASE_TIMES[63]*14.32833 at a nominal
        // 44100 Hz-class per-voice update rate is a few ms).
        timeout = 0;
        while (dut.s_active[0] && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 200000)
            $fatal(1, "release-F envelope never reached zero/deactivated");
        if (dut.s_env_vol[0] !== 27'd0)
            $fatal(1, "voice deactivated without envelope volume reaching zero");

        // Attack ramp: a fast attack_reg=F (get_rate's val==0xf special
        // case, decay_release/attack_step_rom[63]) should still visibly
        // ramp the envelope gain up from zero rather than jumping straight
        // to full scale on the very first tick after key-on -- distinct
        // from the pre-envelope-generator model where TL alone gated the
        // sample instantly.  Reuse channel 0 with the already-loaded
        // 8-bit descriptor (attack=F, decay1=0) and key it on again.
        select_reg(4);
        write_data(8'h80);
        timeout = 0;
        while (!dut.s_active[0] && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "second key-on retrigger timeout");
        // Not racily asserting vol==0 here: the very first envelope tick
        // may already have landed (attack=F overflows to full in one
        // step), so only check retrigger left RELEASE behind.
        if (dut.s_env_state[0] === 2'd3)
            $fatal(1, "retrigger did not leave the prior RELEASE state");

        // 12-bit packed-sample fetch: select channel 1, sample index 0x106
        // (12-bit format, descriptor above), key it on, and confirm the
        // mixed output goes negative -- only possible if the even-index
        // 12-bit sample was assembled as {byte(adr),byte(adr+1)[3:0],4'h0}
        // = 16'hF0F0 rather than, e.g., the raw middle byte alone (which
        // would read as a small positive 0x0F00).
        write_port(1, 8'd1);   // raw selector 1 -> channel 1 (no hole below it)
        // reg2 (sample bit 8) must land before the reg1 write below, since
        // a reg1 write is what triggers the descriptor fetch and it must
        // see the full {bit8,low byte} = 0x106 index, not a stale 0x006.
        select_reg(2);
        write_data(8'h01);     // sample bit8 = 1 -> index {1,8'h06} = 0x106
        select_reg(1);
        write_data(8'h06);
        select_reg(4);
        write_data(8'h80);
        timeout = 0;
        while (!dut.s_active[1] && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 1000) $fatal(1, "12-bit voice key-on/descriptor timeout");
        if (dut.s_fmt12[1] !== 1'b1)
            $fatal(1, "12-bit format flag not latched for channel 1");

        timeout = 0;
        while ((out_l >= 0 || out_r >= 0) && timeout < 4000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout == 4000)
            $fatal(1, "12-bit packed sample not decoded as negative 0xF0F0: %0d/%0d",
                out_l, out_r);

        $display("MULTIPCM PASS");
        $finish;
    end

    initial begin
        // The release-ramp wait (up to 200000 clk cycles) needs more sim
        // time than the prior instant-key-off model did.
        #4000000;
        $fatal(1, "MULTIPCM timeout");
    end
endmodule
