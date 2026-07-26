// elaboration-only top: instantiates s32_core to keep the full design honest
module tb_core_lint;
    import s32_pkg::*;
    board_desc_t bd = '0;
    wire [7:0] zeros8 = 8'h00;
    wire [7:0] adc [0:7];
    for (genvar i=0;i<8;i++) assign adc[i] = 8'h80;
    wire dv [0:2];
    wire signed [8:0] dx [0:2], dy [0:2];
    wire [7:0] tb [0:2];
    for (genvar i=0;i<3;i++) begin
        assign dv[i]=0; assign dx[i]=0; assign dy[i]=0; assign tb[i]=8'hff;
    end
    s32_core core (
        .clk_sys(1'b0), .clk_ram(1'b0), .rst(1'b1), .video_rst(1'b1), .board(bd),
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
        .eep_ld_wr(1'b0), .eep_ld_addr(6'h0), .eep_ld_data(16'h0), .eep_rd_addr(6'h0),
        .eep_upload(1'b0), .eep_modified(),
        .in_p1a(8'hff), .in_p2a(8'hff), .in_portc(8'hff), .in_svc12(8'hff), .in_svc34(8'hff),
        .in_p1b(8'hff), .in_p2b(8'hff), .in_portc_b(8'hff), .in_svc12_b(8'hff), .in_svc34_b(8'hff),
        .adc_ch(adc), .trk_dv(dv), .trk_dx(dx), .trk_dy(dy), .trk_btn(tb),
        .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff)
    );

    // Elaborate and execute this top twice: once as the universal source build
    // and once with -DS32_SYSTEM32_ONLY.  These checks prevent a future edit
    // from silently restoring the 128 KiB RAM or an independent Screen B to
    // the resource-constrained SegaS32 revision.
    initial begin
        #1; // allow continuous assignments to settle on event-strict simulators
`ifdef S32_OUTRUNNERS_ONLY
        if (core.SYSTEM32_ONLY !== 1'b0) $fatal(1, "OutRunners profile retained System32 pruning");
        if (core.WRAM_WORDS != 65536)    $fatal(1, "OutRunners work RAM is not 64K x 16");
        if (core.is_multi32 !== 1'b1)    $fatal(1, "OutRunners profile did not select Multi 32");
        if (core.OUTRUNNERS_ONLY !== 1'b1 || core.GAME_ONLY !== 1'b1)
            $fatal(1, "OutRunners release pruning not enabled");
        $display("CORE OUTRUNNERS PROFILE LINT PASS");
`elsif S32_SYSTEM32_ONLY
        if (core.SYSTEM32_ONLY !== 1'b1) $fatal(1, "System32 profile parameter not enabled");
        if (core.WRAM_WORDS != 32768)    $fatal(1, "System32 work RAM is not 32K x 16");
        if (core.is_multi32 !== 1'b0)   $fatal(1, "System32 profile accepted Multi 32 mode");
        #1;
        if (core.rgb_b !== core.rgb_a)  $fatal(1, "System32 Screen B output does not mirror A");
`ifdef S32_HOLO_ONLY
        if (core.GAME_ONLY !== 1'b1) $fatal(1, "Holosseum release pruning not enabled");
        $display("CORE HOLO PROFILE LINT PASS");
`elsif S32_JPARK_ONLY
        if (core.GAME_ONLY !== 1'b1) $fatal(1, "Jurassic Park release pruning not enabled");
        $display("CORE JPARK PROFILE LINT PASS");
`else
        $display("CORE S32-ONLY LINT PASS");
`endif
`else
        if (core.SYSTEM32_ONLY !== 1'b0) $fatal(1, "universal profile parameter unexpectedly enabled");
        if (core.WRAM_WORDS != 65536)    $fatal(1, "universal work RAM is not 64K x 16");
        $display("CORE UNIVERSAL LINT PASS");
`endif
        $finish;
    end
endmodule
