// Quantify the MultiPCM frame-cadence stall: with realistic SDRAM ack
// latency, how far does the 224-ce sample frame stretch as voices activate?
// Real 315-5560 outputs at clk/224 regardless of ROM traffic.
`timescale 1ns/1ps

module tb_multipcm_cadence;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // Production ratio: ce_pcm = 10 MHz from 48.317 MHz clk_sys (~1 in 4.83).
    // Model with an NCO like s32_audio_ce.
    reg ce = 1'b0;
    reg [31:0] acc = 0;
    localparam [31:0] PCM_INC = 32'd888908667;
    always @(posedge clk) begin
        {ce, acc} <= {1'b0, acc} + {1'b0, PCM_INC};
    end

    reg rst = 1'b1;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [1:0] addr = 0;
    reg [7:0] wdata = 0;
    wire rom_req;
    wire [21:0] rom_addr;
    reg [7:0] rom_data = 0;
    reg rom_ack = 1'b0;
    wire signed [15:0] out_l, out_r;

    // ACK latency in clk cycles (plusarg), default 1 (like the unit tb).
    integer ack_delay = 1;
    integer ack_cnt = 0;
    reg pending = 1'b0;

    s32_multipcm dut (
        .clk(clk), .ce(ce), .rst(rst),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack),
        .bank_lo(3'd0), .bank_hi(3'd0),
        .out_l(out_l), .out_r(out_r)
    );

    function automatic [7:0] rom_byte(input [22:0] a);
        // Descriptor region for sample 0x102 at 0x102*12=0xC18: 8-bit fmt,
        // start 0x100, loop 1, end 4, attack F (instant), no LFO depth.
        reg [3:0] di;
    begin
        if (a >= 22'h000c18 && a < 22'h000c24) begin
            di = a[3:0] - 4'h8;
            case (di)
                0: rom_byte = 8'h00;
                1: rom_byte = 8'h01;
                2: rom_byte = 8'h00;
                3: rom_byte = 8'h00;
                4: rom_byte = 8'h01;
                5: rom_byte = 8'hff;
                6: rom_byte = 8'hfc;
                7: rom_byte = 8'h00;
                8: rom_byte = 8'hf0;
                9: rom_byte = 8'h00;
               10: rom_byte = 8'h0f;
               11: rom_byte = 8'h00;
              default: rom_byte = 8'h00;
            endcase
        end
        else rom_byte = 8'h40;  // nonzero sample data
    end
    endfunction

    // ack after ack_delay clks
    always @(posedge clk) begin
        rom_ack <= 1'b0;
        if (rom_req && !pending) begin
            pending <= 1'b1;
            ack_cnt <= 0;
        end
        else if (pending) begin
            if (ack_cnt >= ack_delay - 1) begin
                rom_data <= rom_byte(rom_addr);
                rom_ack <= 1'b1;
                pending <= 1'b0;
            end
            else ack_cnt <= ack_cnt + 1;
        end
        if (!rom_req) pending <= 1'b0;
    end

    task automatic write_port(input [1:0] port, input [7:0] value);
    begin
        @(negedge clk); cs = 1'b1; we = 1'b1; addr = port; wdata = value;
        @(posedge clk); #1; @(negedge clk); cs = 1'b0; we = 1'b0;
    end
    endtask

    // key on channel n with sample 0x102, octave 1 pitch 0, pan 0, TL 0
    task automatic keyon(input [7:0] ch);
    begin
        write_port(1, ch);
        write_port(2, 8'd0); write_port(0, 8'h00);         // pan 0
        write_port(2, 8'd2); write_port(0, 8'h01);         // sample bit8
        write_port(2, 8'd1); write_port(0, 8'h02);         // sample lo -> fetch
        write_port(2, 8'd3); write_port(0, 8'h10);         // octave 1, pitch hi 0
        write_port(2, 8'd5); write_port(0, 8'h00);         // TL 0
        write_port(2, 8'd4); write_port(0, 8'h80);         // key on
    end
    endtask

    // measure ce count between out_l/out_r frame boundaries (slot wrap)
    integer ce_count = 0;
    integer frames = 0;
    integer ce_sum = 0;
    reg measuring = 1'b0;
    reg [4:0] slot_d;
    always @(posedge clk) begin
        slot_d <= dut.slot;
        if (ce) ce_count <= ce_count + 1;
        if (dut.slot == 5'd0 && slot_d == 5'd27) begin  // frame wrap
            if (measuring && frames < 200) begin
                frames <= frames + 1;
                ce_sum <= ce_sum + ce_count;
            end
            ce_count <= 0;
        end
    end

    integer nvoice = 1;
    integer i;
    initial begin
        if (!$value$plusargs("ACK=%d", ack_delay)) ack_delay = 1;
        if (!$value$plusargs("VOICES=%d", nvoice)) nvoice = 1;
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);
        for (i = 0; i < nvoice; i = i + 1) begin
            // raw selector skips every 8th value (holes at 7,15,23,31)
            keyon((i + (i/7)) & 8'h1f);
        end
        // let descriptors finish and voices start
        repeat (60000) @(posedge clk);
        measuring = 1'b1;
        frames = 0; ce_sum = 0;
        wait (frames == 200);
        if (ce_sum == 200*224)
            $display("MULTIPCM CADENCE PASS ack=%0d voices=%0d avg=%0d",
                     ack_delay, nvoice, ce_sum/200);
        else
            $display("MULTIPCM CADENCE FAIL ack=%0d voices=%0d avg_ce=%0d (want 224)",
                     ack_delay, nvoice, ce_sum/200);
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT frames=%0d", frames);
        $finish;
    end
endmodule
