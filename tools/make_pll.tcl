# Headless PLL generation for the Sega System 32 core.
#   Produces rtl/pll/pll.{qip,v} = Cyclone V fPLL, 50 MHz in ->
#   outclk_0 = 96.634615 MHz, outclk_1 = 48.317307 MHz (DESIGN.md §3.3).
#
# Run from the repo root with the qsys scripting tool from your Quartus
# install. Run the following from the repository root (with Quartus on PATH):
#   qsys-script --script=tools/make_pll.tcl
#   qsys-generate rtl/pll/pll.qsys \
#       --synthesis=VERILOG --output-directory=rtl/pll
#
# tools/build.bat does both of these plus the compile.

package require -exact qsys 17.0

create_system pll
set_project_property DEVICE_FAMILY {Cyclone V}
set_project_property DEVICE {5CSEBA6U23I7}

add_instance pll_inst altera_pll 17.0

set_instance_parameter_value pll_inst {gui_device_speed_grade}          {7}
set_instance_parameter_value pll_inst {gui_pll_mode}                    {Integer-N PLL}
set_instance_parameter_value pll_inst {gui_reference_clock_frequency}   {50.0}
set_instance_parameter_value pll_inst {gui_number_of_clocks}            {4}
set_instance_parameter_value pll_inst {gui_operation_mode}              {direct}

# outclk_0 = 96.634615 MHz (clk_ram), outclk_1 = 48.317307 MHz (clk_sys)
set_instance_parameter_value pll_inst {gui_output_clock_frequency0}     {96.634615}
set_instance_parameter_value pll_inst {gui_phase_shift0}                {0}
set_instance_parameter_value pll_inst {gui_duty_cycle0}                 {50}
set_instance_parameter_value pll_inst {gui_output_clock_frequency1}     {48.317307}
set_instance_parameter_value pll_inst {gui_phase_shift1}                {0}
set_instance_parameter_value pll_inst {gui_duty_cycle1}                 {50}

# outclk_2 = SDRAM_CLK: 96.634615 MHz shifted 180 deg (+5174 ps).
# The half-cycle relationship centres both sides of the board interface:
# commands/write data launched by outclk_0 have ample setup before SDRAM_CLK,
# while CL2 read data is captured by the constrained outclk_0 input register.
# A negative quarter-cycle phase sampled pre-data on hardware; +90 degrees
# fixed the read direction but left only 2.587 ns for outbound setup.
set_instance_parameter_value pll_inst {gui_output_clock_frequency2}     {96.634615}
set_instance_parameter_value pll_inst {gui_phase_shift2}                {5174}
set_instance_parameter_value pll_inst {gui_duty_cycle2}                 {50}

# outclk_3 = clk_v25 = 24.158653 MHz (exactly clk_sys/2), phase 0.  The large NEC
# V25 (s80x86) runs here so its fabric paths get twice the settle time and meet
# timing with real margin; the fractional enable keeps the 10 MHz V25 cadence.
set_instance_parameter_value pll_inst {gui_output_clock_frequency3}     {24.158653}
set_instance_parameter_value pll_inst {gui_phase_shift3}                {0}
set_instance_parameter_value pll_inst {gui_duty_cycle3}                 {50}

# Export refclk / reset / outclks / locked to match emu's pll instance.
add_interface        refclk    clock      sink
set_interface_property refclk  EXPORT_OF  pll_inst.refclk
add_interface        reset     reset      sink
set_interface_property reset   EXPORT_OF  pll_inst.reset
add_interface        outclk0   clock      source
set_interface_property outclk0 EXPORT_OF  pll_inst.outclk0
add_interface        outclk1   clock      source
set_interface_property outclk1 EXPORT_OF  pll_inst.outclk1
add_interface        outclk2   clock      source
set_interface_property outclk2 EXPORT_OF  pll_inst.outclk2
add_interface        outclk3   clock      source
set_interface_property outclk3 EXPORT_OF  pll_inst.outclk3
add_interface        locked    conduit    end
set_interface_property locked  EXPORT_OF  pll_inst.locked

save_system {rtl/pll/pll.qsys}
