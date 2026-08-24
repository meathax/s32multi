//============================================================================
// Directed test: 93C46 MiSTer NVRAM persistence
//   * index-3 upload exposes 64x16 storage as 128 little-endian bytes
//   * only enabled WRITE/ERASE/ERAL/WRAL operations mark storage dirty
//   * soft reset preserves dirty state and EEPROM contents
//   * loader writes and an index-3 upload start clear dirty state
//============================================================================
`timescale 1ns/1ps

module tb_eeprom_nvram;

reg clk = 1'b0;
always #5 clk = ~clk;

reg rst = 1'b1;
reg di = 1'b0;
reg cs = 1'b0;
reg sk = 1'b0;
wire dout;

reg         ld_wr = 1'b0;
reg  [5:0]  ld_addr = 6'd0;
reg [15:0]  ld_data = 16'd0;
wire [15:0] rd_data;
wire  [5:0] rd_addr;
wire        modified;
reg  [15:0] serial_readback;

reg         ioctl_upload = 1'b0;
reg  [15:0] ioctl_index = 16'd0;
reg  [26:0] ioctl_addr = 27'd0;
wire [15:0] ioctl_din;
wire [15:0] ioctl_din_wide;
wire        eep_upload;
wire        eep_upload_wide;
wire  [5:0] rd_addr_wide;

s32_eeprom_nvram_if nvram_if (
    .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .eep_rd_data(rd_data),
    .eep_upload(eep_upload), .eep_rd_addr(rd_addr),
    .ioctl_din(ioctl_din)
);

s32_eeprom_nvram_if #(.WIDE(1)) nvram_if_wide (
    .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .eep_rd_data(rd_data),
    .eep_upload(eep_upload_wide), .eep_rd_addr(rd_addr_wide),
    .ioctl_din(ioctl_din_wide)
);

s32_eeprom93c46 #(
    .WRITE_BUSY_CYCLES(96),
    .ERASE_BUSY_CYCLES(72),
    .WRITE_ALL_BUSY_CYCLES(96),
    .ERASE_ALL_BUSY_CYCLES(96)
) dut (
    .clk(clk), .rst(rst),
    .di(di), .cs(cs), .sk(sk), .dout(dout),
    .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data),
    .rd_data(rd_data), .rd_addr(rd_addr),
    .upload(eep_upload), .modified(modified)
);

integer errors = 0;

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL: %0s", name);
    end
end
endtask

// Present each serial bit with a complete low phase before its sampled
// rising edge so the DUT's SK edge detector is exercised realistically.
task automatic serial_bit(input bit value);
begin
    @(negedge clk);
    sk = 1'b0;
    di = value;
    @(posedge clk);
    #1;
    @(negedge clk);
    sk = 1'b1;
    @(posedge clk);
    #1;
end
endtask

task automatic begin_command(input [7:0] command);
integer n;
begin
    @(negedge clk);
    cs = 1'b1;
    sk = 1'b0;
    di = 1'b0;
    @(posedge clk);
    #1;
    serial_bit(1'b1); // start bit
    for (n = 7; n >= 0; n = n - 1) serial_bit(command[n]);
end
endtask

task automatic end_command;
begin
    @(negedge clk);
    cs = 1'b0;
    sk = 1'b0;
    di = 1'b0;
    @(posedge clk);
    #1;
end
endtask

task automatic command_only(input [7:0] command);
begin
    begin_command(command);
    end_command();
end
endtask

task automatic write_word(input [5:0] address, input [15:0] data);
integer n;
begin
    begin_command(8'h40 | address);
    for (n = 15; n >= 0; n = n - 1) serial_bit(data[n]);
    end_command();
end
endtask

task automatic write_all(input [15:0] data);
integer n;
begin
    begin_command(8'h10); // WRAL
    for (n = 15; n >= 0; n = n - 1) serial_bit(data[n]);
    end_command();
end
endtask

task automatic read_word(input [5:0] address, output reg [15:0] data);
integer n;
begin
    begin_command(8'h80 | address);
    check(dout === 1'b0, "READ dummy bit");
    for (n = 15; n >= 0; n = n - 1) begin
        serial_bit(1'b0);
        data[n] = dout;
    end
    end_command();
end
endtask

task automatic read_two_words(
    input [5:0] address,
    output reg [15:0] first,
    output reg [15:0] second
);
integer n;
begin
    begin_command(8'h80 | address);
    check(dout === 1'b0, "streaming READ dummy bit");
    for (n = 15; n >= 0; n = n - 1) begin
        serial_bit(1'b0);
        first[n] = dout;
    end
    for (n = 15; n >= 0; n = n - 1) begin
        serial_bit(1'b0);
        second[n] = dout;
    end
    end_command();
end
endtask

task automatic wait_bulk_write;
begin
    wait (dut.bulk_active === 1'b1);
    wait (dut.bulk_active === 1'b0);
    #1;
end
endtask

task automatic poll_busy_ready(input [255:0] name);
integer polls;
begin
    @(negedge clk);
    cs = 1'b1;
    sk = 1'b0;
    di = 1'b0;
    @(posedge clk);
    #1;
    check(dout === 1'b0, {name, " busy drives DO low"});
    polls = 0;
    while (dout !== 1'b1 && polls < 256) begin
        @(posedge clk);
        #1;
        polls = polls + 1;
    end
    check(dout === 1'b1, {name, " completion drives READY high"});
    end_command();
end
endtask

task automatic load_word(input [5:0] address, input [15:0] data);
begin
    @(negedge clk);
    ld_addr = address;
    ld_data = data;
    ld_wr = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    ld_wr = 1'b0;
    @(posedge clk);
    #1;
end
endtask

task automatic set_upload(input [15:0] index, input enable);
begin
    @(negedge clk);
    ioctl_index = index;
    ioctl_upload = enable;
    @(posedge clk);
    #1;
end
endtask

task automatic check_word(input [5:0] address, input [15:0] expected);
begin
    ioctl_addr = {20'd0, address, 1'b0};
    @(posedge clk);
    #1;
    check(rd_addr === address, "word read address mapping");
    check(rd_data === expected, "EEPROM word contents");
end
endtask

task automatic check_byte(input [6:0] address, input [7:0] expected);
begin
    ioctl_addr = address;
    @(posedge clk);
    #1;
    check(ioctl_din[7:0] === expected && ioctl_din[15:8] === 8'h00, "index-3 little-endian upload byte");
end
endtask

task automatic check_wide_word(input [5:0] address, input [15:0] expected);
begin
    ioctl_addr = {20'd0, address, 1'b0};
    @(posedge clk);
    #1;
    check(rd_addr_wide === address, "wide upload word address mapping");
    check(ioctl_din_wide === expected, "wide upload preserves EEPROM word");
end
endtask

initial begin
    repeat (4) @(posedge clk);
    #1;
    check(modified === 1'b0, "power-up dirty state is clear");
    @(negedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    // Loader data forms the clean baseline used by upload readback.
    load_word(6'd0, 16'h1234);
    load_word(6'd1, 16'hA5C3);
    load_word(6'd63, 16'hBEEF);
    check(!modified, "loader writes leave EEPROM clean");

    set_upload(16'd2, 1'b1);
    check(!eep_upload && ioctl_din === 16'h0000,
          "non-NVRAM upload index is isolated");
    set_upload(16'd2, 1'b0);

    set_upload(16'd3, 1'b1);
    check(eep_upload, "index 3 selects EEPROM upload");
    check(eep_upload_wide, "index 3 selects wide EEPROM upload");
    check_byte(7'd0,   8'h34);
    check_byte(7'd1,   8'h12);
    check_byte(7'd2,   8'hC3);
    check_byte(7'd3,   8'hA5);
    check_byte(7'd126, 8'hEF);
    check_byte(7'd127, 8'hBE);
    check_wide_word(6'd0, 16'h1234);
    check_wide_word(6'd1, 16'hA5C3);
    check_wide_word(6'd63, 16'hBEEF);
    set_upload(16'd3, 1'b0);

    // A write while write-enable is clear must be ignored and remain clean.
    write_word(6'd5, 16'h0BAD);
    check(!modified, "disabled WRITE does not dirty");
    check_word(6'd5, 16'hFFFF);

    command_only(8'h30); // EWEN
    check(!modified, "EWEN does not dirty");
    read_word(6'd5, serial_readback);
    check(serial_readback === 16'hFFFF, "serial READ returns erased word");
    check(!modified, "READ does not dirty");

    // System 32 software clocks beyond one word without dropping CS. The
    // 93C46 must continue at the next address instead of returning pull-ups.
    read_two_words(6'd0, serial_readback, ld_data);
    check(serial_readback === 16'h1234, "streaming READ first word");
    check(ld_data === 16'hA5C3, "streaming READ advances to next word");
    command_only(8'h00); // EWDS
    check(!modified, "EWDS does not dirty");
    command_only(8'h30); // EWEN again

    write_word(6'd5, 16'hA55A);
    check(modified, "enabled WRITE marks dirty");
    check_word(6'd5, 16'hA55A);
    command_only(8'h00); // EWDS attempt must be ignored during WRITE busy
    check(dut.ewen, "busy EEPROM rejects a new command");
    poll_busy_ready("WRITE");
    read_word(6'd5, serial_readback);
    check(serial_readback === 16'hA55A, "serial READ returns written word");

    // rst is the normal game/soft reset. It resets the serial protocol but
    // must preserve both contents and the pending save request.
    @(negedge clk);
    rst = 1'b1;
    repeat (3) @(posedge clk);
    #1;
    check(modified, "soft reset preserves dirty");
    check_word(6'd5, 16'hA55A);
    @(negedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    // Only an actual index-3 upload acknowledges the pending generation.
    set_upload(16'd2, 1'b1);
    check(modified, "wrong upload index does not clear dirty");
    set_upload(16'd2, 1'b0);
    set_upload(16'd3, 1'b1);
    check(!modified, "index-3 upload start clears dirty");
    set_upload(16'd3, 1'b0);

    command_only(8'h30); // soft reset cleared EWEN
    command_only(8'hC5); // ERASE word 5
    check(modified, "enabled ERASE marks dirty");
    check_word(6'd5, 16'hFFFF);
    poll_busy_ready("ERASE");

    load_word(6'd5, 16'h1357);
    check(!modified, "loader write clears dirty");
    check_word(6'd5, 16'h1357);

    write_all(16'h2468);
    check(!modified, "WRAL remains clean until final RAM commit");
    wait_bulk_write();
    check(modified, "enabled WRAL marks dirty");
    poll_busy_ready("WRAL");
    check_word(6'd0, 16'h2468);
    check_word(6'd63, 16'h2468);
    set_upload(16'd3, 1'b1);
    check(!modified, "upload clears WRAL dirty state");
    set_upload(16'd3, 1'b0);

    command_only(8'h20); // ERAL, EWEN remains active
    check(!modified, "ERAL remains clean until final RAM commit");
    wait_bulk_write();
    check(modified, "enabled ERAL marks dirty");
    poll_busy_ready("ERAL");
    check_word(6'd0, 16'hFFFF);
    check_word(6'd63, 16'hFFFF);

    // Establish a final clean word, disable writes, and prove ERASE is then
    // ignored without raising another save request.
    load_word(6'd0, 16'h55AA);
    command_only(8'h00); // EWDS
    command_only(8'hC0); // disabled ERASE word 0
    check(!modified, "disabled ERASE remains clean");
    check_word(6'd0, 16'h55AA);

    if (errors == 0) $display("EEPROM NVRAM PASS");
    else             $display("EEPROM NVRAM FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #500000;
    $display("EEPROM NVRAM FAIL (timeout)");
    $finish;
end

endmodule
