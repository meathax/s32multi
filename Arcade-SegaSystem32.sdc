derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The forwarded SDRAM clock, the CPU clock-enable exception, and the sprite
# state-exclusive exception all reference objects (PLL divider pins, fitted
# registers) that do not exist during analysis & synthesis.  The previous hard
# `error` guards fired at the quartus_map stage and silently disabled
# timing-driven synthesis (audit R20 PF-5).  Defer the dependent constraints
# with a warning during synthesis; still fail hard once the fitter/STA netlist
# must contain them.
proc s32_require {present what} {
    if {$present} { return 1 }
    if {[string match "quartus_map" $::quartus(nameofexecutable)]} {
        post_message -type warning \
            "s32 SDC: $what not elaborated yet; deferring to fit/STA"
        return 0
    }
    error "s32 SDC: expected $what but it is missing at $::quartus(nameofexecutable)"
}

#**************************************************************
# Sega System 32 core: SDRAM timing (CL2 @ 96.634615 MHz, 180deg clock)
#**************************************************************
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

if {[s32_require [expr {[get_collection_size $sdram_fwd_pin] == 1 && \
                        [get_collection_size $sdram_mem_clk] == 1}] \
        "exactly one PLL outclk2 pin and outclk0 clock for the SDRAM bus"]} {

create_generated_clock -name SDRAM_CLK -source $sdram_fwd_pin \
    [get_ports SDRAM_CLK]

# board + chip delays (typical MiSTer SDRAM module, -7 grade)
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK -min 3.2 [get_ports SDRAM_DQ[*]]
set_output_delay -clock SDRAM_CLK -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_multicycle_path -setup -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 2
set_multicycle_path -hold -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 1

}

# Dedicated Golden Axe and OutRunners profiles compile out CPU Turbo and use
# fixed 16.10795/20 MHz NCOs. Their CE pulses are separated by at least one
# idle clk_sys edge, so internal V60/V70 register-to-register paths have a real
# two-cycle requirement. Universal revisions retain Turbo and must remain
# single-cycle.
set s32_revision ""
if {[llength [info commands get_current_revision]] > 0} {
    set s32_revision [get_current_revision]
}
set s32_ga_fixed_ce  [string equal $s32_revision "s32GoldenAxe"]
# Match every OutRunners-profile revision, not just the release one.  The
# diagnostic revision s32OutRunnersDbg has the identical fixed 20 MHz V70 NCO,
# so it has the same real two-cycle requirement.  An exact-match test silently
# dropped the exception for it and timed the build with stricter constraints
# than the core it is meant to measure -- which both wastes a fit (the release
# build closes at only +0.210 ns WITH the exception) and would make the
# diagnostic a different machine than the one being diagnosed.
set s32_out_fixed_ce [string match "s32OutRunners*" $s32_revision]
set s32_cpu_fixed_ce [expr {$s32_ga_fixed_ce || $s32_out_fixed_ce}]

if {$s32_cpu_fixed_ce} {
    set v60_regs [get_registers -nowarn {*|s32_v60:v60|*}]
    if {[s32_require [expr {[get_collection_size $v60_regs] > 0}] "V60/V70 registers for the dedicated fixed-CE constraint"]} {
        set_multicycle_path -setup 2 -from $v60_regs -to $v60_regs
        set_multicycle_path -hold 1 -from $v60_regs -to $v60_regs

        # Golden Axe's slower 16.10795 MHz NCO guarantees at least three
        # clk_sys edges between CPU updates, so its optional FP accumulator
        # path has the corresponding real requirement. OutRunners' 20 MHz V70
        # can update after two edges and deliberately receives no 3-cycle FP
        # exception.
        if {$s32_ga_fixed_ce} {
            set v60_fp_a [get_registers -nowarn {*|s32_v60:v60|fp_a[*]}]
            if {[get_collection_size $v60_fp_a] > 0} {
                set_multicycle_path -setup 3 -from $v60_fp_a -to $v60_regs
                set_multicycle_path -hold 2 -from $v60_fp_a -to $v60_regs
            } else {
                post_message -type info "s32 SDC: Golden Axe no-FP profile has no fp_a registers"
            }
        }
    }
} else {
    post_message -type info "s32 SDC: revision '$s32_revision' retains single-cycle V60 timing"
}
# Sprite words 0..6 are loaded at least two fetch clocks before decode; word 7
# is intentionally excluded because clip commands consume it on the very next
# decode edge.  x0/y0 are latched before the scale/row/pixel states consume
# them.  These paths are state-exclusive, while the sprite FSM still accepts
# and emits one pixel per fast clock in R_PIXEL.  A two-cycle requirement
# describes the minimum real separation without reducing renderer throughput.
set sprite_deferred_sources [get_registers -nowarn \
    {*|s32_sprite:sprite|sw[0][*] *|s32_sprite:sprite|sw[1][*] \
     *|s32_sprite:sprite|sw[2][*] *|s32_sprite:sprite|sw[3][*] \
     *|s32_sprite:sprite|sw[4][*] *|s32_sprite:sprite|sw[5][*] \
     *|s32_sprite:sprite|sw[6][*] *|s32_sprite:sprite|x0[*] \
     *|s32_sprite:sprite|y0[*]}]
set sprite_regs [get_registers -nowarn {*|s32_sprite:sprite|*}]
if {[s32_require [expr {[get_collection_size $sprite_deferred_sources] > 0 && \
                        [get_collection_size $sprite_regs] > 0}] \
        "sprite registers for the state-exclusive timing constraint"]} {
    set_multicycle_path -setup 2 -from $sprite_deferred_sources -to $sprite_regs
    set_multicycle_path -hold  1 -from $sprite_deferred_sources -to $sprite_regs
}

# The NEC V25 (s80x86) runs on clk_v25 = outclk3 (clk_sys/2, 24.158653 MHz) so its
# large core meets timing with real margin.  Its two crossings to the clk_sys/
# clk_ram world -- the SDRAM p5 line fetch and the V60-side mailbox port -- are
# handled in RTL by two-flop toggle synchronisers (s32_v25_cpu) and a true-dual-
# port RAM, so STA must NOT time those paths.  Declaring clk_v25 asynchronous to
# the rest false-paths them.  Present only in the S32_REAL_V25 build.  Detect
# that instantiated block first: a real-V25 build still hard-fails if its PLL
# clock is missing, while non-V25 profiles (including Jurassic Park) skip it.
set v25_regs [get_registers -nowarn {*|s32_v25_cpu:v25|*}]
if {[get_collection_size $v25_regs] > 0} {
    set v25_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[3].*|divclk}]
    if {[s32_require [expr {[get_collection_size $v25_clk] == 1}] \
            "clk_v25 PLL output clock for the asynchronous clock group"]} {
        set_clock_groups -asynchronous -group $v25_clk
    }
}
