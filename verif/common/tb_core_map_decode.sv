// Focused conformance checks for the official MAME System 32 main map.
`timescale 1ns/1ps

module tb_core_map_decode;
    import s32_pkg::*;

    reg clk = 0;
    always #5 clk = ~clk;

    board_desc_t bd = '0;
    wire [7:0] adc [0:7];
    wire dv [0:2];
    wire signed [8:0] dx [0:2], dy [0:2];
    wire [7:0] tb [0:2];
    for (genvar i=0;i<8;i++) assign adc[i] = 8'h80;
    for (genvar i=0;i<3;i++) begin
        assign dv[i]=0; assign dx[i]=0; assign dy[i]=0; assign tb[i]=8'hff;
    end

    reg core_rst = 1'b1;

    s32_core core (
        .clk_sys(clk), .clk_ram(clk), .rst(core_rst), .video_rst(core_rst), .board(bd),
        .ce_cpu(1'b0), .ce_z80(1'b0), .ce_fm(1'b0), .ce_pcm(1'b0), .pause(1'b0), .fast_v60(1'b0),
        .sdr_p0_dout(64'h0), .sdr_p0_ack(1'b0),
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
        .adc_ch(adc),
        .ppi_pa(8'hff), .ppi_pb(8'hff), .ppi_pc(8'hff),
        .screen_sel(1'b0)
    );

    reg [23:0] probe;
    integer errors = 0;

    task automatic expect_decode(
        input [23:0] addr,
        input pal0, input mix0, input io0, input ioex,
        input ppi, input v25
    );
    begin
        probe = addr;
        #1;
        if (core.is_pal0 !== pal0 || core.is_mix0 !== mix0 ||
            core.sel_io0 !== io0 || core.sel_ioex !== ioex ||
            core.sel_ppi !== ppi || core.sel_v25 !== v25) begin
            $display("FAIL map %06x pal=%b/%b mix=%b/%b io=%b/%b ex=%b/%b ppi=%b/%b v25=%b/%b",
                addr, core.is_pal0,pal0, core.is_mix0,mix0,
                core.sel_io0,io0, core.sel_ioex,ioex,
                core.sel_ppi,ppi, core.sel_v25,v25);
            errors = errors + 1;
        end
    end
    endtask

    initial begin
        // has_ppi/has_v25 are no longer selectable: cfg_has_ppi is hardcoded
        // 0 in s32_core.sv (this board has no PPI, no V25) regardless of the
        // descriptor, so sel_ppi never fires -- see the flipped expect_decode
        // ppi=0 below and the removed PPI bus-seam test.
        bd.comm_link_hle = 1'b1;
        force core.A = probe;

        // 0x600000/0x610000 windows, including A18:A17 mirrors. A19 is no
        // longer a mirror bit here: this board is always Multi 32
        // (is_multi32 is a build constant), so A19 genuinely selects
        // screen A (0) vs screen B/pal1-mix1 (1) -- the two addresses below
        // keep A19=0 to stay in screen-A/pal0-mix0 territory while still
        // varying A18/A17 to prove those remain don't-care.
        expect_decode(24'h600000, 1,0,0,0,0,0);
        expect_decode(24'h661234, 1,0,0,0,0,0);
        expect_decode(24'h610000, 0,1,0,0,0,0);
        expect_decode(24'h670000, 0,1,0,0,0,0);

        // 315-5296: 00-1f only; A19:A7 are mirrors. Expansion has A6 set.
        expect_decode(24'hc00000, 0,0,1,0,0,0);
        expect_decode(24'hc51280, 0,0,1,0,0,0);
        expect_decode(24'hc00020, 0,0,0,0,0,0);
        expect_decode(24'hc00040, 0,0,0,1,0,0);
        // Original address (0xcabc60) had A19=1, which under always-on
        // Multi 32 selects io1's 0xC8xxxx window, not this ioex mirror --
        // moved to an A19=0 address to keep testing what this line means to
        // test (ioex mirroring). Also no longer expects ppi=1: the PPI
        // (s32_i8255) was removed and cfg_has_ppi is hardcoded 0 in
        // s32_core.sv, so sel_ppi can never fire regardless of descriptor.
        expect_decode(24'hc0abe0, 0,0,0,1,0,0);
        expect_decode(24'hc00068, 0,0,0,1,0,0);

        // GA2's MB8421 right-side window is not mirrored across 0xAxxxxx.
        expect_decode(24'ha00000, 0,0,0,0,0,1);
        expect_decode(24'ha00ffe, 0,0,0,0,0,1);
        expect_decode(24'ha01000, 0,0,0,0,0,0);

        // IO-7: s32comm share RAM occupies 0x800000-0x800fff only; the cn/fg
        // link registers at 0x801000+ are in the comm page but not share RAM.
        probe = 24'h800000; #1;
        if (core.sel_comm !== 1'b1 || core.sel_comm_ram !== 1'b1) begin
            $display("FAIL comm share @800000 comm=%b ram=%b", core.sel_comm, core.sel_comm_ram);
            errors = errors + 1;
        end
        probe = 24'h800ffe; #1;
        if (core.sel_comm_ram !== 1'b1) begin
            $display("FAIL comm share @800ffe ram=%b", core.sel_comm_ram);
            errors = errors + 1;
        end
        probe = 24'h801000; #1;   // cn register: comm page, not share RAM
        if (core.sel_comm !== 1'b1 || core.sel_comm_ram !== 1'b0 ||
            core.sel_comm_cn !== 1'b1 || core.sel_comm_fg !== 1'b0) begin
            $display("FAIL comm CN @801000 comm=%b ram=%b cn=%b fg=%b",
                core.sel_comm, core.sel_comm_ram, core.sel_comm_cn, core.sel_comm_fg);
            errors = errors + 1;
        end
        probe = 24'h801002; #1;   // fg register
        if (core.sel_comm !== 1'b1 || core.sel_comm_ram !== 1'b0 ||
            core.sel_comm_cn !== 1'b0 || core.sel_comm_fg !== 1'b1) begin
            $display("FAIL comm FG @801002 comm=%b ram=%b cn=%b fg=%b",
                core.sel_comm, core.sel_comm_ram, core.sel_comm_cn, core.sel_comm_fg);
            errors = errors + 1;
        end
        probe = 24'h801004; #1;   // rest of communication page stays open bus
        if (core.sel_comm_cn !== 1'b0 || core.sel_comm_fg !== 1'b0) begin
            $display("FAIL comm hole @801004 cn=%b fg=%b",
                core.sel_comm_cn, core.sel_comm_fg);
            errors = errors + 1;
        end

        // Exercise the MAME s32comm bit-0 write contract without starting a
        // CPU: CN accepts a write, FG accepts one only while CN is set, and
        // cn_w(0) resets FG before disabled-board writes are ignored.
        core_rst = 1'b0;
        force core.m_req = 1'b1;
        force core.m_we = 1'b1;
        force core.m_be = 2'b01;
        force core.m_wdata = 16'h0001;
        probe = 24'h801000; @(posedge clk); #1;
        if (core.comm_cn !== 1'b1) begin
            $display("FAIL comm CN write cn=%b", core.comm_cn);
            errors = errors + 1;
        end
        probe = 24'h801002; @(posedge clk); #1;
        if (core.comm_fg !== 1'b1) begin
            $display("FAIL comm FG write while enabled fg=%b", core.comm_fg);
            errors = errors + 1;
        end
        force core.m_wdata = 16'h0000;
        probe = 24'h801000; @(posedge clk); #1;
        if (core.comm_cn !== 1'b0 || core.comm_fg !== 1'b0) begin
            $display("FAIL disabled comm reset cn=%b fg=%b", core.comm_cn, core.comm_fg);
            errors = errors + 1;
        end
        force core.m_wdata = 16'h0001;
        probe = 24'h801002; @(posedge clk); #1;
        if (core.comm_fg !== 1'b0) begin
            $display("FAIL disabled comm FG write changed fg=%b", core.comm_fg);
            errors = errors + 1;
        end
        release core.m_req;
        release core.m_we;
        release core.m_be;
        release core.m_wdata;
        core_rst = 1'b1;
        @(posedge clk); #1;
        if (core.comm_cn !== 1'b0 || core.comm_fg !== 1'b0) begin
            $display("FAIL comm reset cn=%b fg=%b", core.comm_cn, core.comm_fg);
            errors = errors + 1;
        end

        // The EPR-14084 HLE publishes MAME's one-node online status after
        // the link timer expires. Force the boundary for a short focused test.
        core_rst = 1'b0;
        force core.m_req = 1'b1;
        force core.m_we = 1'b1;
        force core.m_be = 2'b01;
        force core.m_wdata = 16'h0001;
        probe = 24'h801000; @(posedge clk); #1;
        release core.m_req;
        release core.m_we;
        release core.m_be;
        release core.m_wdata;
        force core.comm_link_timer = 16'd1;
        force core.vbl_start = 1'b1;
        @(posedge clk); #1;
        release core.vbl_start;
        release core.comm_link_timer;
        // The RAM-inference-safe publisher writes bytes 0, 1 and 4 on three
        // consecutive clocks, then raises status with the final byte.
        repeat (3) @(posedge clk);
        #1;
        if (core.comm_link_status !== 1'b1 || core.comm_ram[4] !== 8'h01) begin
            $display("FAIL comm link HLE status=%b shared4=%02x",
                core.comm_link_status, core.comm_ram[4]);
            errors = errors + 1;
        end
        core_rst = 1'b1;
        @(posedge clk); #1;

        if (errors == 0) $display("CORE MAP DECODE PASS");
        else $fatal(1, "CORE MAP DECODE FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
