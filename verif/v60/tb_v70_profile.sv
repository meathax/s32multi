// Runtime V60/V70 architectural-profile selection used by the universal core.
`timescale 1ns/1ps

module tb_v70_profile;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg is_v70 = 1'b0;
    always #5 clk = ~clk;

    s32_v60 #(.START_PC(32'hffff_fff0)) dut (
        .clk(clk), .ce(1'b1), .rst(rst), .is_v70(is_v70),
        .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
        .bus_req(), .bus_we(), .bus_addr(), .bus_size(), .bus_wdata(),
        .bus_rdata(32'd0), .bus_ack(1'b0),
        .irq_n(1'b1), .irq_vector(8'd0), .irq_ack(), .nmi_n(1'b1),
        .dbg_pc(), .dbg_halted()
    );

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;
        if (dut.pir !== 32'h0000_6000)
            $fatal(1, "V60 PIR mismatch: %08x", dut.pir);

        @(negedge clk);
        is_v70 = 1'b1;
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;
        if (dut.pir !== 32'h0000_7000)
            $fatal(1, "V70 PIR mismatch: %08x", dut.pir);

        $display("V70 PROFILE PASS");
        $finish;
    end
endmodule
