// Directed test: exercise the real MiSTer wide file-upload transaction.
// This is intentionally above the adapter-only test: hps_io captures ioctl_din
// on FIO_FILE_TX_DAT while advancing ioctl_addr by two bytes.
`timescale 1ns/1ps

module tb_hps_eeprom_nvram;

reg clk = 1'b0;
always #5 clk = ~clk;

wire [45:0] HPS_BUS;
reg [15:0] host_din = 16'h0000;
reg        host_fp_enable = 1'b0;
reg        host_io_enable = 1'b0;
reg        host_io_strobe = 1'b0;

assign HPS_BUS[31:16] = host_din;
assign HPS_BUS[35]    = host_fp_enable;
assign HPS_BUS[34]    = host_io_enable;
assign HPS_BUS[33]    = host_io_strobe;

wire        ioctl_upload;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire        ioctl_rd;
wire        ioctl_wr;
wire [15:0] ioctl_dout;
wire [15:0] ioctl_din;
wire        ioctl_wait;
wire [15:0] eep_rd_data;
wire        eep_upload;
wire  [5:0] eep_rd_addr;

reg [15:0] eep_mem [0:63];
reg  [5:0] eep_write_addr = 6'd0;
reg        eep_write_en = 1'b0;
wire [15:0] eep_write_data = ~eep_mem[eep_write_addr];
wire [15:0] eep_rd_data_phys;

// Use the actual EEPROM storage contract, including its physical inversion.
// Port B is the asynchronous upload/readback shadow; the selected word must
// already be stable when hps_io captures ioctl_din on the same edge that it
// advances the file address.
assign eep_rd_data = ~eep_rd_data_phys;

s32_eeprom_ram eep_storage (
    .clk(clk),
    .address_a(eep_write_addr), .data_a(eep_write_data),
    .wren_a(eep_write_en), .q_a(),
    .address_b(eep_rd_addr), .q_b(eep_rd_data_phys)
);

s32_eeprom_nvram_if #(.WIDE(1)) nvram_if (
    .ioctl_upload(ioctl_upload),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .eep_rd_data(eep_rd_data),
    .eep_upload(eep_upload),
    .eep_rd_addr(eep_rd_addr),
    .ioctl_din(ioctl_din)
);

// PS2DIV=1 keeps the framework's internal PS/2 transaction registers
// elaborated.  They are unrelated to this file-I/O test, but hps_io's shared
// transaction block references them even when the normal core sets PS2DIV=0.
hps_io #(.CONF_STR("HPS EEPROM TEST;"), .WIDE(1), .PS2DIV(1)) hps (
    .clk_sys(clk),
    .HPS_BUS(HPS_BUS),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(1'b0),
    .ioctl_upload_index(8'd3),
    .ioctl_index(ioctl_index),
    .ioctl_rd(ioctl_rd),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_din(ioctl_din),
    .ioctl_wait(ioctl_wait)
);

integer errors = 0;
integer i;
reg [15:0] captured [0:63];
reg [15:0] response;
reg [26:0] address_before;
reg [5:0] eep_address_before;

task automatic host_word(input [15:0] word, output [15:0] result);
begin
    host_din = word;
    host_io_strobe = 1'b1;
    @(posedge clk);
    #1 result = HPS_BUS[15:0];
    @(negedge clk);
    host_io_strobe = 1'b0;
end
endtask

task automatic fpga_begin;
begin
    host_fp_enable = 1'b1;
    @(negedge clk);
end
endtask

task automatic fpga_end;
begin
    host_fp_enable = 1'b0;
    @(posedge clk);
    @(negedge clk);
end
endtask

task automatic load_word(input [5:0] address);
begin
    @(negedge clk);
    eep_write_addr = address;
    eep_write_en = 1'b1;
    @(posedge clk);
    @(negedge clk);
    eep_write_en = 1'b0;
end
endtask

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL: %0s", name);
    end
end
endtask

initial begin
    for (i = 0; i < 64; i = i + 1)
        eep_mem[i] = 16'h3100 + (i * 16'h0127) + i;
    for (i = 0; i < 64; i = i + 1)
        load_word(i[5:0]);

    // Main_MiSTer sends FIO_FILE_INDEX before starting the NVRAM upload.
    fpga_begin();
    host_word(16'h0055, response);
    host_word(16'h0003, response);
    fpga_end();
    check(ioctl_index === 16'd3, "upload index is 3");

    // user_io_set_upload(1): FIO_FILE_TX, 0xAA, then chip-select release.
    fpga_begin();
    host_word(16'h0053, response);
    host_word(16'h00aa, response);
    fpga_end();
    check(ioctl_upload === 1'b1, "wide upload asserted");
    check(eep_upload === 1'b1, "EEPROM upload adapter enabled");
    check(ioctl_addr === 27'd0, "wide upload starts at byte address zero");

    // user_io_file_rx_data(): one command word followed by 64 wide data
    // words.  The response after each data word is what reaches the NVRAM
    // file buffer on the HPS side.
    fpga_begin();
    host_word(16'h0054, response);
    for (i = 0; i < 64; i = i + 1) begin
        address_before = ioctl_addr;
        eep_address_before = eep_rd_addr;
        host_word(16'h0000, captured[i]);
        check(address_before === (i * 2), "wide upload address increments by two");
        check(eep_address_before === i[5:0], "EEPROM address follows the wide byte address");
        if (i < 4)
            $display("  word[%0d] addr=%0d eep_addr=%0d captured=%04h expected=%04h",
                     i, address_before, eep_address_before, captured[i], eep_mem[i]);
    end
    fpga_end();

    for (i = 0; i < 64; i = i + 1)
        check(captured[i] === eep_mem[i], "uploaded EEPROM word round-trips unchanged");

    // user_io_set_upload(0): terminate the upload after the data transaction.
    fpga_begin();
    host_word(16'h0053, response);
    host_word(16'h0000, response);
    fpga_end();
    check(ioctl_upload === 1'b0, "wide upload deasserted");
    check(eep_upload === 1'b0, "EEPROM upload adapter disabled");

    if (errors == 0) $display("HPS EEPROM NVRAM PASS");
    else $display("HPS EEPROM NVRAM FAIL (%0d errors)", errors);
    $finish;
end

endmodule
