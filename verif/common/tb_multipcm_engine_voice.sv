// Replay the OutRunners engine-voice key-on sequence captured from MAME
// (slot raw 29 = voice 26): pan, KEY ON, then sample select — the reverse
// of the usual sample-then-key order every music voice uses. MAME retriggers
// on the sample write while key is on (multipcm.cpp case 1); this bench
// checks whether the RTL ends up playing the right sample.
`timescale 1ns/1ps

module tb_multipcm_engine_voice;
    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz-ish; ratio to ce below matches core

    reg ce = 1'b0;
    reg [31:0] acc = 0;
    localparam [31:0] PCM_INC = 32'd888908667;
    always @(posedge clk) {ce, acc} <= {1'b0, acc} + {1'b0, PCM_INC};

    reg rst = 1'b1;
    reg cs = 1'b0, we = 1'b0;
    reg [1:0] addr = 0;
    reg [7:0] wdata = 0;
    wire rom_req;
    wire [21:0] rom_addr;
    reg  [7:0] rom_data = 0;
    reg  rom_ack = 1'b0;
    wire signed [15:0] out_l, out_r;

    integer ack_delay = 1;
    integer ack_cnt = 0;
    reg pending = 1'b0;

    s32_multipcm dut (
        .clk(clk), .ce(ce), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack),
        .bank_lo(3'd0), .bank_hi(3'd0),
        .out_l(out_l), .out_r(out_r)
    );

    // Synthetic ROM: the real OutRunners engine descriptor (sample 5 at
    // 5*12=0x3c: 8-bit fmt, start 0x2ba4, loop 0, end 0x10000-0xfd18=0x2e8,
    // AR=15 D1R=0 DL=0 D2R=0 KRS=0 RR=15, no LFO defaults) plus a second
    // sample-8 descriptor for the interleaved music voices, and nonzero
    // bytes everywhere else standing in for sample data.
    function [7:0] rom_byte(input [21:0] a);
        reg [3:0] di;
    begin
        if (a >= 22'h00003c && a < 22'h000048) begin
            di = a - 22'h00003c;
            case (di)
                0: rom_byte = 8'h00;  1: rom_byte = 8'h2b;
                2: rom_byte = 8'ha4;  3: rom_byte = 8'h00;
                4: rom_byte = 8'h00;  5: rom_byte = 8'hfd;
                6: rom_byte = 8'h18;  7: rom_byte = 8'h00;
                8: rom_byte = 8'hf0;  9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f; 11: rom_byte = 8'h00;
              default: rom_byte = 8'h00;
            endcase
        end
        else if (a >= 22'h000060 && a < 22'h00006c) begin
            di = a - 22'h000060;
            case (di)
                0: rom_byte = 8'h00;  1: rom_byte = 8'h40;
                2: rom_byte = 8'h00;  3: rom_byte = 8'h00;
                4: rom_byte = 8'h00;  5: rom_byte = 8'hfd;
                6: rom_byte = 8'h00;  7: rom_byte = 8'h00;
                8: rom_byte = 8'hf0;  9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f; 11: rom_byte = 8'h00;
              default: rom_byte = 8'h00;
            endcase
        end
        else rom_byte = 8'h40;
    end
    endfunction

    always @(posedge clk) begin
        rom_ack <= 1'b0;
        if (rom_req && !pending) begin pending <= 1'b1; ack_cnt <= 0; end
        else if (pending) begin
            if (ack_cnt >= ack_delay - 1) begin
                rom_data <= rom_byte(rom_addr);
                rom_ack <= 1'b1;
                pending <= 1'b0;
            end
            else ack_cnt <= ack_cnt + 1;
        end
        if (!rom_req) pending <= 1'b0;
    end

    task automatic wr(input [1:0] port, input [7:0] value);
    begin
        @(negedge clk); cs = 1'b1; we = 1'b1; addr = port; wdata = value;
        // Real Z80 OUT (n),A WR strobe is asserted for multiple clk_sys
        // cycles at the 48 MHz/8 MHz ratio (~6 clk_sys per Z80 T-state,
        // WR active ~2 T-states = ~12 cycles) -- cs&&we in the RTL is
        // level-sensitive with no edge qualification, so this exercises
        // whatever repeated-apply behavior the real timing produces.
        repeat (12) @(posedge clk);
        #1; @(negedge clk); cs = 1'b0; we = 1'b0;
        // Z80 OUT pacing: ~4 us between chip writes at 8 MHz
        repeat (400) @(posedge clk);
    end
    endtask

    // Interleaved retrigger on another slot mid-burst, mimicking the real
    // driver servicing music note-on events between engine pitch updates.
    task automatic other_note(input [4:0] s);
    begin
        wr(1, {3'b0, s});
        wr(2, 8'd0); wr(0, 8'h00);
        wr(2, 8'd2); wr(0, 8'h00);
        wr(2, 8'd1); wr(0, 8'h08);
        wr(2, 8'd3); wr(0, 8'h10);
        wr(2, 8'd5); wr(0, 8'h00);
        wr(2, 8'd4); wr(0, 8'h80);
    end
    endtask

    // Peak |mixed contribution| per report window for voice 26 via out_l
    // (only voice active in this bench).
    integer peak = 0;
    integer alfo_min = 99999, alfo_max = 0;
    reg engine_on = 1'b0;
    always @(posedge clk) begin
        if (out_l > peak) peak = out_l;
        if (-out_l > peak) peak = -out_l;
        if (out_r > peak) peak = out_r;
        if (-out_r > peak) peak = -out_r;
        // Track the engine voice's tremolo gain once it is active with
        // tremolo depth written (r7=01). Correct MAME behavior for depth 1
        // is gain wobble 1024..~979 (-0.4 dB); the [6:0] slice bug swept it
        // down to ~4 (-48 dB) at the LFO rate.
        if (engine_on && dut.s_active[26]) begin
            if (dut.s_alfo_gain[26] < alfo_min) alfo_min = dut.s_alfo_gain[26];
            if (dut.s_alfo_gain[26] > alfo_max) alfo_max = dut.s_alfo_gain[26];
        end
    end

    integer i;
    initial begin
        if (!$value$plusargs("ACK=%d", ack_delay)) ack_delay = 1;
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);

        // Background polyphony: key on 20 music voices first (normal
        // sample-then-key order), matching in-race conditions.
        if ($test$plusargs("POLY")) begin
            for (i = 0; i < 20; i = i + 1) begin
                wr(1, (i + (i/7)) & 8'h1f);
                wr(2, 8'd0); wr(0, 8'h00);
                wr(2, 8'd2); wr(0, 8'h00);
                wr(2, 8'd1); wr(0, 8'h08);   // some real sample
                wr(2, 8'd3); wr(0, 8'h10);
                wr(2, 8'd5); wr(0, 8'h00);
                wr(2, 8'd4); wr(0, 8'h80);
            end
        end

        // --- MAME-captured engine key-on, slot raw 29 ---
        wr(1, 8'd29);        // slot select
        wr(2, 8'd0); wr(0, 8'h70);   // r0 pan
        wr(2, 8'd4); wr(0, 8'h80);   // r4 KEY ON  (before sample!)
        wr(2, 8'd2); wr(0, 8'h00);   // r2 sample bit8 = 0
        wr(2, 8'd1); wr(0, 8'h05);   // r1 sample = 5
        wr(2, 8'd2); wr(0, 8'hc0);   // r2 pitch lo
        wr(2, 8'd3); wr(0, 8'he6);   // r3 octave/pitch hi
        wr(2, 8'd5); wr(0, 8'h59);   // r5 TL
        wr(2, 8'd6); wr(0, 8'h33);   // r6 LFO
        wr(2, 8'd10); wr(0, 8'h01);  // r10 (clamps to r7)
        engine_on = 1'b1;

        // idle-engine updates for a while (as captured frame 67235+)
        wr(2, 8'd2); wr(0, 8'hf0); wr(2, 8'd3); wr(0, 8'hf5);
        wr(2, 8'd5); wr(0, 8'h36); wr(2, 8'd6); wr(0, 8'h10);

        // Realistic interleaving: many more engine pitch updates, each one
        // immediately followed by a note-on for a DIFFERENT slot (as the
        // real Z80 driver services music between engine RPM updates), for
        // ~60 update cycles -- matching the ~70 Hz update rate measured
        // live in MAME (1689 writes / 6s over 4-5 regs/update).
        for (i = 0; i < 60; i = i + 1) begin
            wr(1, 8'd29);   // re-select engine slot (driver always does)
            wr(2, 8'd2); wr(0, i[7:0]);
            wr(2, 8'd3); wr(0, 8'hf0 + i[3:0]);
            wr(2, 8'd5); wr(0, 8'h30 + i[3:0]);
            wr(2, 8'd6); wr(0, 8'h10);
            begin
                reg [4:0] raw_other;
                raw_other = (i + (i/7)) & 5'h1f;
                // never key the engine's own raw slot (29) from the
                // "other voice" interleave -- the real driver never does.
                if (raw_other == 5'd29 || raw_other[2:0] == 3'd7)
                    raw_other = 5'd0;
                other_note(raw_other);
            end
        end

        // run ~30 output frames' worth
        repeat (400000) @(posedge clk);
        $display("ENGINE ack=%0d active=%0d envstate=%0d envvol=%07x hold=%0d start=%06x peak=%0d alfo_min=%0d alfo_max=%0d",
            ack_delay, dut.s_active[26], dut.s_env_state[26],
            dut.s_env_vol[26], dut.s_hold[26], dut.s_start[26], peak,
            alfo_min, alfo_max);
        // Depth-1 tremolo must stay within -0.75dB of unity: gain >= 940.
        if (dut.s_active[26] && dut.s_start[26] == 22'h002ba4 && peak > 100 &&
            alfo_min >= 940 && alfo_max <= 1024)
            $display("ENGINE PASS");
        else
            $display("ENGINE FAIL");
        $finish;
    end

    initial begin
        #80000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
