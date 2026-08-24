package require ::quartus::project
package require ::quartus::sta

set project_name "s32"
set revision_name "s32"
set report_file "output_files/s32.core-setup.rpt"

project_open -revision $revision_name $project_name
create_timing_netlist
read_sdc
update_timing_netlist

set core_clock [get_clocks "*|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
report_timing \
    -setup \
    -to_clock $core_clock \
    -npaths 50 \
    -nworst 10 \
    -detail full_path \
    -show_routing \
    -file $report_file

report_timing \
    -hold \
    -to_clock $core_clock \
    -npaths 50 \
    -nworst 10 \
    -detail full_path \
    -show_routing \

delete_timing_netlist
project_close
