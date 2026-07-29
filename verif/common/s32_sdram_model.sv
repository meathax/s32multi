//============================================================================
//  Dual-device SDR SDRAM model for the MiSTer 128 MB module.
//
//  The module carries TWO 512 Mbit (32M x 16) devices on one pin set:
//    - SDRAM_nCS is the DEVICE SELECT, not a command bit.  A device that is
//      not selected sees COMMAND INHIBIT and must ignore the cycle entirely.
//    - SDRAM_DQML/DQMH are SHORTED to SDRAM_A[11]/A[12] on the module, so the
//      byte mask is whatever the address bus happens to carry.
//    - 4 banks x 8192 rows x 1024 columns per device.  Columns are A[9:0];
//      A[10] is auto-precharge.
//  Verified against Arcade-IremM92_MiSTer/rtl/sdram.sv:64,69,191-192 and
//  jtcores/modules/jtframe/hdl/sdram/jtframe_sdram_bank_core.v:63-66,140.
//
//  This model exists because the pre-existing tb_sdram.sv chip model has no
//  array, no rows and no banks -- it would pass an almost arbitrary wrong
//  geometry.  Everything here is FATAL rather than tolerant: a capacity change
//  is the class of bug that passes a lenient sim and corrupts a real board.
//============================================================================
`timescale 1ns/1ps

module s32_sdram_model #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 10,
    parameter BANK_BITS = 2,
    // Refresh obligation: 8192 rows / 64 ms, checked per device.
    parameter longint REFRESH_MAX_NS = 64_000_000/8192 * 8192
) (
    input               clk,
    inout       [15:0]  SDRAM_DQ,
    input       [12:0]  SDRAM_A,
    input        [1:0]  SDRAM_BA,
    input               SDRAM_DQML,
    input               SDRAM_DQMH,
    input               SDRAM_nCS,
    input               SDRAM_nRAS,
    input               SDRAM_nCAS,
    input               SDRAM_nWE,
    input               SDRAM_CKE
);

// {chip, bank[1:0], row[12:0], col[9:0]} -> word
logic [15:0] store [longint];

// per-device, per-bank open row (-1 = closed)
integer arow [0:1][0:3];
reg     mrs_done [0:1];
integer ref_count [0:1];
integer errors = 0;

// command decode: nCS selects the device, {RAS,CAS,WE} is the command
wire [2:0] cmd  = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
wire       chip = SDRAM_nCS;

localparam [2:0] C_NOP=3'b111, C_ACT=3'b011, C_READ=3'b101,
                 C_WRITE=3'b100, C_PRE=3'b010, C_REF=3'b001, C_MRS=3'b000;

// CL2 read return pipeline
reg [15:0] dq_pipe [0:2];
reg  [2:0] dq_val;
reg  [1:0] dq_mask_pipe [0:2];
// CL2: the model observes the READ command one cycle after the controller
// registers it, so the data must appear on the bus two model cycles later --
// dq_pipe[1], not [2].  Driving [2] emulates CL3 and shows up as every burst
// word shifted by one with the first word empty.
assign SDRAM_DQ = dq_val[1] ? dq_pipe[1] : 16'hZZZZ;

integer i, j;
initial begin
    for (i=0;i<2;i=i+1) begin
        mrs_done[i]=0; ref_count[i]=0;
        for (j=0;j<4;j=j+1) arow[i][j]=-1;
    end
    dq_val = 3'b000;
end

task automatic fail(input string msg);
    errors = errors + 1;
    $display("SDRAM MODEL FATAL @%0t: %s", $time, msg);
    $display("  chip=%0d BA=%0d A=%013b DQMH/L=%b%b cmd=%b",
             chip, SDRAM_BA, SDRAM_A, SDRAM_DQMH, SDRAM_DQML, cmd);
    $fatal(1);
endtask

// The DQM pins are shorted to A[12:11] on this module.  If the DUT ever drives
// them independently the physical net would be in contention; catch it here.
always @(posedge clk) begin
    if ({SDRAM_DQMH, SDRAM_DQML} !== SDRAM_A[12:11])
        fail("DQMH/DQML do not match A[12:11] -- the 128MB module shorts these pins");
end

wire [COL_BITS-1:0] col_now = {SDRAM_A[9], SDRAM_A[8:0]};

always @(posedge clk) begin
    // shift the CL2 return pipe
    dq_pipe[2] <= dq_pipe[1]; dq_pipe[1] <= dq_pipe[0];
    dq_val     <= {dq_val[1:0], 1'b0};
    dq_mask_pipe[2] <= dq_mask_pipe[1]; dq_mask_pipe[1] <= dq_mask_pipe[0];

    if (SDRAM_CKE !== 1'b1) begin
        // CKE low is not used by this controller
    end
    else case (cmd)
        C_MRS: begin
            if (SDRAM_A[12:11] !== 2'b00)
                fail("MRS with A[12:11] non-zero would assert DQM on the shorted net");
            mrs_done[chip] = 1'b1;
        end

        C_ACT: begin
            if (!mrs_done[chip]) fail("ACT before MRS on this device");
            if (arow[chip][SDRAM_BA] != -1)
                fail($sformatf("ACT to bank %0d of chip %0d which already has row %0d open",
                               SDRAM_BA, chip, arow[chip][SDRAM_BA]));
            arow[chip][SDRAM_BA] = SDRAM_A[ROW_BITS-1:0];
        end

        C_PRE: begin
            if (SDRAM_A[10]) begin
                for (j=0;j<4;j=j+1) arow[chip][j] = -1;
            end else begin
                arow[chip][SDRAM_BA] = -1;
            end
        end

        C_REF: begin
            // JEDEC init is PRE-all -> 8x AUTO_REFRESH -> MRS, so refresh
            // legitimately precedes MRS.  Only ACT/READ/WRITE require it.
            for (j=0;j<4;j=j+1)
                if (arow[chip][j] != -1)
                    fail($sformatf("REFRESH on chip %0d with bank %0d still open", chip, j));
            ref_count[chip] = ref_count[chip] + 1;
        end

        C_WRITE: begin
            longint key;
            logic [15:0] old, nw;
            logic [1:0]  mask;
            if (!mrs_done[chip]) fail("WRITE before MRS on this device");
            if (arow[chip][SDRAM_BA] == -1)
                fail($sformatf("WRITE to chip %0d bank %0d with no open row", chip, SDRAM_BA));
            key = {chip, SDRAM_BA, arow[chip][SDRAM_BA][12:0], col_now};
            mask = SDRAM_A[12:11];          // DQM: 1 = masked
            old  = store.exists(key) ? store[key] : 16'hxxxx;
            nw   = old;
            if (!mask[0]) nw[7:0]  = SDRAM_DQ[7:0];
            if (!mask[1]) nw[15:8] = SDRAM_DQ[15:8];
            store[key] = nw;
            if (SDRAM_A[10]) arow[chip][SDRAM_BA] = -1;   // auto-precharge
        end

        C_READ: begin
            longint key;
            if (!mrs_done[chip]) fail("READ before MRS on this device");
            if (arow[chip][SDRAM_BA] == -1)
                fail($sformatf("READ from chip %0d bank %0d with no open row", chip, SDRAM_BA));
            // A[12:11] is DQM.  Non-zero here masks the returning data, which on
            // this module means the controller used a column bit it does not have.
            if (SDRAM_A[12:11] !== 2'b00)
                fail("READ CAS with A[12:11] non-zero -- DQM would mask the returned word (wrong column count?)");
            key = {chip, SDRAM_BA, arow[chip][SDRAM_BA][12:0], col_now};
            dq_pipe[0] <= store.exists(key) ? store[key] : 16'hdead;
            dq_val[0]  <= 1'b1;
            if (SDRAM_A[10]) arow[chip][SDRAM_BA] = -1;   // auto-precharge
        end

        default: ; // NOP
    endcase
end

// Refresh obligation, checked per device.
realtime last_check = 0;
initial begin
    forever begin
        #1_000_000;   // 1 ms
        for (i=0;i<2;i=i+1) begin
            if (mrs_done[i] && ref_count[i] < 100)
                $display("SDRAM MODEL WARNING: chip %0d only %0d refreshes in 1ms (expect ~128)",
                         i, ref_count[i]);
            ref_count[i] = 0;
        end
    end
end

function automatic int unsigned model_errors(); model_errors = errors; endfunction

endmodule
