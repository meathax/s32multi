`timescale 1ns/1ps

module tb_driving_controls;
    reg        clk = 1'b0;
    reg        rst;
    reg        capture_wheel;
    reg        wheel_sample;
    reg  [7:0] left_x;
    reg  [7:0] paddle;
    reg  [8:0] spinner;
    reg  [1:0] wheel_source;
    reg  [7:0] right_y;
    reg        digital_accel;
    reg        digital_brake;
    reg        digital_left;
    reg        digital_right;
    wire [7:0] wheel;
    wire [7:0] accel;
    wire [7:0] brake;

    s32_driving_controls dut (
        .clk(clk),
        .rst(rst),
        .capture_wheel(capture_wheel),
        .wheel_sample(wheel_sample),
        .left_x(left_x),
        .paddle(paddle),
        .spinner(spinner),
        .wheel_source(wheel_source),
        .right_y(right_y),
        .digital_accel(digital_accel),
        .digital_brake(digital_brake),
        .digital_left(digital_left),
        .digital_right(digital_right),
        .wheel(wheel),
        .accel(accel),
        .brake(brake)
    );

    always #5 clk = ~clk;

    reg  [7:0] paddle_p2;
    reg  [8:0] spinner_p2;
    reg  [1:0] wheel_source_p2;
    wire [7:0] wheel_p2;

    s32_driving_controls dut_p2 (
        .clk(clk),
        .rst(rst),
        .capture_wheel(1'b0),
        .wheel_sample(1'b0),
        .left_x(8'h00),
        .paddle(paddle_p2),
        .spinner(spinner_p2),
        .wheel_source(wheel_source_p2),
        .right_y(8'h00),
        .digital_accel(1'b0),
        .digital_brake(1'b0),
        .digital_left(1'b0),
        .digital_right(1'b0),
        .wheel(wheel_p2),
        .accel(),
        .brake()
    );

    task automatic check(input condition, input [255:0] message);
        if (!condition) begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic drive(input [7:0] right_y_value, input [31:0] buttons);
        right_y = right_y_value;
        digital_accel = buttons[4];
        digital_brake = buttons[5];
        #1;
    endtask

    task automatic drive_wheel(input [7:0] left_x_value);
        left_x = left_x_value;
        #1;
    endtask

    task automatic report_wheel(input [7:0] left_x_value);
        @(negedge clk);
        left_x = left_x_value;
        @(posedge clk);
        #1;
    endtask

    task automatic sample_wheel(output [7:0] sampled_value);
        @(negedge clk);
        sampled_value = wheel;
        wheel_sample = 1'b1;
        @(posedge clk);
        #1;
        wheel_sample = 1'b0;
    endtask

    task automatic report_spinner(input [7:0] delta);
        @(negedge clk);
        spinner = {~spinner[8], delta};
        @(posedge clk);
        #1;
    endtask

    task automatic report_spinner_p2(input [7:0] delta);
        @(negedge clk);
        spinner_p2 = {~spinner_p2[8], delta};
        @(posedge clk);
        #1;
    endtask

    initial begin
        integer position;
        integer expected;
        reg [7:0] previous;
        reg [7:0] sampled;

        left_x = 8'h00;
        paddle = 8'h80;
        spinner = 9'h000;
        wheel_source = 2'd0;
        right_y = 8'h00;
        digital_accel = 1'b0;
        digital_brake = 1'b0;
        digital_left = 1'b0;
        digital_right = 1'b0;
        paddle_p2 = 8'h80;
        spinner_p2 = 9'h000;
        wheel_source_p2 = 2'd0;
        capture_wheel = 1'b0;
        wheel_sample = 1'b0;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;

        drive(8'h00, 32'd0);
        check(accel == 8'h00 && brake == 8'h00,
              "center releases both pedals");

        drive(8'hc0, 32'd0); // -64: right stick halfway up
        check(accel == 8'h80 && brake == 8'h00,
              "right-stick up drives accelerator only");

        drive(8'h81, 32'd0); // -127: full up
        check(accel == 8'hff && brake == 8'h00,
              "full right-stick up saturates accelerator");

        drive(8'h40, 32'd0); // +64: right stick halfway down
        check(accel == 8'h00 && brake == 8'h80,
              "right-stick down drives brake only");

        drive(8'h7f, 32'd0); // +127: full down
        check(accel == 8'h00 && brake == 8'hff,
              "full right-stick down saturates brake");

        drive(8'h00, 32'h0000_0010); // A / B1
        check(accel == 8'hff && brake == 8'h00,
              "A is the full-scale digital accelerator");

        drive(8'h00, 32'h0000_0020); // B / B2
        check(accel == 8'h00 && brake == 8'hff,
              "B is the full-scale digital brake");

        drive(8'h00, 32'h0000_0040); // X / B3: Gear Change
        check(accel == 8'h00 && brake == 8'h00,
              "Gear Change does not press either pedal");

        // Sweep every signed MiSTer X coordinate in physical order. Each
        // coordinate must appear immediately, monotonically, with no clocked
        // state that can retain a random intermediate wheel position.
        previous = 8'h00;
        for (position = -127; position <= 127; position = position + 1) begin
            drive_wheel(position[7:0]);
            if (position < -6)
                expected = 128 + position + 6;
            else if (position > 6)
                expected = 128 + position - 6;
            else
                expected = 128;
            check(wheel == expected[7:0],
                  "wheel follows every current signed-stick coordinate");
            check(position == -127 || wheel >= previous,
                  "wheel sweep is monotonic");
            previous = wheel;
        end

        drive_wheel(8'hc0); // -64
        check(wheel == 8'h46, "left intermediate coordinate is immediate");
        drive_wheel(8'h40); // +64, direct reversal
        check(wheel == 8'hba, "right reversal cannot retain old left value");
        drive_wheel(8'h00); // center
        check(wheel == 8'h80, "return to center is immediate");

        // A host report can leave centre and return before Rad Mobile starts
        // its next ADC conversion. Retain both the excursion and its return,
        // each until one real channel-0 load consumes it.
        capture_wheel = 1'b1;
        report_wheel(8'hc0);
        report_wheel(8'h00);
        check(wheel == 8'h46, "fast left excursion remains pending");
        sample_wheel(sampled);
        check(sampled == 8'h46, "ADC consumes fast left excursion");
        check(wheel == 8'h80, "return to centre remains pending after left");
        sample_wheel(sampled);
        check(sampled == 8'h80, "ADC consumes return after fast left");

        report_wheel(8'h40);
        report_wheel(8'h00);
        check(wheel == 8'hba, "fast right excursion remains pending");
        sample_wheel(sampled);
        check(sampled == 8'hba, "ADC consumes fast right excursion");
        check(wheel == 8'h80, "return to centre remains pending after right");
        sample_wheel(sampled);
        check(sampled == 8'h80, "ADC consumes return after fast right");

        report_wheel(8'hc0);
        report_wheel(8'h90);
        report_wheel(8'he0);
        report_wheel(8'h00);
        check(wheel == 8'h16,
              "strongest excursion survives multiple reports between loads");
        sample_wheel(sampled);
        check(sampled == 8'h16, "ADC consumes strongest queued excursion");
        sample_wheel(sampled);
        check(sampled == 8'h80, "ADC consumes latest coordinate after peak");

        capture_wheel = 1'b0;
        wheel_source = 2'd1;
        paddle = 8'h00;
        #1;
        check(wheel == 8'h00, "paddle reaches the full-left ADC endpoint");
        paddle = 8'h80;
        #1;
        check(wheel == 8'h80, "paddle center is exact");
        paddle = 8'hff;
        #1;
        check(wheel == 8'hff, "paddle reaches the full-right ADC endpoint");

        wheel_source = 2'd2;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        #1;
        check(wheel == 8'h80, "spinner steering resets to center");
        report_spinner(8'h10);
        check(wheel == 8'h90, "positive spinner delta turns right");
        report_spinner(8'he0);
        check(wheel == 8'h70, "negative spinner delta turns left");
        report_spinner(8'h80);
        check(wheel == 8'h00, "minus 128 saturates at full left");
        report_spinner(8'h7f);
        report_spinner(8'h7f);
        report_spinner(8'h7f);
        check(wheel == 8'hff, "positive spinner motion saturates without wrap");

        wheel_source = 2'd3;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        report_spinner(8'h10);
        check(wheel == 8'h70, "reverse spinner mode reverses movement");
        report_spinner(8'h80);
        check(wheel == 8'hf0,
              "reverse mode preserves the full minus-128 report as plus 128");

        digital_right = 1'b1;
        #1;
        check(wheel == 8'hff, "digital right overrides spinner steering");
        digital_right = 1'b0;
        digital_left = 1'b1;
        #1;
        check(wheel == 8'h00, "digital left overrides spinner steering");
        digital_left = 1'b0;

        wheel_source = 2'd2;
        wheel_source_p2 = 2'd2;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        report_spinner(8'h0a);
        check(wheel == 8'h8a && wheel_p2 == 8'h80,
              "P1 spinner does not move P2 steering");
        report_spinner_p2(8'hf6);
        check(wheel == 8'h8a && wheel_p2 == 8'h76,
              "P2 spinner is independent from P1 steering");

        $display("PASS: System 32 driving controls");
        $finish;
    end
endmodule
