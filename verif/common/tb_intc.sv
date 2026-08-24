//============================================================================
// Directed System 32 interrupt-controller regression.
// Covers reset state, vector/mask selection, simultaneous source+ack
// accumulation, zero-count write semantics (must NOT cancel — MAME parity,
// audit R25-9), exact timer-0 period, and
// the sound-CPU doorbell pulse.
//============================================================================
`timescale 1ns/1ps

module tb_intc;

reg clk = 0;
always #5 clk = ~clk;

reg rst = 1;
reg is_multi32 = 0;
reg cs = 0;
reg we = 0;
reg [3:1] addr = 0;
reg [1:0] be = 0;
reg [15:0] wdata = 0;
wire [7:0] rdata;
reg vblank_start = 0;
reg vblank_end = 0;
reg sound_irq = 0;
wire irq_n;
wire [7:0] irq_vector;
wire z80_doorbell;

integer errors = 0;
integer i;
integer timer1_clocks;

s32_intc dut (
    .clk(clk), .rst(rst), .is_multi32(is_multi32),
    .cs(cs), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata),
    .vblank_start(vblank_start), .vblank_end(vblank_end),
    .sound_irq(sound_irq), .irq_n(irq_n), .irq_vector(irq_vector),
    .irq_taken(1'b0), .z80_doorbell(z80_doorbell)
);

task automatic ctl_write(
    input [3:1] a,
    input [1:0] lanes,
    input [15:0] value
);
begin
    @(negedge clk);
    addr = a; be = lanes; wdata = value; cs = 1'b1; we = 1'b1;
    @(negedge clk);
    cs = 1'b0; we = 1'b0; be = 2'b00;
end
endtask

task automatic ctl_read(input [3:1] a, input [1:0] lanes);
begin
    @(negedge clk);
    addr = a; be = lanes; cs = 1'b1; we = 1'b0;
    @(posedge clk); #1;
    // MAME's int_control_r is currently an unmapped/readback stub: all
    // interrupt-controller and timer offsets return 0xff.  Keep the
    // production behavior explicit until PCB evidence proves otherwise.
    if (rdata !== 8'hff) begin
        $display("FAIL intc read addr=%0d lanes=%b data=%02x expected=ff",
                 a, lanes, rdata);
        errors = errors + 1;
    end
    @(negedge clk);
    cs = 1'b0; we = 1'b0; be = 2'b00;
end
endtask

initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 0;
    @(posedge clk);
    #1;

    for (i = 0; i < 16; i = i + 1) begin
        if (dut.ctl[i] !== 8'hff) begin
            $display("FAIL intc reset ctl[%0d]=%02x want ff", i, dut.ctl[i]);
            errors = errors + 1;
        end
    end
    // audit R20 IO-6: reset now leaves all five sources pending (MAME memsets
    // the control file to 0xff, so the pending byte = 0xff), but ctl[6]=0xff
    // masks them all, so irq_n stays high and no IRQ is delivered.
    if (dut.pending !== 5'h1f || irq_n !== 1'b1 ||
        rdata !== 8'hff || z80_doorbell !== 1'b0) begin
        $display("FAIL intc reset outputs pending=%02x irq_n=%b rdata=%02x doorbell=%b",
                 dut.pending, irq_n, rdata, z80_doorbell);
        errors = errors + 1;
    end

    // Exercise every byte-pair and lane of the readback aperture, including
    // the timer registers. The expected all-FF result is the pinned MAME
    // contract, not an accidental stale value from the previous transaction.
    for (i = 0; i < 8; i = i + 1) begin
        ctl_read(i[3:1], 2'b01);
        ctl_read(i[3:1], 2'b10);
        ctl_read(i[3:1], 2'b11);
    end

    // Acknowledge the reset-pending sources (byte 7, AND-mask 0) so the
    // directed source/timer cases below start from a clean pending state.
    ctl_write(3'd3, 2'b10, 16'h0000);
    @(posedge clk); #1;

    // Source 0 vector = 5; mask byte FE leaves only source 0 unmasked.
    ctl_write(3'd0, 2'b01, 16'h0005);
    ctl_write(3'd3, 2'b01, 16'h00fe);
    @(negedge clk); vblank_start = 1'b1;
    @(negedge clk); vblank_start = 1'b0;
    #1;
    if (dut.pending[0] !== 1'b1 || irq_n !== 1'b0 || irq_vector !== 8'h05) begin
        $display("FAIL intc vector/mask pending=%02x irq_n=%b vector=%02x",
                 dut.pending, irq_n, irq_vector);
        errors = errors + 1;
    end

    // Byte 7 is an AND-clear acknowledgement; FE clears source 0.
    ctl_write(3'd3, 2'b10, 16'hfe00);
    #1;
    if (dut.pending[0] !== 1'b0 || irq_n !== 1'b1) begin
        $display("FAIL intc source-0 acknowledge pending=%02x", dut.pending);
        errors = errors + 1;
    end

    // A new source arriving with an acknowledgement for a different source
    // must be retained. The former whole-vector NBA used stale pending and
    // discarded sound_irq here even though FE preserves bit 2.
    @(negedge clk);
    addr = 3'd3; be = 2'b10; wdata = 16'hfe00;
    cs = 1'b1; we = 1'b1; sound_irq = 1'b1;
    @(negedge clk);
    cs = 1'b0; we = 1'b0; be = 2'b00; sound_irq = 1'b0;
    #1;
    if (dut.pending[2] !== 1'b1) begin
        $display("FAIL intc simultaneous source/ack lost source 2");
        errors = errors + 1;
    end
    ctl_write(3'd3, 2'b10, 16'hfb00);

    // A zero duration write must NOT cancel a previously armed one-shot:
    // MAME int_control_w only re-arms `if (duration)` — the register byte
    // is stored and the in-flight timer keeps running (audit R25-9).
    ctl_write(3'd4, 2'b11, 16'h0001);
    #1;
    if (dut.t0_run !== 1'b1 || dut.t0_cnt !== 24'h0017ff) begin
        $display("FAIL timer0 arm run=%b count=%06x", dut.t0_run, dut.t0_cnt);
        errors = errors + 1;
    end
    ctl_write(3'd4, 2'b11, 16'h0000);
    #1;
    if (dut.t0_run !== 1'b1 || dut.t0_cnt > 24'h0017ff || dut.t0_cnt == 24'd0) begin
        $display("FAIL timer0 zero write must not cancel run=%b count=%06x",
                 dut.t0_run, dut.t0_cnt);
        errors = errors + 1;
    end

    // N=1 must expire after exactly 0x1800 clk_sys clocks, not one late.
    ctl_write(3'd4, 2'b11, 16'h0001);
    repeat (16'h17ff) @(posedge clk);
    #1;
    if (dut.pending[3] !== 1'b0) begin
        $display("FAIL timer0 expired early");
        errors = errors + 1;
    end
    @(posedge clk);
    #1;
    if (dut.pending[3] !== 1'b1 || dut.t0_run !== 1'b0) begin
        $display("FAIL timer0 exact expiry pending=%02x run=%b",
                 dut.pending, dut.t0_run);
        errors = errors + 1;
    end
    ctl_write(3'd3, 2'b10, 16'hf700);

    // Timer 1 uses the independent 50 MHz/16 source.  N=1 is 256 source
    // ticks, or about 3958 clocks at 48.317307 MHz; bound the fractional phase
    // to one host clock around the exact ratio.
    ctl_write(3'd5, 2'b11, 16'h0001);
    timer1_clocks = 0;
    while (!dut.pending[4] && timer1_clocks < 4100) begin
        @(posedge clk); #1;
        timer1_clocks = timer1_clocks + 1;
    end
    if (!dut.pending[4] || timer1_clocks < 3958 || timer1_clocks > 3960) begin
        $display("FAIL timer1 cadence clocks=%0d pending=%02x",
                 timer1_clocks, dut.pending);
        errors = errors + 1;
    end
    ctl_write(3'd3, 2'b10, 16'hef00);

    // Writes to byte offsets 12..15 ring the sound CPU for one clock.
    ctl_write(3'd6, 2'b01, 16'h00a5);
    #1;
    if (z80_doorbell !== 1'b1) begin
        $display("FAIL intc doorbell did not assert");
        errors = errors + 1;
    end
    @(posedge clk);
    #1;
    if (z80_doorbell !== 1'b0) begin
        $display("FAIL intc doorbell did not clear");
        errors = errors + 1;
    end

    if (errors == 0) $display("INTC PASS");
    else             $display("INTC FAIL (%0d errors)", errors);
    $finish;
end

endmodule
