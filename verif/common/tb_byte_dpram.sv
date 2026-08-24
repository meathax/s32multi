`timescale 1ns/1ps

// Directed contract test for the common-clock byte-wide TDP block RAM.
module tb_byte_dpram;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [3:0] addr_a = 0;
    reg  [7:0] data_a = 0;
    reg        rden_a = 0;
    reg        wren_a = 0;
    wire [7:0] q_a;

    reg  [3:0] addr_b = 0;
    reg  [7:0] data_b = 0;
    reg        rden_b = 0;
    reg        wren_b = 0;
    wire [7:0] q_b;

    s32_byte_dpram #(.ADDR_WIDTH(4), .NUM_WORDS(16)) dut (
        .clock(clk),
        .address_a(addr_a), .data_a(data_a),
        .rden_a(rden_a), .wren_a(wren_a), .q_a(q_a),
        .address_b(addr_b), .data_b(data_b),
        .rden_b(rden_b), .wren_b(wren_b), .q_b(q_b)
    );

    task check_byte(input [7:0] got, input [7:0] want,
                    input [255:0] what);
        begin
            if (got !== want) begin
                $display("BYTE DPRAM FAIL: %0s got=%02x want=%02x",
                         what, got, want);
                $fatal(1);
            end
        end
    endtask

    initial begin
        // Port A: a write and the following read prove one-cycle registered
        // timing.  The unwritten old value is intentionally unspecified.
        addr_a = 4'h2; data_a = 8'ha5; rden_a = 1'b1; wren_a = 1'b1;
        @(posedge clk); #1;
        wren_a = 1'b0;
        @(posedge clk); #1;
        check_byte(q_a, 8'ha5, "port-A registered read");

        // Disabling a port's read holds q even while its address changes.
        rden_a = 1'b0; addr_a = 4'h7;
        @(posedge clk); #1;
        check_byte(q_a, 8'ha5, "port-A read-enable hold");

        // Port B sees memory only after its own active read edge.
        addr_b = 4'h2; rden_b = 1'b1;
        @(posedge clk); #1;
        check_byte(q_b, 8'ha5, "cross-port committed read");

        // Same-port read-during-write returns the old byte in simulation;
        // clients ignore q during this cycle in synthesized hardware.
        data_b = 8'h5a; wren_b = 1'b1;
        @(posedge clk); #1;
        check_byte(q_b, 8'ha5, "old data on port-B write");
        wren_b = 1'b0;
        @(posedge clk); #1;
        check_byte(q_b, 8'h5a, "port-B write committed");

        // Preload an address for the observable mixed-port collision case.
        addr_a = 4'h4; data_a = 8'h11; rden_a = 1'b1; wren_a = 1'b1;
        rden_b = 1'b0;
        @(posedge clk); #1;
        wren_a = 1'b0;
        @(posedge clk); #1;
        check_byte(q_a, 8'h11, "collision preload");

        // A reads while B writes the same byte: both the old RTL and the
        // M10K mixed-port setting expose old data, then the new byte next edge.
        addr_b = 4'h4; data_b = 8'h22; rden_b = 1'b1; wren_b = 1'b1;
        @(posedge clk); #1;
        check_byte(q_a, 8'h11, "mixed-port old data on port A");
        check_byte(q_b, 8'h11, "mixed-port old data on port B");
        wren_b = 1'b0;
        @(posedge clk); #1;
        check_byte(q_a, 8'h22, "mixed-port write committed on A");
        check_byte(q_b, 8'h22, "mixed-port write committed on B");

        // Independent simultaneous writes prove both ports are bidirectional.
        addr_a = 4'h5; data_a = 8'haa; wren_a = 1'b1;
        addr_b = 4'h6; data_b = 8'h66; wren_b = 1'b1;
        @(posedge clk); #1;
        wren_a = 1'b0; wren_b = 1'b0;
        @(posedge clk); #1;
        check_byte(q_a, 8'haa, "simultaneous port-A write");
        check_byte(q_b, 8'h66, "simultaneous port-B write");

        $display("BYTE DPRAM PASS");
        $finish;
    end
endmodule
