//============================================================================
//  File-driven 315-5386A differential replay bench.
//
//  Inputs are prepared from an s32.sprite.v1 manifest by run.py.  This bench
//  intentionally contains no renderer model: it captures only production RTL
//  writes into a physical 416x224 u16 framebuffer for byte-exact comparison
//  with the independent MAME-derived oracle.
//============================================================================
`timescale 1ns/1ps

module tb_sprite_replay;

localparam integer FB_WIDTH = 416;
localparam integer FB_HEIGHT = 224;
localparam integer FB_PIXELS = FB_WIDTH * FB_HEIGHT;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1;

string sram_path, rom_path, back_path, out_path;
integer rom_chunks, max_cycles, seed, rom_stall_mask, fb_stall_enable;
integer sprite_bank_mask;
integer c0, c1, c2, c3, c4, c5, c6, c7;
reg [7:0] controls [0:7];

reg [15:0] sram [0:65535];
reg [127:0] rom128 [0:1048575];
reg [15:0] fb [0:FB_PIXELS-1];

wire [15:0] slist_addr;
reg  [15:0] slist_q;
always @(posedge clk) slist_q <= sram[slist_addr];

wire        srom_req;
wire [23:4] srom_addr;
reg         srom_ack = 1'b0;
reg [127:0] srom_data = 128'd0;

wire        fb_wr_start, fb_wr_valid, fb_wr_end, fb_wr_shadow;
wire  [1:0] fb_wr_buf;
wire  [8:0] fb_wr_x;
wire  [7:0] fb_wr_y;
wire [15:0] fb_wr_pix;
wire        fb_er_req;
wire  [1:0] fb_er_buf;
wire  [7:0] fb_er_y;
`ifdef S32_REPLAY_REAL_FB
wire        fb_er_ack;
wire        fb_busy;
`else
reg         fb_er_ack = 1'b0;
wire        fb_busy;
`endif
wire  [1:0] disp_buf;
wire        rendering;
reg         vblank = 1'b0;

reg ctl_we = 1'b0;
reg [2:0] ctl_addr = 3'd0;
reg [7:0] ctl_wdata = 8'd0;

reg [31:0] lfsr = 32'h5386_a5c3;
`ifndef S32_REPLAY_REAL_FB
assign fb_busy = fb_stall_enable != 0 && rendering && lfsr[0] && lfsr[5];
`endif
always @(posedge clk) begin
    if (rst)
        lfsr <= seed ^ 32'h5386_a5c3;
    else
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
end

s32_sprite #(.VERIFY_SROM(1'b1)) dut (
    .clk(clk), .rst(rst), .is_multi32(1'b0), .screen_sel(1'b0),
    .present(1'b0),
    .verify_srom(1'b1),
    .srom_bank_mask(sprite_bank_mask[1:0]),
    .vblank(vblank),
    .ctl_we(ctl_we), .ctl_addr(ctl_addr), .ctl_wdata(ctl_wdata),
    .ctl_rdata(), .ctl_raddr(3'd0),
    .slist_addr(slist_addr), .slist_data(slist_q),
    .srom_req(srom_req), .srom_addr(srom_addr),
    .srom_data(srom_data), .srom_ack(srom_ack),
    .fb_wr_start(fb_wr_start), .fb_wr_buf(fb_wr_buf),
    .fb_wr_x(fb_wr_x), .fb_wr_y(fb_wr_y),
    .fb_wr_valid(fb_wr_valid), .fb_wr_pix(fb_wr_pix),
    .fb_wr_end(fb_wr_end), .fb_wr_shadow(fb_wr_shadow),
    .fb_busy(fb_busy),
    .fb_er_req(fb_er_req), .fb_er_buf(fb_er_buf),
    .fb_er_y(fb_er_y), .fb_er_ack(fb_er_ack),
    .disp_buf(disp_buf), .scan_buf()
);
assign rendering = dut.rs != 0;

integer errors = 0;
integer cycles = 0;
integer rom_requests = 0;
integer fb_writes = 0;
integer fb_runs = 0;
integer fb_run_ends = 0;

// -------------------------------------------------------------------------
// Bounded-latency sprite-ROM service and protocol assertions.
// -------------------------------------------------------------------------
reg rom_outstanding = 1'b0;
reg rom_acked = 1'b0;
reg [23:4] rom_addr_latched = 20'd0;
integer rom_fault_once = 0;
reg rom_fault_done = 1'b0;
integer rom_wait = 0;
always @(posedge clk) begin
    srom_ack <= 1'b0;
    if (rst) begin
        rom_outstanding <= 1'b0;
        rom_acked <= 1'b0;
        rom_fault_done <= 1'b0;
        rom_wait <= 0;
    end
    else if (!rom_outstanding && srom_req) begin
        if (^srom_addr === 1'bx) begin
            errors = errors + 1;
            $display("REPLAY ASSERT FAIL: X sprite-ROM address");
        end
        rom_outstanding <= 1'b1;
        rom_acked <= 1'b0;
        rom_addr_latched <= srom_addr;
        rom_wait <= lfsr[7:0] & rom_stall_mask;
        rom_requests = rom_requests + 1;
    end
    else if (rom_outstanding && !rom_acked) begin
        if (!srom_req) begin
            errors = errors + 1;
            $display("REPLAY ASSERT FAIL: sprite-ROM request dropped before ACK");
            rom_outstanding <= 1'b0;
        end
        else if (srom_addr !== rom_addr_latched) begin
            errors = errors + 1;
            $display("REPLAY ASSERT FAIL: sprite-ROM address changed under wait %05x -> %05x",
                     rom_addr_latched, srom_addr);
        end
        else if (rom_wait != 0)
            rom_wait <= rom_wait - 1;
        else begin
            if (rom_addr_latched >= rom_chunks) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: sprite-ROM chunk %05x >= loaded %0d",
                         rom_addr_latched, rom_chunks);
                srom_data <= {128{1'b1}};
            end
            else if (rom_fault_once != 0 && !rom_fault_done) begin
                // One deliberately corrupt response proves the production
                // renderer discards a mismatched verification pair.
                srom_data <= rom128[rom_addr_latched] ^ 128'h1;
                rom_fault_done <= 1'b1;
            end
            else
                srom_data <= rom128[rom_addr_latched];
            srom_ack <= 1'b1;
            rom_acked <= 1'b1;
        end
    end
    else if (rom_outstanding && rom_acked) begin
        if (!srom_req) begin
            rom_outstanding <= 1'b0;
            rom_acked <= 1'b0;
        end
    end
end

`ifdef S32_REPLAY_REAL_FB
// Exact integration mode: route the production renderer through the same
// framebuffer RTL and deterministic MiSTer-style DDR model as real-ROM
// qualification. Direct-render fixtures start from a transparent buffer.
wire [31:0] model_write_accepts, model_read_accepts, model_line_acks;
wire [31:0] model_max_wr_wait, model_max_rd_wait, model_max_er_wait;
wire        model_deadline_fail;
s32_fb_ddr_model fb_model (
    .clk(clk), .rst(rst),
    .wr_start(fb_wr_start), .wr_buf(fb_wr_buf),
    .wr_x(fb_wr_x), .wr_y(fb_wr_y), .wr_valid(fb_wr_valid),
    .wr_pix(fb_wr_pix), .wr_end(fb_wr_end), .wr_shadow(fb_wr_shadow),
    .wr_busy(fb_busy),
    .er_req(fb_er_req), .er_buf(fb_er_buf), .er_y(fb_er_y), .er_ack(fb_er_ack),
    .rd_req(1'b0), .rd_buf(2'd0),
    .rd_y(8'd0), .rd_ack(),
    .rd_x(9'd0), .rd_pix(),
    .write_accepts(model_write_accepts), .read_accepts(model_read_accepts),
    .line_acks(model_line_acks), .max_wr_wait(model_max_wr_wait),
    .max_rd_wait(model_max_rd_wait), .max_er_wait(model_max_er_wait),
    .deadline_fail(model_deadline_fail)
);
`else
// Erase is not part of a direct render event, but acknowledge it with bounded
// behavior so an accidental controller command cannot deadlock silently.
always @(posedge clk) begin
    fb_er_ack <= fb_er_req;
end
`endif

// -------------------------------------------------------------------------
// Physical framebuffer sink and write-run liveness checks.
// -------------------------------------------------------------------------
reg run_active = 1'b0;
integer run_age = 0;
always @(posedge clk) begin
    if (rst) begin
        run_active <= 1'b0;
        run_age <= 0;
    end
    else begin
        if (run_active) begin
            run_age <= run_age + 1;
            if (run_age > 200000) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: framebuffer run failed to terminate");
                run_age <= 0;
            end
        end
        if (fb_wr_start) begin
            if (run_active) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: framebuffer run started while active");
            end
            run_active <= 1'b1;
            run_age <= 0;
            fb_runs = fb_runs + 1;
        end
        if (fb_wr_valid) begin
            if (!run_active) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: framebuffer pixel outside run");
            end
            if (^fb_wr_x === 1'bx || ^fb_wr_y === 1'bx || ^fb_wr_pix === 1'bx) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: X on framebuffer write");
            end
            else if (fb_wr_x >= FB_WIDTH || fb_wr_y >= FB_HEIGHT) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: framebuffer write outside 416x224 (%0d,%0d)",
                         fb_wr_x, fb_wr_y);
            end
            else begin
`ifndef S32_REPLAY_REAL_FB
                if (fb_wr_shadow)
                    fb[fb_wr_y * FB_WIDTH + fb_wr_x] <=
                        fb[fb_wr_y * FB_WIDTH + fb_wr_x] & 16'h7fff;
                else
                    fb[fb_wr_y * FB_WIDTH + fb_wr_x] <= fb_wr_pix;
`endif
                fb_writes = fb_writes + 1;
            end
        end
        if (fb_wr_end) begin
            if (!run_active) begin
                errors = errors + 1;
                $display("REPLAY ASSERT FAIL: framebuffer run ended while idle");
            end
            run_active <= 1'b0;
            run_age <= 0;
            fb_run_ends = fb_run_ends + 1;
        end
    end
end

always @(posedge clk) begin
    if (!rst) begin
        cycles = cycles + 1;
        // slist_addr is don't-care in idle/reset and is first assigned by
        // R_FETCH. Require it known only while consuming registered RAM data.
        if ((dut.rs == dut.R_FETCHW || dut.rs == dut.R_INDTABW ||
             dut.rs == dut.R_RAMDATAW) && ^slist_addr === 1'bx) begin
            errors = errors + 1;
            $display("REPLAY ASSERT FAIL: X sprite-list address");
        end
        if (dut.list_count > 14'd8192) begin
            errors = errors + 1;
            $display("REPLAY ASSERT FAIL: list count exceeded hardware bound");
        end
    end
end

task write_control(input [2:0] address, input [7:0] value);
begin
    @(negedge clk);
    ctl_we = 1'b1;
    ctl_addr = address;
    ctl_wdata = value;
    @(negedge clk);
    ctl_we = 1'b0;
end
endtask

integer init_i;
integer init_buf, init_y, init_word;
integer out_fd;
integer out_x, out_y, out_word, out_lane;
initial begin
    if (!$value$plusargs("SPRRAM=%s", sram_path))
        $fatal(1, "missing +SPRRAM=<hex>");
    if (!$value$plusargs("SROM=%s", rom_path))
        $fatal(1, "missing +SROM=<hex>");
    if (!$value$plusargs("BACK=%s", back_path))
        $fatal(1, "missing +BACK=<hex>");
    if (!$value$plusargs("OUT=%s", out_path))
        $fatal(1, "missing +OUT=<hex>");
    if (!$value$plusargs("ROMCHUNKS=%d", rom_chunks)) rom_chunks = 0;
    if (!$value$plusargs("MAXCYCLES=%d", max_cycles)) max_cycles = 50000000;
    if (!$value$plusargs("SEED=%d", seed)) seed = 342122;
    if (!$value$plusargs("ROMSTALL=%d", rom_stall_mask)) rom_stall_mask = 7;
    if (!$value$plusargs("ROMFAULT=%d", rom_fault_once)) rom_fault_once = 0;
    if (!$value$plusargs("FBSTALL=%d", fb_stall_enable)) fb_stall_enable = 1;
    if (!$value$plusargs("SBM=%h", sprite_bank_mask)) sprite_bank_mask = 3;
    if (!$value$plusargs("C0=%h", c0)) c0 = 0;
    if (!$value$plusargs("C1=%h", c1)) c1 = 0;
    if (!$value$plusargs("C2=%h", c2)) c2 = 0;
    if (!$value$plusargs("C3=%h", c3)) c3 = 0;
    if (!$value$plusargs("C4=%h", c4)) c4 = 0;
    if (!$value$plusargs("C5=%h", c5)) c5 = 0;
    if (!$value$plusargs("C6=%h", c6)) c6 = 0;
    if (!$value$plusargs("C7=%h", c7)) c7 = 0;
    controls[0]=c0; controls[1]=c1; controls[2]=c2; controls[3]=c3;
    controls[4]=c4; controls[5]=c5; controls[6]=c6; controls[7]=c7;

    if (rom_chunks <= 0 || rom_chunks > 1048576)
        $fatal(1, "invalid ROMCHUNKS=%0d", rom_chunks);
    $readmemh(sram_path, sram);
    $readmemh(rom_path, rom128, 0, rom_chunks - 1);
    $readmemh(back_path, fb);

    repeat (8) @(posedge clk);
`ifdef S32_REPLAY_REAL_FB
    // The direct oracle starts from the fixture's physical back framebuffer.
    // Seed every production DDR slot with that same image so integrated mode
    // compares rendering semantics as well as protocol/backpressure.  The old
    // all-transparent DDR initialization made untouched/randomized fixture
    // pixels look like renderer mismatches and happened to assume A/B only.
    for (init_buf = 0; init_buf < 4; init_buf = init_buf + 1) begin
        for (init_y = 0; init_y < FB_HEIGHT; init_y = init_y + 1) begin
            for (init_word = 0; init_word < FB_WIDTH / 4;
                 init_word = init_word + 1) begin
                fb_model.ddr[(init_buf << 15) + (init_y << 7) + init_word] = {
                    fb[init_y * FB_WIDTH + (init_word << 2) + 3],
                    fb[init_y * FB_WIDTH + (init_word << 2) + 2],
                    fb[init_y * FB_WIDTH + (init_word << 2) + 1],
                    fb[init_y * FB_WIDTH + (init_word << 2)]
                };
            end
        end
    end
`endif
    rst = 1'b0;
    repeat (4) @(posedge clk);
    for (init_i = 0; init_i < 8; init_i = init_i + 1)
        write_control(init_i[2:0], controls[init_i]);
    // Direct replay uses the production command path.  Manual mode prevents
    // the vblank helper from replacing command bit0 with an automatic erase.
    write_control(3'd3, controls[3] | 8'h02);
    write_control(3'd0, controls[0] | 8'h01);
    @(negedge clk); vblank = 1'b1;
    @(negedge clk); vblank = 1'b0;

    while (!rendering && cycles < max_cycles) @(posedge clk);
    if (!rendering) begin
        errors = errors + 1;
        $display("REPLAY ASSERT FAIL: renderer never started");
    end
    while (rendering && cycles < max_cycles) @(posedge clk);
    if (rendering) begin
        errors = errors + 1;
        $display("REPLAY ASSERT FAIL: renderer exceeded MAXCYCLES=%0d", max_cycles);
    end
    while ((run_active || rom_outstanding) && cycles < max_cycles) @(posedge clk);
    while (fb_busy && cycles < max_cycles) @(posedge clk);
    repeat (8) @(posedge clk);

    if (fb_runs != fb_run_ends) begin
        errors = errors + 1;
        $display("REPLAY ASSERT FAIL: unbalanced framebuffer runs %0d/%0d",
                 fb_runs, fb_run_ends);
    end
    out_fd = $fopen(out_path, "w");
    if (out_fd == 0)
        $fatal(1, "cannot open RTL framebuffer output %s", out_path);
`ifdef S32_REPLAY_REAL_FB
    // Read the physical work buffer selected by the production triple-buffer
    // rotation, including the overrun-only third slot.
    for (out_y = 0; out_y < FB_HEIGHT; out_y = out_y + 1) begin
        for (out_x = 0; out_x < FB_WIDTH; out_x = out_x + 1) begin
            out_word = (dut.work_buf << 15) + (out_y << 7) + (out_x >> 2);
            out_lane = out_x & 3;
            fb[out_y * FB_WIDTH + out_x] =
                fb_model.ddr[out_word] >> (out_lane * 16);
        end
    end
`endif
    for (init_i = 0; init_i < FB_PIXELS; init_i = init_i + 1)
        $fdisplay(out_fd, "%04x", fb[init_i]);
    $fclose(out_fd);
    if (errors == 0)
        $display("SPRITE REPLAY RTL PASS cycles=%0d commands=%0d rom_requests=%0d runs=%0d pixels=%0d",
                 cycles, dut.list_count, rom_requests, fb_runs, fb_writes);
    else
        $display("SPRITE REPLAY RTL FAIL errors=%0d", errors);
    $finish;
end

initial begin
    #1000000000;
    $display("SPRITE REPLAY RTL FAIL wall-clock timeout");
    $finish;
end

endmodule
