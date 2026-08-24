`timescale 1ns/1ps

module tb_multipcm_output_level;
	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg ce = 1'b0;
	reg [31:0] ce_acc = 0;
	always @(posedge clk) {ce, ce_acc} <= {1'b0, ce_acc} + 33'd888908667;

	reg rst = 1'b1;
	reg cs = 1'b0;
	reg we = 1'b0;
	reg [1:0] addr = 0;
	reg [7:0] wdata = 0;
	wire rom_req;
	wire [21:0] rom_addr;
	reg [7:0] rom_data = 0;
	reg rom_ack = 1'b0;
	wire signed [15:0] out_l;
	wire signed [15:0] out_r;

	reg pending = 1'b0;
	integer peak_acc_r = 0;
	integer peak_out_r = 0;
	reg measure = 1'b0;

	s32_multipcm dut (
		.clk(clk), .ce(ce), .rst(rst),
		.cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_data(rom_data), .rom_ack(rom_ack),
		.bank_lo(3'd0), .bank_hi(3'd0),
		.out_l(out_l), .out_r(out_r)
	);

	function automatic [7:0] rom_byte(input [21:0] a);
		reg [3:0] di;
	begin
		if (a >= 22'h00003c && a < 22'h000048) begin
			di = a[3:0] - 4'hc;
			case (di)
				0: rom_byte = 8'h00;  1: rom_byte = 8'h2b;
				2: rom_byte = 8'ha4;  3: rom_byte = 8'h00;
				4: rom_byte = 8'h00;  5: rom_byte = 8'hfd;
				6: rom_byte = 8'h18;  7: rom_byte = 8'h00;
				8: rom_byte = 8'hf0;  9: rom_byte = 8'h00;
				10: rom_byte = 8'h0f; 11: rom_byte = 8'h00;
				default: rom_byte = 8'h00;
			endcase
		end
		else rom_byte = 8'h40;
	end
	endfunction

	always @(posedge clk) begin
		rom_ack <= 1'b0;
		if (rom_req && !pending)
			pending <= 1'b1;
		else if (pending) begin
			rom_data <= rom_byte(rom_addr);
			rom_ack <= 1'b1;
			pending <= 1'b0;
		end
		if (!rom_req) pending <= 1'b0;
	end

	task automatic wr(input [1:0] port, input [7:0] value);
	begin
		@(negedge clk); cs = 1'b1; we = 1'b1; addr = port; wdata = value;
		repeat (12) @(posedge clk);
		#1; @(negedge clk); cs = 1'b0; we = 1'b0;
		repeat (400) @(posedge clk);
	end
	endtask

	always @(posedge clk) begin
		if (measure) begin
			if ($signed(dut.acc_r) > peak_acc_r) peak_acc_r = $signed(dut.acc_r);
			if (-$signed(dut.acc_r) > peak_acc_r) peak_acc_r = -$signed(dut.acc_r);
			if ($signed(out_r) > peak_out_r) peak_out_r = $signed(out_r);
			if (-$signed(out_r) > peak_out_r) peak_out_r = -$signed(out_r);
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		rst = 1'b0;
		repeat (20) @(posedge clk);

		wr(1, 8'd29);
		wr(2, 8'd0); wr(0, 8'h70);
		wr(2, 8'd4); wr(0, 8'h80);
		wr(2, 8'd2); wr(0, 8'h00);
		wr(2, 8'd1); wr(0, 8'h05);
		wr(2, 8'd2); wr(0, 8'h58);
		wr(2, 8'd3); wr(0, 8'hf6);
		wr(2, 8'd5); wr(0, 8'h38);
		wr(2, 8'd6); wr(0, 8'h38);
		wr(2, 8'd7); wr(0, 8'h01);

		repeat (100000) @(posedge clk);
		measure = 1'b1;
		repeat (300000) @(posedge clk);
		$display("AUDIO_LEVEL_JSON {\"schema\":\"orunners-multipcm-level-v1\",\"engine_raw_slot\":29,\"peak_reference\":%0d,\"peak_rtl\":%0d}", peak_acc_r, peak_out_r);
		if (peak_acc_r > 0 && peak_out_r > 0)
			$display("AUDIO_LEVEL_RATIO reference_over_rtl=%0d", peak_acc_r / peak_out_r);
		else
			$fatal(1, "engine voice produced no measurable PCM");
		if (peak_acc_r != peak_out_r)
			$fatal(1, "MultiPCM output scale mismatch: reference=%0d rtl=%0d", peak_acc_r, peak_out_r);
		$finish;
	end

	initial begin
		#20000000;
		$fatal(1, "TIMEOUT");
	end
endmodule
