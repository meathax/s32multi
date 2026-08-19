// System 32 driving-cabinet input adapters.
// MiSTer analog-stick axes are signed -128..+127 with zero at rest.
// Steering: left-stick X, deadzoned, with dpad left/right as a full-deflection
// digital fallback when no analog stick is present. Pedals: right-stick Y
// split into accel(up)/brake(down), with two assignable digital buttons as
// full-scale fallbacks.
module s32_driving_controls (
    input         clk,
    input         rst,
    input         capture_wheel,
    input         wheel_sample,
    input   [7:0] left_x,
    input   [7:0] right_y,
    input         digital_accel,
    input         digital_brake,
    input         digital_left,
    input         digital_right,
    output  [7:0] wheel,
    output  [7:0] accel,
    output  [7:0] brake
);
    localparam [7:0] WHEEL_DZ = 8'd6;

    function automatic [7:0] wheel_deadzone(input [7:0] raw);
        logic [7:0] v;
        begin
            v = raw ^ 8'h80;
            // This is algebraically the same subtractive deadzone as
            // 128 + ((v - 128) +/- WHEEL_DZ), expressed in offset-binary so
            // every intermediate and the ADC result remain explicitly 8-bit.
            if (v >= (8'd128 - WHEEL_DZ) && v <= (8'd128 + WHEEL_DZ))
                wheel_deadzone = 8'h80;
            else if (v > 8'd128)
                wheel_deadzone = v - WHEEL_DZ;
            else
                wheel_deadzone = v + WHEEL_DZ;
        end
    endfunction

    wire [7:0] wheel_live = wheel_deadzone(left_x);

    function automatic [8:0] wheel_distance(
        input [7:0] a,
        input [7:0] b
    );
        wheel_distance = (a >= b) ? ({1'b0, a} - {1'b0, b})
                                  : ({1'b0, b} - {1'b0, a});
    endfunction

    reg [7:0] wheel_latest;
    reg [7:0] wheel_delivered;
    reg [7:0] wheel_pending;
    reg       wheel_pending_valid;

    wire signed [8:0] stick_y =
        $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    // Rad Mobile polls the MSM6253 more slowly than a USB stick can report a
    // complete out-and-back motion. Retain the strongest excursion between
    // channel-0 loads, then present the latest coordinate on the following
    // load. Other driving sets keep the direct positional path.
    // Digital d-pad steering (no analog stick present) overrides the analog
    // path entirely, same priority as the digital accel/brake fallbacks
    // below. Full deflection saturates the 8-bit ADC endpoint.
    assign wheel = digital_right ? 8'hff :
                   digital_left  ? 8'h00 :
                   (capture_wheel && wheel_pending_valid)
                 ? wheel_pending : wheel_live;

    always @(posedge clk) begin
        if (rst) begin
            wheel_latest       <= 8'h80;
            wheel_delivered    <= 8'h80;
            wheel_pending      <= 8'h80;
            wheel_pending_valid <= 1'b0;
        end
        else if (!capture_wheel) begin
            wheel_latest       <= wheel_live;
            wheel_delivered    <= wheel_live;
            wheel_pending      <= wheel_live;
            wheel_pending_valid <= 1'b0;
        end
        else if (wheel_sample) begin
            // The MSM6253 captures the pre-edge value of wheel. If the stick
            // has already returned or moved elsewhere, retain that latest
            // coordinate for the next conversion so steering cannot stick.
            wheel_delivered <= wheel;
            wheel_latest    <= wheel_live;
            wheel_pending   <= wheel_live;
            wheel_pending_valid <= (wheel_live != wheel);
        end
        else if (wheel_live != wheel_latest) begin
            wheel_latest <= wheel_live;
            if (!wheel_pending_valid) begin
                if (wheel_live != wheel_delivered) begin
                    wheel_pending       <= wheel_live;
                    wheel_pending_valid <= 1'b1;
                end
            end
            else if (wheel_distance(wheel_live, wheel_delivered) >=
                     wheel_distance(wheel_pending, wheel_delivered)) begin
                wheel_pending <= wheel_live;
            end
        end
    end

    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule
