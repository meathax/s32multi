`timescale 1ns/1ps

module tb_multipcm_pan;
    reg clk = 1'b0;
    reg ce = 1'b0;
    reg rst = 1'b1;
    reg cs = 1'b0, we = 1'b0;
    reg [1:0] addr = 0;
    reg [7:0] wdata = 0;
    wire rom_req;
    wire [21:0] rom_addr;
    reg [7:0] rom_data = 0;
    reg rom_ack = 1'b0;
    wire signed [15:0] out_l, out_r;

    s32_multipcm dut (
        .clk(clk), .ce(ce), .rst(rst), .cs(cs), .we(we), .addr(addr),
        .wdata(wdata), .rdata(), .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_data(rom_data), .rom_ack(rom_ack), .bank_lo(3'd0),
        .bank_hi(3'd0), .out_l(out_l), .out_r(out_r)
    );

    function automatic integer expected_gain(input integer distance);
    begin
        case (distance)
            0: expected_gain = 1024;
            1: expected_gain = 724;
            2: expected_gain = 513;
            3: expected_gain = 363;
            4: expected_gain = 257;
            5: expected_gain = 182;
            6: expected_gain = 128;
            default: expected_gain = 0;
        endcase
    end
    endfunction

    integer pan;
    integer want_l, want_r;
    integer got_l, got_r;
    initial begin
        for (pan = 0; pan < 16; pan = pan + 1) begin
            if (pan == 8) begin
                want_l = 0;
                want_r = 0;
            end
            else if (pan == 0) begin
                want_l = 16000;
                want_r = 16000;
            end
            else if (pan < 8) begin
                want_l = (16000 * expected_gain(pan)) >>> 10;
                want_r = 16000;
            end
            else begin
                want_l = 16000;
                want_r = (16000 * expected_gain(16 - pan)) >>> 10;
            end
            got_l = dut.pan_sample(16'sd16000, pan[3:0], 1'b1);
            got_r = dut.pan_sample(16'sd16000, pan[3:0], 1'b0);
            if (got_l !== want_l || got_r !== want_r)
                $fatal(1, "pan=%0d got=%0d/%0d want=%0d/%0d", pan,
                       got_l, got_r, want_l, want_r);
            got_l = dut.pan_sample(-16'sd16000, pan[3:0], 1'b1);
            got_r = dut.pan_sample(-16'sd16000, pan[3:0], 1'b0);
            if (pan == 8) begin
                want_l = 0;
                want_r = 0;
            end
            else if (pan == 0) begin
                want_l = -16000;
                want_r = -16000;
            end
            else if (pan < 8) begin
                want_l = (-16000 * expected_gain(pan)) >>> 10;
                want_r = -16000;
            end
            else begin
                want_l = -16000;
                want_r = (-16000 * expected_gain(16 - pan)) >>> 10;
            end
            if (got_l !== want_l || got_r !== want_r)
                $fatal(1, "negative pan=%0d got=%0d/%0d want=%0d/%0d", pan,
                       got_l, got_r, want_l, want_r);
        end
        $display("MULTIPCM PAN PASS cases=32");
        $finish;
    end
endmodule
