// Dedicated OutRunners profile regression for the Multi 32 analog-bank mux.
`timescale 1ns/1ps

module tb_core_orunners_analog;
    import s32_pkg::*;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    board_desc_t bd = '0;
    wire [7:0] adc [0:7];
    wire dv [0:2];
    wire signed [8:0] dx [0:2], dy [0:2];
    wire [7:0] tb [0:2];

    for (genvar i = 0; i < 8; i = i + 1)
        assign adc[i] = 8'h10 + i;
    for (genvar i = 0; i < 3; i = i + 1) begin
        assign dv[i] = 1'b0;
        assign dx[i] = '0;
        assign dy[i] = '0;
        assign tb[i] = 8'hff;
    end

    s32_core core (
        .clk_sys(clk), .clk_ram(clk), .rst(rst), .video_rst(1'b1), .board(bd),
        .ce_cpu(1'b0), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0),
        .sdr_p0_dout(16'h0), .sdr_p0_ack(1'b0),
        .sdr_p1_dout(64'h0), .sdr_p1_ack(1'b0),
        .sdr_p2_dout(128'h0), .sdr_p2_ack(1'b0),
        .sdr_p3_dout(16'h0), .sdr_p3_ack(1'b0),
        .sdr_p4_dout(16'h0), .sdr_p4_ack(1'b0),
        .sdr_p5_dout(64'h0), .sdr_p5_ack(1'b0),
        .fb_er_ack(1'b0), .fb_rd_ack(1'b0), .fb_rd_pix(16'hffff),
        .fb_wr_busy(1'b0),
        .v25_prg_wr(1'b0), .v25_prg_waddr(16'h0), .v25_prg_wdata(8'h0),
        .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0),
        .eep_rd_addr(6'h0), .eep_upload(1'b0),
        .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff),
        .in_svc12(8'hff), .in_svc34(8'hff),
        .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff),
        .in_svc12_b(8'hff), .in_svc34_b(8'hff),
        .adc_ch(adc), .trk_dv(dv), .trk_dx(dx), .trk_dy(dy), .trk_btn(tb),
        .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff)
    );

    task drive_bank(input select_bank_1);
    begin
        @(negedge clk);
        force core.m_req   = 1'b1;
        force core.m_we    = 1'b1;
        force core.m_addr  = 23'h600030; // byte address C00060
        if (select_bank_1)
            force core.m_wdata = 16'h0001;
        else
            force core.m_wdata = 16'h0000;
        force core.m_be    = 2'b01;
        @(posedge clk);
        #1;
        release core.m_req;
        release core.m_we;
        release core.m_addr;
        release core.m_wdata;
        release core.m_be;
    end
    endtask

    task drive_neighbor;
    begin
        @(negedge clk);
        force core.m_req   = 1'b1;
        force core.m_we    = 1'b1;
        force core.m_addr  = 23'h600031; // byte address C00062
        force core.m_wdata = 16'h0000;
        force core.m_be    = 2'b01;
        @(posedge clk);
        #1;
        release core.m_req;
        release core.m_we;
        release core.m_addr;
        release core.m_wdata;
        release core.m_be;
    end
    endtask

    task automatic expect_mux(
        input expected_bank,
        input [7:0] expected_an2,
        input [7:0] expected_an3
    );
    begin
        #1;
        if (core.g_extended_analog.analog_bank !== expected_bank ||
            core.g_extended_analog.adc.an0 !== 8'h10 ||
            core.g_extended_analog.adc.an1 !== 8'h11 ||
            core.g_extended_analog.adc.an2 !== expected_an2 ||
            core.g_extended_analog.adc.an3 !== expected_an3)
            $fatal(1,
                "OutRunners analog mux mismatch: bank=%b an=%02x/%02x/%02x/%02x",
                core.g_extended_analog.analog_bank,
                core.g_extended_analog.adc.an0,
                core.g_extended_analog.adc.an1,
                core.g_extended_analog.adc.an2,
                core.g_extended_analog.adc.an3);
    end
    endtask

    initial begin
`ifndef S32_OUTRUNNERS_ONLY
        $fatal(1, "tb_core_orunners_analog requires S32_OUTRUNNERS_ONLY");
`endif
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        if (core.OUTRUNNERS_ONLY !== 1'b1 || core.GAME_ONLY !== 1'b1 ||
            core.is_multi32 !== 1'b1)
            $fatal(1, "Dedicated OutRunners profile straps are not active");

        // Reset selects ANALOG3/4 for MSM6253 channels 2/3.
        expect_mux(1'b0, 8'h12, 8'h13);

        // The real Multi 32 C00060 low-byte register selects ANALOG7/8.
        drive_bank(1'b1);
        expect_mux(1'b1, 8'h16, 8'h17);

        // Nearby expansion addresses must not alias the bank register.
        drive_neighbor();
        expect_mux(1'b1, 8'h16, 8'h17);

        drive_bank(1'b0);
        expect_mux(1'b0, 8'h12, 8'h13);

        $display("CORE OUTRUNNERS ANALOG BANK PASS");
        $finish;
    end
endmodule
