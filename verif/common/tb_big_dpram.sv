`timescale 1ns/1ps

module tb_big_dpram;
    reg clk_a = 1'b0;
    reg clk_b = 1'b0;
    always #5 clk_a = ~clk_a;
    always #7 clk_b = ~clk_b;

    reg  [3:0]  addr_a = 0;
    reg  [15:0] data_a = 0;
    reg  [1:0]  be_a = 0;
    reg         we_a = 0;
    wire [15:0] q_a;
    reg  [3:0]  addr_b = 0;
    reg  [15:0] data_b = 0;
    reg  [1:0]  be_b = 0;
    reg         we_b = 0;
    wire [15:0] q_b;

    s32_big_dpram #(
        .ADDR_WIDTH(4), .NUM_WORDS(16), .MIXED_RDW_MODE("DONT_CARE")
    ) dut (
        .clock_a(clk_a), .address_a(addr_a), .data_a(data_a),
        .byteena_a(be_a), .wren_a(we_a), .q_a(q_a),
        .clock_b(clk_b), .address_b(addr_b), .data_b(data_b),
        .byteena_b(be_b), .wren_b(we_b), .q_b(q_b)
    );

    task check_word(input [15:0] got, input [15:0] want, input [255:0] what);
        begin
            if (got !== want) begin
                $display("BIG DPRAM FAIL: %0s got=%04x want=%04x", what, got, want);
                $fatal(1);
            end
        end
    endtask

    initial begin
        // Registered zero-filled read.
        addr_a = 4'h2;
        @(posedge clk_a); #1;
        check_word(q_a, 16'h0000, "initial port-A read");

        // Each byte lane updates independently.  q retains the prior word on
        // the write edge in the behavioural model; core clients sample reads
        // only on a later cycle.
        data_a = 16'h12a5; be_a = 2'b01; we_a = 1'b1;
        @(posedge clk_a); #1;
        check_word(q_a, 16'h0000, "old data on low-byte write");
        we_a = 1'b0;
        @(posedge clk_a); #1;
        check_word(q_a, 16'h00a5, "low-byte merge");

        data_a = 16'h5a00; be_a = 2'b10; we_a = 1'b1;
        @(posedge clk_a); #1;
        check_word(q_a, 16'h00a5, "old data on high-byte write");
        we_a = 1'b0;
        @(posedge clk_a); #1;
        check_word(q_a, 16'h5aa5, "high-byte merge");

        // The independently-clocked read port sees the committed word after
        // its own active edge and holds it between edges.
        addr_b = 4'h2;
        @(posedge clk_b); #1;
        check_word(q_b, 16'h5aa5, "cross-clock port-B read");
        addr_b = 4'h3;
        #2;
        check_word(q_b, 16'h5aa5, "registered port-B hold");
        @(posedge clk_b); #1;
        check_word(q_b, 16'h0000, "registered port-B address");

        // Port B is genuinely bidirectional for work RAM; sprite/VRAM tie
        // this write interface low.
        data_b = 16'hbeef; be_b = 2'b11; we_b = 1'b1;
        @(posedge clk_b); #1;
        check_word(q_b, 16'h0000, "old data on port-B write");
        we_b = 1'b0;
        @(posedge clk_b); #1;
        check_word(q_b, 16'hbeef, "port-B full-word write");

        addr_a = 4'h3;
        @(posedge clk_a); #1;
        check_word(q_a, 16'hbeef, "port-B write visible on port A");

        $display("BIG DPRAM PASS");
        $finish;
    end
endmodule
