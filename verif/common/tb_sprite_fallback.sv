// Run the identical 24-case pixel suite with the common-path accelerator
// disabled.  Both tops therefore compare against the same expected pixels,
// while only the production top is allowed to use the faster cadence.
module tb_sprite_fallback;
    tb_sprite #(.DUT_FAST_1X(1'b0)) test();
endmodule
