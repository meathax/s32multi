`timescale 1ns/1ps

// Multi 32 sound-subsystem real-ROM integration probe (production T80).
//
// tb_soundsys_realrom covers the System 32 wiring (SYSTEM32_ONLY=1, RF5C68,
// two YM3438s).  Multi 32 is a different subsystem: one YM3438, MultiPCM in
// place of the RF5C68 at 0xC000-0xDFFF, the MultiPCM bank register on Z80 port
// 0xB0 instead of sound_bank_hi, and an 8 MHz / 10 MHz CE pair.  Nothing
// exercised that path end to end before this bench.
//
// Copyrighted images are supplied at runtime and stay under ignored roms/.
// This bench observes bus activity and subsystem state only.
//   +ROM=<soundcpu.hex>   4 MiB Z80 region as little-endian 16-bit words
//   +PCM=<multipcm.hex>   4 MiB MultiPCM sample region, same word format
//   +CYCLES=<n>           clk_sys cycles to run after the Z80 leaves reset
module tb_soundsys_multi32;
    reg clk = 1'b0;
    always #10.345 clk = ~clk; // 48.317307 MHz, matching the generated PLL output

    reg rst = 1'b1;
    reg z80_reset = 1'b1;
    reg [15:0] acc_z80 = 16'd0;
    reg [15:0] acc_fm = 16'd0;
    reg [15:0] acc_pcm = 16'd0;
    reg ce_z80 = 1'b0;
    reg ce_fm = 1'b0;
    reg ce_pcm = 1'b0;

    // Multi 32 rates: Z80 8.0 MHz, MultiPCM 10.0 MHz (Arcade-SegaSystem32.sv).
    always @(posedge clk) begin
        logic [16:0] sum;
        if (rst) begin
            acc_z80 <= 16'd0;
            acc_pcm <= 16'd0;
            ce_z80  <= 1'b0;
            ce_pcm  <= 1'b0;
        end
        else begin
            sum = acc_z80 + 17'd10851;
            ce_z80 <= sum[16];
            acc_z80 <= sum[15:0];
            sum = acc_pcm + 17'd13564;
            ce_pcm <= sum[16];
            acc_pcm <= sum[15:0];
        end
    end

    // The production FM NCO free-runs through reset so JT12's enabled-clock
    // rings are actually flushed.
    always @(posedge clk) begin
        logic [16:0] sum;
        sum = acc_fm + 17'd10851;
        ce_fm <= sum[16];
        acc_fm <= sum[15:0];
    end

    wire        zrom_req;
    wire [23:0] zrom_addr;
    reg  [15:0] zrom_data = 16'hffff;
    reg         zrom_ack = 1'b0;

    wire        mpcm_req;
    wire [21:0] mpcm_addr;
    reg  [7:0]  mpcm_data = 8'h00;
    reg         mpcm_ack = 1'b0;

    wire signed [15:0] audio_l, audio_r;

    reg [15:0] rom [0:2097151];   // soundcpu region, 4 MiB
    reg [15:0] pcm [0:2097151];   // MultiPCM sample region, 4 MiB
    string rom_path, pcm_path;

    // Doorbell from the V60 side: the real board's main CPU pokes the sound
    // command port every frame.  Drive it at the 60 Hz vblank cadence so the
    // Z80's command loop and IRQ path are exercised, not just its init code.
    reg v60_doorbell = 1'b0;
    integer doorbell_div = 0;

    // +define+S32_SOUND_MULTI32_PRUNED compiles the dedicated OutRunners audio
    // subsystem (RF5C68 and the second YM3438 removed structurally) so the
    // release configuration is exercised, not just the generic one.
`ifdef S32_SOUND_MULTI32_PRUNED
    localparam M32_ONLY = 1'b1;
`else
    localparam M32_ONLY = 1'b0;
`endif

    s32_soundsys #(.SYSTEM32_ONLY(1'b0), .MULTI32_ONLY(M32_ONLY)) dut (
        .clk(clk), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
        .rst(rst), .z80_reset(z80_reset), .is_multi32(1'b1),
        .sh_cs(1'b0), .sh_we(1'b0), .sh_addr(12'd0), .sh_be(2'd0), .sh_wdata(16'd0),
        .sh_rdata(), .v60_doorbell(v60_doorbell), .irq_to_v60(),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(mpcm_req), .mpcm_addr(mpcm_addr),
        .mpcm_data(mpcm_data), .mpcm_ack(mpcm_ack),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    // One-cycle SDRAM responses with the same word/byte contract as s32_core:
    // p3 hands back 16-bit words, p4 is byte-addressed into the same packing.
    always @(posedge clk) begin
        zrom_ack <= zrom_req;
        if (zrom_req) zrom_data <= rom[zrom_addr[22:1]];
        mpcm_ack <= mpcm_req;
        if (mpcm_req)
            mpcm_data <= mpcm_addr[0] ? pcm[mpcm_addr[21:1]][15:8]
                                      : pcm[mpcm_addr[21:1]][7:0];
    end

    // 60 Hz doorbell (48.317307 MHz / 60 = 805288 clocks)
    always @(posedge clk) begin
        v60_doorbell <= 1'b0;
        if (rst || z80_reset) doorbell_div <= 0;
        else if (doorbell_div == 805287) begin
            doorbell_div <= 0;
            v60_doorbell <= 1'b1;
        end
        else doorbell_div <= doorbell_div + 1;
    end

    integer cycles = 0;
    integer rom_reqs = 0;
    integer opcode_fetches = 0;
    integer fixed_fetches = 0;
    integer banked_fetches = 0;
    integer bank_lo_writes = 0;
    integer mpcm_bank_writes = 0;
    integer fm1_writes = 0;
    integer fm2_writes = 0;      // must stay 0: Multi 32 has no second YM3438
    integer mpcm_writes = 0;
    integer mpcm_rom_reqs = 0;
    integer shared_reads = 0;
    integer irq_ctl_writes = 0;
    integer x_audio = 0;
    integer x_fm1 = 0;
    integer x_mp = 0;
    integer run_cycles = 5000000;
    reg zrom_req_d = 1'b0;
    reg mpcm_req_d = 1'b0;

    always @(posedge clk) if (!rst && !z80_reset) begin
        cycles <= cycles + 1;
        zrom_req_d <= zrom_req;
        mpcm_req_d <= mpcm_req;
        if (zrom_req && !zrom_req_d) begin
            rom_reqs <= rom_reqs + 1;
            if (zrom_addr < 24'ha000) fixed_fetches <= fixed_fetches + 1;
            else banked_fetches <= banked_fetches + 1;
        end
        if (mpcm_req && !mpcm_req_d) mpcm_rom_reqs <= mpcm_rom_reqs + 1;
        if (!dut.z_m1_n && !dut.z_mreq_n) opcode_fetches <= opcode_fetches + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'ha) bank_lo_writes <= bank_lo_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'hb) mpcm_bank_writes <= mpcm_bank_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'h8) fm1_writes <= fm1_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'h9) fm2_writes <= fm2_writes + 1;
        if (dut.z_mem_wr && dut.pcm_cs) mpcm_writes <= mpcm_writes + 1;
        if (dut.z_mem_rd && dut.z_addr[15:13] == 3'b111) shared_reads <= shared_reads + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'hd) irq_ctl_writes <= irq_ctl_writes + 1;
        if (^{audio_l, audio_r} === 1'bx) x_audio <= x_audio + 1;
        if (^{dut.fm1_l, dut.fm1_r} === 1'bx) x_fm1 <= x_fm1 + 1;
        if (^{dut.mp_l, dut.mp_r} === 1'bx) x_mp <= x_mp + 1;
    end

    initial begin
        if (!$value$plusargs("ROM=%s", rom_path))
            $fatal(1, "SOUNDSYS MULTI32 missing +ROM=<soundcpu.hex>");
        if (!$value$plusargs("PCM=%s", pcm_path))
            $fatal(1, "SOUNDSYS MULTI32 missing +PCM=<multipcm.hex>");
        if (!$value$plusargs("CYCLES=%d", run_cycles))
            run_cycles = 5000000;
        $readmemh(rom_path, rom);
        $readmemh(pcm_path, pcm);
        repeat (2048) @(posedge clk);
        rst = 1'b0;
        repeat (5000) @(posedge clk);
        $display("SOUNDSYS MULTI32 prerelease audio=%h/%h fm=%h/%h mp=%h/%h",
                 audio_l, audio_r, dut.fm1_l, dut.fm1_r, dut.mp_l, dut.mp_r);
        z80_reset = 1'b0;
        repeat (run_cycles) @(posedge clk);

        $display("SOUNDSYS MULTI32 activity cycles=%0d rom=%0d opcodes=%0d fixed=%0d banked=%0d bank=%03x",
                 cycles, rom_reqs, opcode_fetches, fixed_fetches,
                 banked_fetches, dut.sound_bank);
        $display("SOUNDSYS MULTI32 writes banklo=%0d mpcmbank=%0d(lo=%0d hi=%0d) fm1=%0d fm2=%0d mpcm=%0d mpcmrom=%0d irqctl=%0d sharedrd=%0d audio=%0d/%0d x=%0d/%0d/%0d",
                 bank_lo_writes, mpcm_bank_writes, dut.mpcm_bank_lo, dut.mpcm_bank_hi,
                 fm1_writes, fm2_writes, mpcm_writes, mpcm_rom_reqs,
                 irq_ctl_writes, shared_reads, audio_l, audio_r,
                 x_audio, x_fm1, x_mp);

        // Multi 32 has a single YM3438; port 0x90 is unmapped and any write
        // there would mean the System 32 second-FM path leaked into this build.
        if (fm2_writes != 0)
            $fatal(1, "SOUNDSYS MULTI32 wrote the System 32 second YM3438");
        if (rom_reqs < 100 || opcode_fetches < 100)
            $fatal(1, "SOUNDSYS MULTI32 Z80 did not run from the sound ROM");
        if (fm1_writes < 100)
            $fatal(1, "SOUNDSYS MULTI32 did not initialise the YM3438");
        if (mpcm_writes < 100)
            $fatal(1, "SOUNDSYS MULTI32 did not program the MultiPCM at 0xC000-0xDFFF");
        if (x_audio != 0 || x_fm1 != 0 || x_mp != 0)
            $fatal(1, "SOUNDSYS MULTI32 produced X on an audio output");
        $display("SOUNDSYS MULTI32 PASS");
        $finish;
    end

    initial begin
        #150000000;
        $fatal(1, "SOUNDSYS MULTI32 timeout");
    end
endmodule
