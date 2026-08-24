`timescale 1ns/1ps

// Production-T80 real-ROM integration probe. The copyrighted image is passed
// at runtime and remains under ignored roms/. This bench observes only bus
// activity and subsystem state; it never writes ROM contents to an artifact.
module tb_soundsys_realrom #(
    parameter integer ZROM_CACHE_SETS = 4
);
    reg clk = 1'b0;
    always #10.345 clk = ~clk; // 48.317 MHz, matching the generated 48.317307 MHz PLL output

    reg rst = 1'b1;
    reg z80_reset = 1'b1;
    reg [31:0] acc_z80 = 32'd0;
    reg [31:0] acc_fm = 32'd0;
    reg [31:0] acc_pcm = 32'd0;
    reg ce_z80 = 1'b0;
    reg ce_fm = 1'b0;
    reg ce_pcm = 1'b0;

    always @(posedge clk) begin
        logic [32:0] sum;
        if (rst) begin
            acc_z80 <= 32'd0;
            acc_pcm <= 32'd0;
            ce_z80  <= 1'b0;
            ce_pcm  <= 1'b0;
        end
        else begin
            sum = {1'b0,acc_z80} + 33'd715924818;
            ce_z80 <= sum[32];
            acc_z80 <= sum[31:0];
            sum = {1'b0,acc_pcm} + 33'd1111135834;
            ce_pcm <= sum[32];
            acc_pcm <= sum[31:0];
        end
    end


    // Production FM NCO is deliberately free-running during reset so JT12's
    // enabled-clock reset rings are actually flushed.
    always @(posedge clk) begin
        logic [32:0] sum;
        sum = {1'b0,acc_fm} + 33'd715924818;
        ce_fm <= sum[32];
        acc_fm <= sum[31:0];
    end

    wire        zrom_req;
    wire [23:0] zrom_addr;
    reg  [15:0] zrom_data = 16'hffff;
    reg         zrom_ack = 1'b0;
    wire signed [15:0] audio_l, audio_r;

    // System 32 sound ROM region: 4 MiB, exposed as little-endian words by
    // the production SDRAM port. make_sim_images.py emits this exact format.
    reg [15:0] rom [0:2097151];
    string rom_path;

    s32_soundsys #(
        .SYSTEM32_ONLY(1'b1),
        .ZROM_CACHE_SETS(ZROM_CACHE_SETS)
    ) dut (
        .clk(clk), .ce_z80(ce_z80), .ce_fm(ce_fm), .ce_pcm(ce_pcm),
        .rst(rst), .z80_reset(z80_reset), .is_multi32(1'b0),
        .sh_cs(1'b0), .sh_we(1'b0), .sh_addr(12'd0), .sh_be(2'd0), .sh_wdata(16'd0),
        .sh_rdata(), .v60_doorbell(1'b0), .irq_to_v60(),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(), .mpcm_addr(), .mpcm_data(8'd0), .mpcm_ack(1'b0),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    // One-cycle SDRAM response with the same word/byte contract as s32_core.
    always @(posedge clk) begin
        zrom_ack <= zrom_req;
        if (zrom_req)
            zrom_data <= rom[zrom_addr[22:1]];
    end

    integer cycles = 0;
    integer rom_reqs = 0;
    integer opcode_fetches = 0;
    integer fixed_fetches = 0;
    integer banked_fetches = 0;
    integer bank_lo_writes = 0;
    integer bank_hi_writes = 0;
    integer fm1_writes = 0;
    integer fm2_writes = 0;
    integer rf_reg_writes = 0;
    integer rf_ram_writes = 0;
    integer shared_reads = 0;
    integer irq_ctl_writes = 0;
    integer x_audio = 0;
    integer x_fm1 = 0;
    integer x_fm2 = 0;
    integer x_rf = 0;
    integer first_audio_x = -1;
    integer run_cycles = 5000000;
    reg zrom_req_d = 1'b0;

    always @(posedge clk) if (!rst && !z80_reset) begin
        cycles <= cycles + 1;
        zrom_req_d <= zrom_req;
        if (zrom_req && !zrom_req_d) begin
            rom_reqs <= rom_reqs + 1;
            if (zrom_addr < 24'ha000) fixed_fetches <= fixed_fetches + 1;
            else banked_fetches <= banked_fetches + 1;
        end
        if (!dut.z_m1_n && !dut.z_mreq_n) opcode_fetches <= opcode_fetches + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'ha) bank_lo_writes <= bank_lo_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'hb) bank_hi_writes <= bank_hi_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'h8) fm1_writes <= fm1_writes + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'h9) fm2_writes <= fm2_writes + 1;
        if (dut.z_mem_wr && dut.pcm_cs && !dut.z_addr[12]) rf_reg_writes <= rf_reg_writes + 1;
        if (dut.z_mem_wr && dut.pcm_cs &&  dut.z_addr[12]) rf_ram_writes <= rf_ram_writes + 1;
        if (dut.z_mem_rd && dut.z_addr[15:13] == 3'b111) shared_reads <= shared_reads + 1;
        if (dut.z_io_wr && dut.z_addr[7:4] == 4'hd) irq_ctl_writes <= irq_ctl_writes + 1;
        if (^{audio_l, audio_r} === 1'bx) x_audio <= x_audio + 1;
        if (^{dut.fm1_l, dut.fm1_r} === 1'bx) x_fm1 <= x_fm1 + 1;
        if (^{dut.fm2_l, dut.fm2_r} === 1'bx) x_fm2 <= x_fm2 + 1;
        if (^{dut.rf_l, dut.rf_r} === 1'bx) x_rf <= x_rf + 1;
        if (first_audio_x < 0 && ^{audio_l, audio_r} === 1'bx) begin
            first_audio_x <= cycles;
            $display("SOUNDSYS REALROM first audio X cycle=%0d bus_addr=%04x io_wr=%b port=%02x data=%02x fm=%h/%h %h/%h rf=%h/%h",
                     cycles, dut.z_addr, dut.z_io_wr,
                     dut.z_addr[7:0], dut.z_dout, dut.fm1_l, dut.fm1_r,
                     dut.fm2_l, dut.fm2_r, dut.rf_l, dut.rf_r);
        end
    end

    initial begin
        if (!$value$plusargs("ROM=%s", rom_path))
            $fatal(1, "SOUNDSYS REALROM missing +ROM=<soundcpu.hex>");
        if (!$value$plusargs("CYCLES=%d", run_cycles))
            run_cycles = 5000000;
        $readmemh(rom_path, rom);
        // The 24-stage jt12 operator/envelope rings advance on its internal
        // /6 enable.  The board naturally supplies a much longer ROM-load
        // reset; 2048 system clocks fully flush every ring in simulation.
        repeat (2048) @(posedge clk);
        rst = 1'b0;
        // On the board, I/O-chip CNT2 holds the T80 while the V60 completes
        // initialization.  The full-core Holo trace shows release after one
        // frame; 5000 clocks are already enough for both JT12 outputs to
        // capture known post-reset samples in this focused bench.
        repeat (5000) @(posedge clk);
        $display("SOUNDSYS REALROM prerelease audio=%h/%h fm=%h/%h %h/%h rf=%h/%h",
                 audio_l, audio_r, dut.fm1_l, dut.fm1_r,
                 dut.fm2_l, dut.fm2_r, dut.rf_l, dut.rf_r);
        z80_reset = 1'b0;
        repeat (run_cycles) @(posedge clk);

        $display("SOUNDSYS REALROM activity cycles=%0d rom=%0d opcodes=%0d fixed=%0d banked=%0d bank=%03x",
                 cycles, rom_reqs, opcode_fetches, fixed_fetches,
                 banked_fetches, dut.sound_bank);
        $display("SOUNDSYS REALROM writes bank=%0d/%0d fm=%0d/%0d rfreg=%0d rfram=%0d irqctl=%0d sharedrd=%0d audio=%0d/%0d x=%0d fm1x=%0d fm2x=%0d rfx=%0d",
                 bank_lo_writes, bank_hi_writes, fm1_writes, fm2_writes,
                 rf_reg_writes, rf_ram_writes, irq_ctl_writes, shared_reads,
                 audio_l, audio_r, x_audio, x_fm1, x_fm2, x_rf);

        if (rom_reqs < 100 || opcode_fetches < 100 ||
            fm1_writes < 100 || fm2_writes < 100 ||
            rf_reg_writes < 16 || rf_ram_writes < 4096 ||
            shared_reads < 100 || x_audio != 0 || x_fm1 != 0 ||
            x_fm2 != 0 || x_rf != 0)
            $fatal(1, "SOUNDSYS REALROM did not complete Holo sound initialization");
        $display("SOUNDSYS REALROM PASS");
        $finish;
    end

    initial begin
        #150000000;
        $fatal(1, "SOUNDSYS REALROM timeout");
    end
endmodule
