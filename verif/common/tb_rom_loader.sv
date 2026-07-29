//============================================================================
// Directed test: s32_rom_loader
//   * synchronous reset leaves every externally-visible state deterministic
//   * EEPROM-only downloads never open the ROM boot gate
//   * index-0 start/end controls rom_loaded and waits for the final SDRAM ack
//   * all SDRAM region boundaries preserve little-endian byte pairing/mapping
//   * V25 writes use the inverse MAME permutation of the MCU-local source,
//     store through the correct external-SDRAM byte lane, and cover the real
//     GA2 reset-vector source address
//   * persisted index-3 EEPROM data loads as little-endian 16-bit words
//============================================================================
`timescale 1ns/1ps

module tb_rom_loader;

import s32_pkg::*;

reg clk = 1'b0;
reg rst = 1'b1;
reg mem_ready = 1'b0;
always #5 clk = ~clk;

reg         ioctl_download = 1'b0;
reg  [7:0]  ioctl_index = 8'd0;
reg         ioctl_wr = 1'b0;
reg  [26:0] ioctl_addr = 27'd0;
reg [15:0]  ioctl_dout = 16'd0;
wire        ioctl_wait;

wire board_desc_t board_desc;

wire        sdr_wr_req;
wire [26:1] sdr_wr_addr;
wire [15:0] sdr_wr_din;
wire  [1:0] sdr_wr_be;
reg         sdr_wr_ack = 1'b0;

wire        v25_wr;
wire [15:0] v25_waddr;
wire  [7:0] v25_wdata;

wire        eep_wr;
wire  [5:0] eep_waddr;
wire [15:0] eep_wdata;
wire        eep_loaded;
wire        rom_loaded;

s32_rom_loader dut (
    .clk(clk), .rst(rst),
    .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .board_desc(board_desc),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .v25_wr(v25_wr), .v25_waddr(v25_waddr), .v25_wdata(v25_wdata),
    .eep_wr(eep_wr), .eep_waddr(eep_waddr), .eep_wdata(eep_wdata),
    .eep_loaded(eep_loaded), .rom_loaded(rom_loaded)
);

localparam [26:0] OFF_MAINCPU  = 27'h0000040;
localparam [26:0] OFF_SOUNDCPU = 27'h0200040;
localparam [26:0] OFF_TILES    = 27'h0600040;
localparam [26:0] OFF_MULTIPCM = 27'h0A00040;
localparam [26:0] OFF_MCU      = 27'h0E00040;
localparam [26:0] OFF_SPRITES  = 27'h0E10040;
localparam [26:0] OFF_END      = 27'h1E10040;

integer errors = 0;

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL: %0s", name);
    end
end
endtask

// Change host inputs away from the active edge so the DUT sees an
// unambiguous, registered-style write pulse.
task automatic send_byte(
    input [7:0] index,
    input [26:0] address,
    input [7:0] data
);
begin
    @(negedge clk);
    ioctl_download = 1'b1;
    ioctl_index    = index;
    ioctl_addr     = address;
    ioctl_dout     = data;
    ioctl_wr       = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    ioctl_wr       = 1'b0;
end
endtask

task automatic send_sdr_pair(
    input [26:0] stream_even,
    input [7:0] lo,
    input [7:0] hi,
    input [23:0] expected_word
);
begin
    send_byte(8'd0, stream_even, lo);
    check(!sdr_wr_req && !ioctl_wait, "even SDR byte must only fill byte_lo");
    send_byte(8'd0, stream_even + 1'b1, hi);
    check(sdr_wr_req && ioctl_wait, "odd SDR byte must raise request/wait");
    check(sdr_wr_addr === expected_word, "SDRAM mapped word address");
    check(sdr_wr_din === {hi, lo}, "SDRAM stream is little-endian");
    check(sdr_wr_be === 2'b11, "SDRAM write enables both bytes");
end
endtask

task automatic ack_sdr;
begin
    // send_sdr_pair returns on a falling edge, so this ack is stable for the
    // complete next active edge.
    sdr_wr_ack = 1'b1;
    @(posedge clk);
    #1;
    check(!sdr_wr_req && !ioctl_wait, "SDRAM ack must release request/wait");
    @(negedge clk);
    sdr_wr_ack = 1'b0;
end
endtask

task automatic check_sdr_pair(
    input [26:0] stream_even,
    input [7:0] lo,
    input [7:0] hi,
    input [23:0] expected_word
);
begin
    send_sdr_pair(stream_even, lo, hi, expected_word);
    ack_sdr();
end
endtask

task automatic check_reset_state;
begin
    check(sdr_wr_req === 1'b0, "reset sdr_wr_req");
    check(sdr_wr_addr === 24'd0, "reset sdr_wr_addr");
    check(sdr_wr_din === 16'd0, "reset sdr_wr_din");
    check(sdr_wr_be === 2'd0, "reset sdr_wr_be");
    check(ioctl_wait === ~mem_ready, "reset ioctl_wait follows memory ready");
    check(v25_wr === 1'b0 && v25_waddr === 16'd0 && v25_wdata === 8'd0,
          "reset V25 write port");
    check(eep_wr === 1'b0 && eep_waddr === 6'd0 && eep_wdata === 16'd0,
          "reset EEPROM write port");
    check(eep_loaded === 1'b0, "reset eep_loaded");
    check(rom_loaded === 1'b0, "reset rom_loaded");
    check(board_desc === '0, "reset board descriptor");
end
endtask

initial begin
    // Reset must be deterministic both at power-up and after live activity.
    repeat (5) @(posedge clk);
    #1;
    check_reset_state();
    @(negedge clk);
    rst = 1'b0;
    // Traffic presented before SDRAM readiness is not accepted and the host
    // remains backpressured.
    ioctl_download = 1'b1;
    ioctl_index = 8'd0;
    ioctl_addr = 27'd0;
    ioctl_dout = 8'hde;
    ioctl_wr = 1'b1;
    repeat (2) @(posedge clk);
    #1;
    check(ioctl_wait && !sdr_wr_req && !rom_loaded && board_desc === '0,
          "pre-ready download has no side effects");
    @(negedge clk);
    ioctl_wr = 1'b0;
    ioctl_download = 1'b0;
    mem_ready = 1'b1;
    repeat (2) @(posedge clk);

    // Index 2 is a factory EEPROM image, not a program ROM download.  It may
    // mark the EEPROM initialized, but must never release the main boot gate.
    send_byte(8'd2, 27'd0, 8'h34);
    send_byte(8'd2, 27'd1, 8'h12);
    check(eep_wr && eep_waddr === 6'd0 && eep_wdata === 16'h1234,
          "index-2 EEPROM little-endian word");
    check(eep_loaded && !rom_loaded, "index 2 must not set rom_loaded");
    @(negedge clk);
    ioctl_download = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    check(!rom_loaded, "ending index 2 must not set rom_loaded");

    // A minimal index-0 transaction proves the explicit start/end gate.  Its
    // address-zero write also clears an earlier EEPROM-loaded indication.
    send_byte(8'd0, 27'd0, 8'hA5);
    check(!rom_loaded && !eep_loaded, "index-0 start clears boot/load gates");
    @(negedge clk);
    ioctl_download = 1'b0;
    @(posedge clk);
    #1;
    check(rom_loaded, "completed index-0 session sets rom_loaded");

    // Start a real mapped session.  Address zero must close an already-open
    // boot gate before any program bytes arrive.
    send_byte(8'd0, 27'd0, 8'hA5);
    check(!rom_loaded, "new index-0 start closes existing boot gate");

    // Populate/latch a nonzero descriptor so the final reset check also
    // proves descriptor state is deterministic.
    send_byte(8'd0, 27'd1, 8'h03);
    send_byte(8'd0, 27'd2, 8'h7F);
    send_byte(8'd0, 27'd3, 8'h81);
    send_byte(8'd0, 27'd63, 8'h00);
    check(board_desc !== '0, "descriptor became nonzero before final reset");
    check(board_desc.sprite_bank_valid &&
          board_desc.sprite_bank_mask === 2'b01,
          "descriptor sprite bank metadata");
    check(board_desc.flip_y === 1'b1, "descriptor vertical orientation");

    // First and last words of every SDRAM-backed region.  Distinct byte data
    // on each pair catches stale byte_lo and endian errors as well as mapping.
    check_sdr_pair(OFF_MAINCPU,      8'h10, 8'h11, 24'h000000);
    check_sdr_pair(OFF_SOUNDCPU-2,   8'h12, 8'h13, 24'h0FFFFF);
    check_sdr_pair(OFF_SOUNDCPU,     8'h20, 8'h21, 24'h100000);
    check_sdr_pair(OFF_TILES-2,      8'h22, 8'h23, 24'h2FFFFF);
    check_sdr_pair(OFF_TILES,        8'h30, 8'h31, 24'h300000);
    check_sdr_pair(OFF_MULTIPCM-2,   8'h32, 8'h33, 24'h4FFFFF);
    check_sdr_pair(OFF_MULTIPCM,     8'h40, 8'h41, 24'h500000);
    check_sdr_pair(OFF_MCU-2,        8'h42, 8'h43, 24'h6FFFFF);
    check_sdr_pair(OFF_SPRITES,      8'h50, 8'h51, 24'h800000);

    // Optimized MRAs address each populated region from local offset zero.
    // These downloads must map identically to the legacy fixed stream and
    // must not alter the descriptor-controlled boot gate.
    send_byte(8'd4, 27'd0, 8'h61);
    check(!sdr_wr_req, "split main even byte parks locally");
    send_byte(8'd4, 27'd1, 8'h62);
    check(sdr_wr_req && sdr_wr_addr === 24'h000000 &&
          sdr_wr_din === 16'h6261, "split main maps to maincpu base");
    ack_sdr();
    check(!rom_loaded, "split region cannot open boot gate");

    send_byte(8'd9, 27'd0, 8'h71);
    send_byte(8'd9, 27'd1, 8'h72);
    check(sdr_wr_req && sdr_wr_addr === 24'h800000 &&
          sdr_wr_din === 16'h7271, "split sprites map to sprite base");
    ack_sdr();

    // The stream's MCU base has low bits 0x0040.  Local source offset 0x0040
    // contains only source bit 6, which the inverse permutation maps to
    // destination bit 10 (0x0400).  This also detects accidentally permuting
    // the global stream address rather than the MCU-local source offset.
    // The permutation preserves bits 1:0, so consecutive even/odd stream
    // bytes share one SDRAM word and the loader writes them as a single
    // full-word (be=11) transaction on the odd byte — the design no longer
    // performs any DQM-masked write (they corrupted the image on hardware).
    send_byte(8'd0, OFF_MCU + 27'h0000040, 8'hC7);
    check(v25_wr && v25_waddr === 16'h0400 && v25_wdata === 8'hC7,
          "V25 uses inverse-permuted MCU-local source address");
    check(!sdr_wr_req && !ioctl_wait, "even MCU byte only fills byte_lo");
    send_byte(8'd0, OFF_MCU + 27'h0000041, 8'h5A);
    check(v25_wr && v25_waddr === 16'h0401 && v25_wdata === 8'h5A,
          "V25 odd source maps to odd destination");
    check(sdr_wr_req && ioctl_wait, "odd MCU byte raises SDRAM request/wait");
    check(sdr_wr_addr === 24'h700200, "MCU pair destination word address");
    check(sdr_wr_din === 16'h5AC7, "MCU pair written little-endian");
    check(sdr_wr_be === 2'b11, "MCU pair uses a full-word write");
    ack_sdr();
    check(!v25_wr, "V25 observation write is a one-cycle pulse");

    // Golden Axe II stores encrypted reset byte 0x02 at raw source 0xFDDC.
    // MAME's contract places that byte at V25 destination 0xFFF0; its stream
    // partner 0xFDDD lands at 0xFFF1 in the same word.
    send_byte(8'd0, OFF_MCU + 27'h000FDDC, 8'h02);
    check(v25_wr && v25_waddr === 16'hFFF0 && v25_wdata === 8'h02,
          "GA2 raw reset source FDDC maps to V25 destination FFF0");
    check(!sdr_wr_req && !ioctl_wait, "GA2 even reset byte only fills byte_lo");
    send_byte(8'd0, OFF_MCU + 27'h000FDDD, 8'h11);
    check(v25_wr && v25_waddr === 16'hFFF1 && v25_wdata === 8'h11,
          "GA2 reset partner FDDD maps to V25 destination FFF1");
    check(sdr_wr_req && ioctl_wait, "GA2 reset pair raises SDRAM request");
    check(sdr_wr_addr === 24'h707FF8, "GA2 reset pair SDRAM word address");
    check(sdr_wr_din === 16'h1102, "GA2 reset pair written little-endian");
    check(sdr_wr_be === 2'b11, "GA2 reset pair uses a full-word write");
    ack_sdr();
    check(!v25_wr, "GA2 reset-vector observation is a one-cycle pulse");

    // Leave the very last stream word outstanding while download deasserts.
    // rom_loaded may rise only after that request has actually acknowledged.
    send_sdr_pair(OFF_END-2, 8'hFE, 8'hFF, 24'hFFFFFF);
    @(negedge clk);
    ioctl_download = 1'b0;
    @(posedge clk);
    #1;
    check(sdr_wr_req && ioctl_wait && !rom_loaded,
          "download end waits for final SDRAM ack");
    @(negedge clk);
    sdr_wr_ack = 1'b1;
    @(posedge clk);
    #1;
    check(!sdr_wr_req && !ioctl_wait && !rom_loaded,
          "ack edge clears request before opening boot gate");
    @(negedge clk);
    sdr_wr_ack = 1'b0;
    @(posedge clk);
    #1;
    check(rom_loaded, "post-ack cycle opens boot gate");

    // Index 3 is the persisted NVRAM image.  It must use the same LE packing
    // as the factory image and leave an already-loaded program ROM intact.
    send_byte(8'd3, 27'd126, 8'hEF);
    send_byte(8'd3, 27'd127, 8'hBE);
    check(eep_wr && eep_waddr === 6'd63 && eep_wdata === 16'hBEEF,
          "index-3 persisted EEPROM word");
    check(eep_loaded && rom_loaded, "index 3 preserves ROM boot gate");
    @(negedge clk);
    ioctl_download = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    check(rom_loaded, "ending index 3 preserves rom_loaded");

    // Reassert reset after nonzero outputs/state to catch simulation-only X or
    // power-up dependencies rather than merely checking declaration defaults.
    @(negedge clk);
    rst = 1'b1;
    @(posedge clk);
    #1;
    check_reset_state();

    if (errors == 0) $display("ROM LOADER PASS");
    else             $display("ROM LOADER FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #100000;
    $display("ROM LOADER FAIL (timeout)");
    $finish;
end

endmodule
