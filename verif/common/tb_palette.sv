// Directed palette test: registered reads, format aliasing, byte enables,
// mixer read port, and the serialized write-both partner copy.
`timescale 1ns/1ps

module tb_palette;

reg clk = 0;
always #5 clk = ~clk;
reg mix_clk = 0;
initial begin
    #1;
    forever #3 mix_clk = ~mix_clk;
end

reg         cpu_we = 0;
reg  [14:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
reg   [1:0] cpu_be = 0;
wire [15:0] cpu_rdata;
reg  [15:0] mixer_r4e = 0;
reg  [13:0] mix_addr = 0;
wire [15:0] mix_data;

s32_palette dut (
    .clk(clk), .mix_clk(mix_clk),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_rdata(cpu_rdata), .mixer_r4e(mixer_r4e),
    .mix_addr(mix_addr), .mix_data(mix_data)
);

function automatic [15:0] to_alt(input [15:0] v);
    to_alt = {v[15], v[10], v[5], v[0], v[14:11], v[9:6], v[4:1]};
endfunction

function automatic [15:0] from_alt(input [15:0] v);
    from_alt = {v[15], v[11:8], v[14], v[7:4], v[13], v[3:0], v[12]};
endfunction

integer errors = 0;
integer cdc_iter;

task check16(input [15:0] got, input [15:0] want, input [255:0] what);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %0s: got=%04x want=%04x", what, got, want);
    end
endtask

task write_word(
    input [14:0] addr,
    input [15:0] data,
    input  [1:0] be,
    input        both
);
    @(negedge clk);
    cpu_addr = addr;
    cpu_wdata = data;
    cpu_be = be;
    mixer_r4e = both ? 16'h0080 : 16'h0000;
    cpu_we = 1'b1;
    @(posedge clk); #1;
    @(negedge clk);
    cpu_we = 1'b0;
    mixer_r4e = 16'h0000;
    // Commits a pending mirror, or supplies the normal idle/read edge.
    @(posedge clk); #1;
endtask

task expect_cpu(input [14:0] addr, input [15:0] want, input [255:0] what);
    @(negedge clk);
    cpu_addr = addr;
    cpu_we = 1'b0;
    @(posedge clk); #1;
    check16(cpu_rdata, want, what);
endtask

task expect_mix(input [13:0] addr, input [15:0] want, input [255:0] what);
    @(negedge mix_clk);
    mix_addr = addr;
    @(posedge mix_clk); #1;
    check16(mix_data, want, what);
endtask

reg [15:0] expected;
reg [15:0] old_alt;

initial begin
    repeat (2) @(posedge clk);

    // Independent one-hot format vectors from MAME's conversion contract.
    // Native channel bit 0 is promoted into the alternate B/G/R flag bit;
    // channel bits 4:1 move into the low nibbles.  These constants prevent
    // the DUT and test helper from agreeing on the same reversed mapping.
    write_word(15'h0070, 16'h0001, 2'b11, 1'b0);
    expect_cpu(15'h4070, 16'h1000, "native R0 -> alternate R flag");
    write_word(15'h0071, 16'h0020, 2'b11, 1'b0);
    expect_cpu(15'h4071, 16'h2000, "native G0 -> alternate G flag");
    write_word(15'h0072, 16'h0400, 2'b11, 1'b0);
    expect_cpu(15'h4072, 16'h4000, "native B0 -> alternate B flag");
    write_word(15'h4073, 16'h0001, 2'b11, 1'b0);
    expect_cpu(15'h0073, 16'h0002, "alternate R1 -> native R1");
    write_word(15'h4074, 16'h0010, 2'b11, 1'b0);
    expect_cpu(15'h0074, 16'h0040, "alternate G1 -> native G1");
    write_word(15'h4075, 16'h0100, 2'b11, 1'b0);
    expect_cpu(15'h0075, 16'h0800, "alternate B1 -> native B1");

    // Native full-word and byte-lane writes.
    write_word(15'h0012, 16'hABCD, 2'b11, 1'b0);
    expect_cpu(15'h0012, 16'hABCD, "native full write/read");
    write_word(15'h0012, 16'h00EF, 2'b01, 1'b0);
    expect_cpu(15'h0012, 16'hABEF, "native low-byte write");
    write_word(15'h0012, 16'h1200, 2'b10, 1'b0);
    expect_cpu(15'h0012, 16'h12EF, "native high-byte write");
    expect_mix(14'h0012, 16'h12EF, "independent mixer read");

    // Exercise the real dual-clock port across both physical halves.  A bank
    // selector taken directly from the new address would be one lookup ahead
    // of the registered RAM row and would fail this alternating sequence.
    write_word(15'h0101, 16'h4211, 2'b11, 1'b0);
    write_word(15'h2102, 16'h2ACE, 2'b11, 1'b0);
    for (cdc_iter = 0; cdc_iter < 16; cdc_iter = cdc_iter + 1) begin
        expect_mix(14'h0101, 16'h4211, "dual-clock lower-bank lookup");
        expect_mix(14'h2102, 16'h2ACE, "dual-clock upper-bank lookup");
    end

    // Converted view: a full write followed by both byte lanes.  Expected
    // values are formed in alias space and then permuted back to storage.
    write_word(15'h4044, 16'hD39A, 2'b11, 1'b0);
    expect_cpu(15'h4044, 16'hD39A, "converted full write/read");
    expect_cpu(15'h0044, from_alt(16'hD39A), "converted native storage");

    old_alt = 16'hD39A;
    expected = from_alt({old_alt[15:8], 8'hE7});
    write_word(15'h4044, 16'h00E7, 2'b01, 1'b0);
    expect_cpu(15'h0044, expected, "converted low-byte mask permutation");
    old_alt = {old_alt[15:8], 8'hE7};
    expected = from_alt({8'h26, old_alt[7:0]});
    write_word(15'h4044, 16'h2600, 2'b10, 1'b0);
    expect_cpu(15'h0044, expected, "converted high-byte mask permutation");
    expect_cpu(15'h4044, 16'h26E7, "converted byte-merged readback");

    // MAME applies COMBINE_DATA to each half independently, so partial
    // write-both preserves each half's own disabled byte.
    write_word(15'h0033, 16'hABCD, 2'b11, 1'b0);
    write_word(15'h2033, 16'h1357, 2'b11, 1'b0);
    @(negedge mix_clk);
    mix_addr = 14'h2033;
    @(posedge mix_clk); #1;
    @(negedge clk);
    cpu_addr = 15'h0033;
    cpu_wdata = 16'h00EF;
    cpu_be = 2'b01;
    mixer_r4e = 16'h0080;
    cpu_we = 1'b1;
    @(posedge clk); #1;
    check16(mix_data, 16'h1357, "write-both source edge leaves partner old");
    @(negedge clk);
    cpu_we = 1'b0;
    mixer_r4e = 16'h0000;
    @(posedge clk); #1;
    check16(cpu_rdata, 16'hABEF, "write-both source merged word");
    @(posedge mix_clk); #1;
    check16(mix_data, 16'h13EF, "pending partner masked write committed");
    expect_cpu(15'h2033, 16'h13EF, "write-both partner preserves own high byte");

    // Reverse direction and converted-view partial write-both.
    write_word(15'h2055, 16'h2468, 2'b11, 1'b0);
    write_word(15'h0055, 16'hDEAD, 2'b11, 1'b0);
    write_word(15'h2055, 16'hB100, 2'b10, 1'b1);
    expect_cpu(15'h2055, 16'hB168, "reverse write-both source");
    expect_cpu(15'h0055, 16'hB1AD, "reverse write-both partner");

    write_word(15'h0066, 16'h5A3C, 2'b11, 1'b0);
    write_word(15'h2066, 16'h0F0F, 2'b11, 1'b0);
    old_alt = to_alt(16'h5A3C);
    expected = from_alt({old_alt[15:8], 8'h91});
    write_word(15'h4066, 16'h0091, 2'b01, 1'b1);
    expect_cpu(15'h4066, {old_alt[15:8], 8'h91},
               "converted write-both alias readback");
    old_alt = to_alt(16'h0F0F);
    expected = from_alt({old_alt[15:8], 8'h91});
    expect_cpu(15'h2066, expected,
               "converted write-both partner native data");

    if (errors == 0)
        $display("PALETTE PASS");
    else begin
        $display("PALETTE FAIL: %0d errors", errors);
        $fatal(1);
    end
    $finish;
end

endmodule
