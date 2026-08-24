`timescale 1ns/1ps

// Direct bus-contract regression for the System 32 sound glue.  The production
// T80 is stubbed and its pins are driven here so banking, wait/ack, interrupt,
// and CNT2 reset behavior can be checked independently of instruction timing.
module tb_soundsys_bus;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg z80_reset = 1'b0;
    reg is_multi32 = 1'b0;
    reg v60_doorbell = 1'b0;
    reg [15:0] bus_addr = 16'h0000;
    reg [7:0] bus_dout = 8'h00;
    reg mreq_n = 1'b1, iorq_n = 1'b1, rd_n = 1'b1;
    reg wr_n = 1'b1, m1_n = 1'b1;
    reg [15:0] zrom_data = 16'h0000;
    reg zrom_ack = 1'b0;
    wire zrom_req;
    wire [23:0] zrom_addr;
    wire irq_to_v60;
    wire signed [15:0] audio_l, audio_r;

    s32_soundsys #(.SYSTEM32_ONLY(1'b1)) dut (
        .clk(clk), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0),
        .rst(rst), .z80_reset(z80_reset), .is_multi32(is_multi32),
        .sh_cs(1'b0), .sh_we(1'b0), .sh_addr(12'd0), .sh_be(2'd0), .sh_wdata(16'd0),
        .sh_rdata(), .v60_doorbell(v60_doorbell), .irq_to_v60(irq_to_v60),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(), .mpcm_addr(), .mpcm_data(8'd0), .mpcm_ack(1'b0),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    task automatic idle_bus;
        begin
            mreq_n = 1'b1; iorq_n = 1'b1; rd_n = 1'b1;
            wr_n = 1'b1; m1_n = 1'b1;
        end
    endtask

    task automatic io_write(input [7:0] port, input [7:0] data);
        begin
            bus_addr = {8'h00, port}; bus_dout = data;
            iorq_n = 1'b0; wr_n = 1'b0; m1_n = 1'b1;
            @(posedge clk); #1;
            idle_bus();
            @(posedge clk); #1;
        end
    endtask

    task automatic io_read_check(input [7:0] port, input [7:0] expected);
        begin
            bus_addr = {8'h00, port};
            iorq_n = 1'b0; rd_n = 1'b0; m1_n = 1'b1;
            #1;
            if (dut.z_din !== expected)
                $fatal(1, "port %02x read %02x, expected %02x",
                       port, dut.z_din, expected);
            idle_bus();
            @(posedge clk); #1;
        end
    endtask

    initial begin
        force dut.z_addr   = bus_addr;
        force dut.z_dout   = bus_dout;
        force dut.z_mreq_n = mreq_n;
        force dut.z_iorq_n = iorq_n;
        force dut.z_rd_n   = rd_n;
        force dut.z_wr_n   = wr_n;
        force dut.z_m1_n   = m1_n;

        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;
        if (dut.sound_bank !== 9'd0 || dut.mpcm_bank_lo !== 3'd0 ||
            dut.mpcm_bank_hi !== 3'd0 || dut.snd_irq_mask !== 8'h00 ||
            dut.snd_irq_ctl[0] !== 8'h00 || dut.snd_irq_ctl[1] !== 8'h00 ||
            dut.snd_irq_ctl[2] !== 8'h00)
            $fatal(1, "sound controller reset state does not match MAME");

        // MAME sound_bank_lo_w / sound_bank_hi_w: low=2a, high data=05
        // produces bank 0ea (D2->B6, D0->B7, D1->B8).
        io_write(8'ha0, 8'h2a);
        io_write(8'hb0, 8'h05);
        if (dut.sound_bank !== 9'h0ea)
            $fatal(1, "sound ROM bank permutation wrong: %03x", dut.sound_bank);

        // F1 is a stateful board latch in MAME, not a constant-zero dummy.
        io_write(8'hf1, 8'h5a);
        io_read_check(8'hf1, 8'h5a);

        // D0-D3 mirror at D4-D7 only.  The upper half of the D-page is
        // unmapped and must not silently change interrupt routing.
        io_write(8'hd0, 8'h01);
        io_write(8'hd8, 8'h55);
        if (dut.snd_irq_ctl[0] !== 8'h01)
            $fatal(1, "unmapped D8 port aliased D0 interrupt control");

        // A123 in bank EA maps to byte 1d4123.  The request is word aligned,
        // WAIT remains asserted through arbitrary SDRAM delay, and odd-byte
        // selection returns the high lane only after ACK.
        bus_addr = 16'ha123; mreq_n = 1'b0; rd_n = 1'b0;
        @(posedge clk); #1;
        if (!zrom_req || zrom_addr !== 24'h1d4122 || dut.z_wait_n !== 1'b0)
            $fatal(1, "banked ROM request/wait mismatch req=%b addr=%06x wait=%b",
                   zrom_req, zrom_addr, dut.z_wait_n);
        repeat (4) begin
            @(posedge clk); #1;
            if (!zrom_req || dut.z_wait_n !== 1'b0)
                $fatal(1, "ROM request was not held until delayed ACK");
        end
        zrom_data = 16'hbbaa; zrom_ack = 1'b1;
        @(posedge clk); #1; zrom_ack = 1'b0;
        if (zrom_req || dut.z_wait_n !== 1'b1 || dut.z_din !== 8'hbb)
            $fatal(1, "ROM ACK/cache/byte-select mismatch din=%02x", dut.z_din);
        idle_bus();
        @(posedge clk); #1;

        // Slot 0 receives V60 source 1; doorbell asserts vector 0 and C1's
        // ack-AND semantics clear it.  C4 signals the main CPU.
        io_write(8'hd0, 8'h01);
        v60_doorbell = 1'b1; @(posedge clk); #1;
        v60_doorbell = 1'b0; @(posedge clk); #1;
        if (dut.z_int_n !== 1'b0 || dut.int_vector !== 8'h00)
            $fatal(1, "V60 doorbell did not assert Z80 vector 0");
        io_write(8'hc1, 8'h00);
        if (dut.z_int_n !== 1'b1)
            $fatal(1, "sound IRQ ack-AND did not clear pending vector");

        // A fresh source on the same edge as an ACK is not stale state and
        // must survive.  This guards the merged pending-bit next-state logic.
        bus_addr = 16'h00c1; bus_dout = 8'h00;
        iorq_n = 1'b0; wr_n = 1'b0; m1_n = 1'b1;
        v60_doorbell = 1'b1;
        @(posedge clk); #1;
        idle_bus(); v60_doorbell = 1'b0;
        @(posedge clk); #1;
        if (dut.z_int_n !== 1'b0)
            $fatal(1, "simultaneous sound IRQ source was lost to ACK");
        io_write(8'hc1, 8'h00);

        bus_addr = 16'h00c4; bus_dout = 8'h00;
        iorq_n = 1'b0; wr_n = 1'b0; m1_n = 1'b1;
        @(posedge clk); #1;
        if (!irq_to_v60) $fatal(1, "C4 did not signal main-CPU sound IRQ");
        idle_bus(); @(posedge clk); #1;
        if (irq_to_v60) $fatal(1, "main-CPU sound IRQ request did not pulse");

        // CNT2 resets the T80 only in MAME.  External banks, IRQ controller,
        // and sound chips must retain their programmed state.
        io_write(8'hd0, 8'h02);
        is_multi32 = 1'b1;
        io_read_check(8'h90, 8'hff);
        io_write(8'hb0, 8'h35);
        z80_reset = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        if (dut.sound_bank !== 9'h0ea || dut.snd_irq_ctl[0] !== 8'h02 ||
            dut.mpcm_bank_lo !== 3'h5 || dut.mpcm_bank_hi !== 3'h6)
            $fatal(1, "CNT2 incorrectly reset external sound state");

        $display("SOUNDSYS BUS PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "SOUNDSYS BUS timeout");
    end
endmodule
