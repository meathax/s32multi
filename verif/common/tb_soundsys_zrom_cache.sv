`timescale 1ns/1ps

// Demand-only sound-ROM cache throughput regression.  This drives the sound
// bus directly so it is ROM-independent and checks both locality shapes that
// matter to the production T80:
//   * a hot opcode word alternating with a forward data stream (LDIR-like),
//   * a four-word loop interleaved with four same-index banked data words.
// The first requires per-set LRU; the second distinguishes the old one-set,
// two-word capacity from the production four-set/two-way cache.
module tb_soundsys_zrom_cache #(
    parameter integer ZROM_CACHE_SETS = 4
);
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg [15:0] bus_addr = 16'h0000;
    reg [7:0] bus_dout = 8'h00;
    reg mreq_n = 1'b1, iorq_n = 1'b1, rd_n = 1'b1;
    reg wr_n = 1'b1, m1_n = 1'b1;
    reg [15:0] zrom_data = 16'h0000;
    reg zrom_ack = 1'b0;
    wire zrom_req;
    wire [23:0] zrom_addr;

    integer req_count = 0;
    integer cycle_count = 0;
    integer ack_delay = 0;
    integer ack_hold = 0;
    integer ldir_requests;
    integer conflict_requests;
    integer conflict_cycles;
    reg req_d = 1'b0;
    reg [23:0] pending_addr = 24'd0;

    s32_soundsys #(
        .SYSTEM32_ONLY(1'b1),
        .ZROM_CACHE_SETS(ZROM_CACHE_SETS)
    ) dut (
        .clk(clk), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0),
        .rst(rst), .z80_reset(1'b0), .is_multi32(1'b0),
        .sh_cs(1'b0), .sh_we(1'b0), .sh_addr(12'd0), .sh_be(2'd0),
        .sh_wdata(16'd0), .sh_rdata(),
        .v60_doorbell(1'b0), .irq_to_v60(),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(), .mpcm_addr(), .mpcm_data(8'd0), .mpcm_ack(1'b0),
        .audio_l(), .audio_r()
    );

    function automatic [7:0] rom_byte(input [23:0] addr);
        rom_byte = addr[7:0] ^ addr[15:8] ^ addr[23:16] ^ 8'ha5;
    endfunction

    function automatic [23:0] mapped_addr(input [15:0] addr);
        if (addr < 16'ha000)
            mapped_addr = {8'b0, addr};
        else
            mapped_addr = {2'b0, 9'h001, addr[12:0]};
    endfunction

    // A two-clock demand response with ACK deliberately held for three clock
    // edges.  This is longer than the production controller's nominal pulse
    // and proves that a stretched completion cannot fill twice or be consumed
    // as the response to a newly launched miss.  Request edges, rather than
    // ACK levels, are the throughput metric.
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (ack_hold > 0) begin
            zrom_ack <= 1'b1;
            ack_hold <= ack_hold - 1;
        end
        else begin
            zrom_ack <= 1'b0;
        end
        req_d <= zrom_req;
        if (zrom_req && !req_d) begin
            req_count <= req_count + 1;
            pending_addr <= zrom_addr;
            ack_delay <= 2;
        end
        else if (ack_delay > 1) begin
            ack_delay <= ack_delay - 1;
        end
        else if (ack_delay == 1) begin
            zrom_data <= {rom_byte(pending_addr + 24'd1), rom_byte(pending_addr)};
            zrom_ack <= 1'b1;
            ack_hold <= 2;
            ack_delay <= 0;
        end
    end

    task automatic idle_bus;
        begin
            mreq_n = 1'b1; iorq_n = 1'b1; rd_n = 1'b1;
            wr_n = 1'b1; m1_n = 1'b1;
        end
    endtask

    task automatic set_bank_one;
        begin
            @(negedge clk);
            bus_addr = 16'h00a0;
            bus_dout = 8'h01;
            iorq_n = 1'b0; wr_n = 1'b0; m1_n = 1'b1;
            @(posedge clk); #1;
            idle_bus();
            @(posedge clk); #1;
            if (dut.sound_bank !== 9'h001)
                $fatal(1, "sound bank setup failed: %03x", dut.sound_bank);
        end
    endtask

    task automatic reset_cache;
        begin
            @(negedge clk);
            idle_bus();
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            repeat (2) @(posedge clk);
            set_bank_one();
            req_count = 0;
        end
    endtask

    task automatic read_rom(input [15:0] addr);
        reg [23:0] physical;
        reg [7:0] expected;
        integer timeout;
        begin
            physical = mapped_addr(addr);
            expected = rom_byte(physical);
            @(negedge clk);
            bus_addr = addr;
            mreq_n = 1'b0; rd_n = 1'b0;
            #1; // allow forced T80 pins and combinational hit logic to settle
            timeout = 0;
            while (!dut.z_wait_n && timeout < 100) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            if (timeout >= 100)
                $fatal(1, "ROM read timed out at %04x", addr);
            if (dut.z_din !== expected)
                $fatal(1, "ROM data mismatch at %04x: got %02x expected %02x",
                       addr, dut.z_din, expected);
            @(negedge clk);
            idle_bus();
            @(posedge clk); #1;
        end
    endtask

    integer i, j;
    integer phase_start;
    initial begin
        force dut.z_addr   = bus_addr;
        force dut.z_dout   = bus_dout;
        force dut.z_mreq_n = mreq_n;
        force dut.z_iorq_n = iorq_n;
        force dut.z_rd_n   = rd_n;
        force dut.z_wr_n   = wr_n;
        force dut.z_m1_n   = m1_n;

        // One fixed opcode word remains hot while 32 banked data words stream.
        // Demand traffic is exactly one opcode fill plus one fill per source
        // word in both supported cache configurations.
        reset_cache();
        for (i = 0; i < 32; i = i + 1) begin
            read_rom(16'h0100);
            read_rom(16'ha000 + (i << 1));
        end
        ldir_requests = req_count;
        if (ldir_requests != 33)
            $fatal(1, "LDIR-like demand count=%0d expected=33", ldir_requests);

        // Four fixed words and four banked words form four address-index pairs.
        // Four sets retain all eight after warm-up; the one-set A/B baseline
        // has only two ways and therefore misses on all 160 accesses.
        reset_cache();
        phase_start = cycle_count;
        for (j = 0; j < 20; j = j + 1)
            for (i = 0; i < 4; i = i + 1) begin
                read_rom(16'h0200 + (i << 1));
                read_rom(16'ha100 + (i << 1));
            end
        conflict_requests = req_count;
        conflict_cycles = cycle_count - phase_start;

        if (ZROM_CACHE_SETS == 1 && conflict_requests != 160)
            $fatal(1, "one-set conflict count=%0d expected=160", conflict_requests);
        if (ZROM_CACHE_SETS == 4 && conflict_requests != 8)
            $fatal(1, "four-set conflict count=%0d expected=8", conflict_requests);
        if (ZROM_CACHE_SETS != 1 && ZROM_CACHE_SETS != 4)
            $fatal(1, "test supports only ZROM_CACHE_SETS=1 or 4");

        $display("SOUNDSYS ZROM CACHE sets=%0d ldir_requests=%0d conflict_requests=%0d conflict_cycles=%0d",
                 ZROM_CACHE_SETS, ldir_requests, conflict_requests, conflict_cycles);
        $display("SOUNDSYS ZROM CACHE PASS");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "SOUNDSYS ZROM CACHE timeout");
    end
endmodule
