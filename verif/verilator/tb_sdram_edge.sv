//============================================================================
//  tb_sdram_edge.sv  —  Independent Verilator cross-validation of the
//  sdram.sv six-port arbitration / rising-edge request-latch fix.
//
//  WHY THIS EXISTS
//  ---------------
//  The ga2/arabfgt black-screen root cause was sdram.sv silently DROPPING a
//  request whose rising edge landed while the previous ack/pend was clearing
//  (the V60 icache-fill chain).  The fix (edge-latch req + clear pend on ack
//  rising edge, clear-before-set ordering) was verified only in ModelSim, and
//  every ModelSim TB models clk_sys rising HALF A clk_ram PERIOD OFFSET from
//  clk_ram.  The real MiSTer PLL emits clk_sys EDGE-ALIGNED with clk_ram.  The
//  audit claims the edge-detect fix is "phase-independent" but that was never
//  simulated in the edge-aligned configuration hardware actually uses.
//
//  This testbench closes that gap in an INDEPENDENT simulator (Verilator):
//    * Drives clk_sys either EDGE-ALIGNED (default, = hardware PLL) or
//      HALF-OFFSET (`+define+HALF_OFFSET`, = the ModelSim TBs) so the same
//      stimulus proves both phases.
//    * Retains the historical four-exact-word V60 icache-fill chain on p0 as
//      an adversarial edge-latch regression: every next request rises the
//      clk_sys cycle after its ack — the exact drop pattern.  Production now
//      fills a line with one p0 burst; tb_sdram_p0_throughput covers that path.
//    * Runs concurrent p5 (V25) bursts to reshuffle arbitration parity — the
//      real trigger that sank ga2 while lighter boards never faulted.
//    * Scoreboards req-vs-ack counts and hard-fails on any hung transaction.
//
//  Same module name `sdram`, so it links against either the production RTL or
//  a pre-fix reconstruction to prove the test has teeth.
//============================================================================
`timescale 1ns/1ps

module tb_sdram_edge;

    // ---- clocks -----------------------------------------------------------
    // clk_ram ~96.6MHz modelled at 10ns period (posedges at 5,15,25,...).
    reg clk_ram = 1'b0;
    always #5 clk_ram = ~clk_ram;

    // clk_sys = clk_ram/2.  Phase selects the coupling under test:
    //   EDGE-ALIGNED (default): clk_sys posedges coincide with clk_ram posedges
    //   HALF-OFFSET (+define+HALF_OFFSET): clk_sys posedges fall between them
    reg clk_sys = 1'b0;
`ifdef HALF_OFFSET
    initial begin           #0; forever #10 clk_sys = ~clk_sys; end // posedge @10,30,50 (between)
`else
    initial begin clk_sys = 1'b0; #5; forever #10 clk_sys = ~clk_sys; end // posedge @15,35,55 (aligned)
`endif

    // ---- DUT wiring -------------------------------------------------------
    reg         init = 1'b1;
    wire        ready;
    reg         started = 1'b0;   // gates requesters + watchdog until post-init

    wire [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

    // p0 (V60), p5 (V25) driven; other ports idle.
    reg         p0_req = 0;  reg [24:1] p0_addr = 0;  wire [63:0] p0_dout;  wire p0_ack;
    reg         p5_req = 0;  reg [24:3] p5_addr = 0;  wire [63:0] p5_dout;  wire p5_ack;

    sdram dut (
        .clk(clk_ram), .init(init), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
        // download write port — idle
        .wr_req(1'b0), .wr_addr(24'd0), .wr_din(16'd0), .wr_be(2'b11), .wr_ack(),
        .p0_req(p0_req), .p0_burst(1'b0), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
        .p1_req(1'b0), .p1_addr(22'd0), .p1_dout(), .p1_ack(),
        .p2_req(1'b0), .p2_addr(21'd0), .p2_dout(), .p2_ack(),
        .p3_req(1'b0), .p3_addr(24'd0), .p3_dout(), .p3_ack(),
        .p4_req(1'b0), .p4_addr(24'd0), .p4_dout(), .p4_ack(),
        .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
    );

    // ---- behavioural SDRAM chip model -------------------------------------
    // Drives DQ with a defined pattern except while the controller is writing
    // (auto-precharge single-word writes), so the controller never captures X
    // on reads.  Data values are NOT the subject of this test (arbitration is),
    // so the pattern only guarantees a defined, non-Z bus during reads.
    localparam [3:0] CMD_WRITE = 4'b0100;
    wire [3:0] chip_cmd = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
    reg  [2:0] wr_win = 0;
    reg [15:0] pat = 16'hA5A5;
    always @(posedge clk_ram) begin
        if (chip_cmd == CMD_WRITE) wr_win <= 3'd3;
        else if (wr_win != 0)      wr_win <= wr_win - 1'b1;
        pat <= pat + 16'h0101;
    end
    assign SDRAM_DQ = (wr_win == 0) ? pat : 16'hZZZZ;

    // ---- scoreboard -------------------------------------------------------
    integer p0_issued = 0, p0_acked = 0;
    integer p5_issued = 0, p5_acked = 0;
    integer p0_wait   = 0;               // clk_ram cycles p0 has waited for ack
    localparam integer HANG_LIMIT = 400; // >> worst-case arbitration + refresh
    localparam integer P0_TARGET  = 64;  // sequential V60 fetches to complete

    // p0 ack edge detect (ack is 2 clk_ram wide; count one per rising edge)
    reg p0_ack_d = 0, p5_ack_d = 0;
    always @(posedge clk_ram) begin
        p0_ack_d <= p0_ack;
        p5_ack_d <= p5_ack;
        if (p0_ack && !p0_ack_d) p0_acked <= p0_acked + 1;
        if (p5_ack && !p5_ack_d) p5_acked <= p5_acked + 1;
        // hang watchdog (clk_ram domain): a p0 line-fill is outstanding but no
        // fresh ack arrives -> a chained request was dropped (the bug).  Resets
        // on every ack (forward progress); fires if a single word stalls.
        if (!p0_out || !started) p0_wait <= 0;
        else if (p0_ack)         p0_wait <= 0;
        else begin
            p0_wait <= p0_wait + 1;
            if (p0_wait > HANG_LIMIT) begin
                $display("*** FAIL: p0 line-fill HUNG at word %0d (%0d clk_ram cycles, no ack). addr=%06h",
                         fill_word, p0_wait, p0_addr);
                $display("*** This is the request-drop signature the sdram edge-latch fix must prevent.");
                dump_and_finish(1);
            end
        end
    end

    // ---- p0 requester: historical exact-word cache-fill stress ------------
    // This deliberately retains the pre-burst four-request pattern: each
    // word's request is a single clk_sys-cycle pulse, and word N+1 rises in the
    // same clk_sys cycle that observes word N's ack.  That collision remains
    // the strongest regression for the edge-latch clear-before-set contract,
    // even though production V60 misses now use one four-beat p0 transaction.
    reg        rom_filling = 1'b0;
    reg [1:0]  fill_word   = 2'd0;
    reg [23:0] line_base   = 24'h010000;
    reg        p0_out      = 1'b0;       // a p0 transaction is outstanding
    always @(posedge clk_sys) if (started) begin
        p0_req <= 1'b0;                  // single-cycle pulse default
        if (!rom_filling) begin
            if (p0_issued < P0_TARGET) begin       // icache miss -> start fill
                rom_filling <= 1'b1;
                fill_word   <= 2'd0;
                p0_req      <= 1'b1;
                p0_addr     <= line_base;
                p0_issued   <= p0_issued + 1;
                p0_out      <= 1'b1;
            end
        end
        else if (p0_ack) begin
            if (fill_word == 2'd3) begin           // line complete
                rom_filling <= 1'b0;
                line_base   <= line_base + 24'd4;
                p0_out      <= 1'b0;
            end
            else begin                             // chain next word THIS cycle
                fill_word <= fill_word + 1'b1;
                p0_req    <= 1'b1;
                p0_addr   <= line_base + {22'b0, (fill_word + 2'd1)};
                p0_issued <= p0_issued + 1;
            end
        end
    end

    // ---- p5 requester: concurrent V25 program bursts (parity perturber) ---
    // Free-running back-to-back 4-word bursts, offset from p0 to reshuffle
    // each ack's clk_ram parity (the effect that made ga2 fault, not holo).
    localparam P5_IDLE=0, P5_WAIT=1;
    reg     p5_st = P5_IDLE;
    integer p5delay = 0;             // +p5delay=N : hold p5 N clk_sys cycles to
    reg     p5_armed = 1'b0;         // sweep arbitration parity vs p0
    integer p5cnt = 0;
    always @(posedge clk_sys) if (started) begin
        if (!p5_armed) begin
            if (p5cnt >= p5delay) p5_armed <= 1'b1;
            else p5cnt <= p5cnt + 1;
        end
        else case (p5_st)
        P5_IDLE: begin
            p5_req  <= 1'b1;
            p5_addr <= 22'h020000 + (p5_issued << 2);
            p5_st   <= P5_WAIT;
        end
        P5_WAIT: if (p5_ack) begin
            p5_req    <= 1'b0;
            p5_issued <= p5_issued + 1;
            p5_st     <= P5_IDLE;
        end
        endcase
    end

    // ---- run control ------------------------------------------------------
    task dump_and_finish(input integer code);
        begin
            $display("---- SUMMARY (%0s phase) ----",
`ifdef HALF_OFFSET "HALF-OFFSET" `else "EDGE-ALIGNED" `endif );
            $display("  p0 (V60 icache chain): issued=%0d  acked=%0d", p0_issued, p0_acked);
            $display("  p5 (V25 bursts)      : issued=%0d  acked=%0d", p5_issued, p5_acked);
            if (code==0) $display("  RESULT: PASS  (every request serviced exactly once, no hang)");
            else         $display("  RESULT: FAIL");
            $finish;
        end
    endtask

    integer global_timeout;
    initial begin
        void'($value$plusargs("p5delay=%d", p5delay));
        $dumpfile("verif/verilator/tb_sdram_edge.vcd");
        $dumpvars(0, tb_sdram_edge);
        // release init after a few clk_ram cycles
        repeat (8) @(posedge clk_ram);
        init <= 1'b0;
        // wait for controller init sequencer (0xFFFF countdown) to assert ready
        @(posedge ready);
        repeat (4) @(posedge clk_sys);   // align to a clean clk_sys edge
        started <= 1'b1;
        $display("[%0t] SDRAM ready — starting V60 icache chain (%0s phase)", $time,
`ifdef HALF_OFFSET "HALF-OFFSET" `else "EDGE-ALIGNED" `endif );

        // run until p0 completes its target or global timeout
        for (global_timeout = 0; global_timeout < 2_000_000; global_timeout = global_timeout + 1) begin
            @(posedge clk_ram);
            if (p0_issued >= P0_TARGET && !p0_req) begin
                // let any in-flight p5 settle
                repeat (50) @(posedge clk_ram);
                if (p0_acked == P0_TARGET) dump_and_finish(0);
                else begin
                    $display("*** FAIL: p0 issued=%0d but only acked=%0d (lost %0d)",
                             p0_issued, p0_acked, p0_issued - p0_acked);
                    dump_and_finish(1);
                end
            end
        end
        $display("*** FAIL: global timeout before completing %0d p0 transactions (got %0d)",
                 P0_TARGET, p0_issued);
        dump_and_finish(1);
    end

endmodule
