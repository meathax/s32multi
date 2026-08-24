`timescale 1ns/1ps

// Directed V60<->Z80 shared-RAM byte-packing test (audit R20 IO-1 / AU-1, and
// the missing coverage AU-9).  The seam was previously untested: every other
// soundsys bench ties sh_cs=0.  MAME maps the Z80's 0xE000-0xFFFF onto the V60's
// 0x700000 window byte-for-byte on both lanes, so V60 byte k == Z80 0xE000+k.
//
// The test proves the full round trip through both byte lanes:
//   1. The V60 port seeds 8 KB-window words 0..0x0F (Z80 bytes 0xE000..0xE01F).
//   2. A real T80 copies each byte, complemented, to 0xE020..0xE03F, then writes
//      a sentinel at 0xE0FF.
//   3. The V60 port reads words 0x10..0x1F back and checks the complement.
// A pass requires the Z80 to have read the correct byte at every even AND odd
// address (proving V60->Z80 both lanes) and the V60 to read back the Z80's
// result at the correct even AND odd lanes (proving Z80->V60 both lanes).
module tb_soundsys_shared;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    wire        zrom_req;
    wire [23:0] zrom_addr;
    reg  [15:0] zrom_data = 16'h0000;
    reg         zrom_ack  = 1'b0;
    wire signed [15:0] audio_l, audio_r;
    wire        wave_rd_req, wave_rd_ack;
    wire [15:0] wave_rd_addr, wave_rd_data;
    wire        wave_wr_req, wave_wr_ack;
    wire [15:0] wave_wr_addr;
    wire  [7:0] wave_wr_data;

    // V60 side of the shared RAM
    reg         sh_cs   = 1'b0;
    reg         sh_we   = 1'b0;
    reg  [11:0] sh_addr = 12'd0;
    reg  [1:0]  sh_be   = 2'b00;
    reg  [15:0] sh_wdata = 16'd0;
    wire [15:0] sh_rdata;

    reg [7:0] rom [0:65535];
    integer i;
    integer timeout;
    reg [7:0] seed [0:31];
    reg [15:0] got;

    s32_soundsys #(.SYSTEM32_ONLY(1'b1)) dut (
        .clk(clk), .ce_z80(1'b1), .ce_fm(1'b0), .ce_pcm(1'b1),
        .rst(rst), .z80_reset(1'b0), .is_multi32(1'b0),
        .sh_cs(sh_cs), .sh_we(sh_we), .sh_addr(sh_addr), .sh_be(sh_be),
        .sh_wdata(sh_wdata), .sh_rdata(sh_rdata),
        .v60_doorbell(1'b0), .irq_to_v60(),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr),
        .zrom_data(zrom_data), .zrom_ack(zrom_ack),
        .mpcm_req(), .mpcm_addr(), .mpcm_data(8'd0), .mpcm_ack(1'b0),
        .wave_rd_req(wave_rd_req), .wave_rd_addr(wave_rd_addr),
        .wave_rd_data(wave_rd_data), .wave_rd_ack(wave_rd_ack),
        .wave_wr_req(wave_wr_req), .wave_wr_addr(wave_wr_addr),
        .wave_wr_data(wave_wr_data), .wave_wr_ack(wave_wr_ack),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    s32_wave_ram_model wave_mem (
        .clk(clk),
        .rd_req(wave_rd_req), .rd_addr(wave_rd_addr),
        .rd_data(wave_rd_data), .rd_ack(wave_rd_ack),
        .wr_req(wave_wr_req), .wr_addr(wave_wr_addr),
        .wr_data(wave_wr_data), .wr_ack(wave_wr_ack)
    );

    // One-cycle SDRAM response for Z80 program fetches.
    always @(posedge clk) begin
        zrom_ack <= zrom_req;
        if (zrom_req)
            zrom_data <= {rom[zrom_addr + 1'b1], rom[zrom_addr]};
    end

    // Drive one 16-bit V60 write to the shared window.
    task v60_write(input [11:0] a, input [1:0] be, input [15:0] d);
        begin
            @(negedge clk);
            sh_cs = 1'b1; sh_we = 1'b1; sh_addr = a; sh_be = be; sh_wdata = d;
            @(posedge clk);
            @(negedge clk);
            sh_cs = 1'b0; sh_we = 1'b0; sh_be = 2'b00;
        end
    endtask

    // Registered V60 read of one shared-window word.
    task v60_read(input [11:0] a, output [15:0] d);
        begin
            @(negedge clk);
            sh_cs = 1'b1; sh_we = 1'b0; sh_addr = a;
            @(posedge clk);          // address registered into q_a
            @(posedge clk);          // q_a now reflects mem[a]
            d = sh_rdata;
            @(negedge clk);
            sh_cs = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) rom[i] = 8'h00;

        // Z80 program: complement-copy 0xE000..0xE01F -> 0xE020..0xE03F,
        // then write sentinel 0xA5 at 0xE0FF and spin.
        rom[16'h0000]=8'h21; rom[16'h0001]=8'h00; rom[16'h0002]=8'he0; // LD HL,E000
        rom[16'h0003]=8'h11; rom[16'h0004]=8'h20; rom[16'h0005]=8'he0; // LD DE,E020
        rom[16'h0006]=8'h06; rom[16'h0007]=8'h20;                      // LD B,20
        rom[16'h0008]=8'h7e;                                           // LD A,(HL)
        rom[16'h0009]=8'h2f;                                           // CPL
        rom[16'h000a]=8'h12;                                           // LD (DE),A
        rom[16'h000b]=8'h23;                                           // INC HL
        rom[16'h000c]=8'h13;                                           // INC DE
        rom[16'h000d]=8'h10; rom[16'h000e]=8'hf9;                      // DJNZ -7 -> 0008
        rom[16'h000f]=8'h3e; rom[16'h0010]=8'ha5;                      // LD A,A5
        rom[16'h0011]=8'h32; rom[16'h0012]=8'hff; rom[16'h0013]=8'he0; // LD (E0FF),A
        rom[16'h0014]=8'hc3; rom[16'h0015]=8'h14; rom[16'h0016]=8'h00; // JP 0014

        // Seed pattern with distinct even/odd lane values.
        for (i = 0; i < 32; i = i + 1) seed[i] = (i * 7 + 8'h11) & 8'hff;

        // Seed via the V60 port while the Z80 is held in reset.  Word w holds
        // {byte 2w+1, byte 2w} = {Z80 0xE000+2w+1, Z80 0xE000+2w}.
        for (i = 0; i < 16; i = i + 1)
            v60_write(i[11:0], 2'b11, {seed[2*i+1], seed[2*i]});

        repeat (12) @(posedge clk);
        rst = 1'b0;

        // Wait for the Z80 sentinel at 0xE0FF (word 0x7F, high lane).
        timeout = 0;
        got = 16'h0000;
        while (got[15:8] !== 8'ha5 && timeout < 200000) begin
            v60_read(12'h07f, got);
            timeout = timeout + 1;
        end
        if (timeout >= 200000)
            $fatal(1, "Z80 never wrote the shared-RAM sentinel (0xE0FF)");

        // Verify the complement-copied block at 0xE020..0xE03F (words 0x10..0x1F).
        for (i = 0; i < 16; i = i + 1) begin
            v60_read(12'h010 + i[11:0], got);
            if (got[7:0] !== (~seed[2*i] & 8'hff))
                $fatal(1, "even-lane mismatch word %0d: got %02x exp %02x",
                       16 + i, got[7:0], ~seed[2*i] & 8'hff);
            if (got[15:8] !== (~seed[2*i+1] & 8'hff))
                $fatal(1, "odd-lane mismatch word %0d: got %02x exp %02x",
                       16 + i, got[15:8], ~seed[2*i+1] & 8'hff);
        end

        // Direct V60 single-lane write/read: prove byteena isolates each lane.
        v60_write(12'h100, 2'b11, 16'hBBAA);
        v60_read(12'h100, got);
        if (got !== 16'hBBAA) $fatal(1, "both-lane RW: got %04x exp BBAA", got);
        v60_write(12'h100, 2'b01, 16'h00CC);   // low lane only
        v60_read(12'h100, got);
        if (got !== 16'hBBCC) $fatal(1, "low-lane RW: got %04x exp BBCC", got);
        v60_write(12'h100, 2'b10, 16'hDD00);   // high lane only
        v60_read(12'h100, got);
        if (got !== 16'hDDCC) $fatal(1, "high-lane RW: got %04x exp DDCC", got);

        $display("SOUNDSYS SHARED PASS");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "SOUNDSYS SHARED timeout");
    end
endmodule
