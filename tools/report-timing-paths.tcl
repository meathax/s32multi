package require ::quartus::project
package require ::quartus::sta

set revision "s32"
if {[llength $quartus(args)] > 0} {
    set revision [lindex $quartus(args) 0]
}

proc s32_exact_clock {label pattern} {
    set clocks [get_clocks -nowarn $pattern]
    set count [get_collection_size $clocks]
    if {$count != 1} {
        error "s32 timing diagnostics: expected exactly one $label clock matching '$pattern', found $count"
    }
    return $clocks
}

proc s32_optional_exact_clock {label pattern} {
    set clocks [get_clocks -nowarn $pattern]
    set count [get_collection_size $clocks]
    if {$count > 1} {
        error "s32 timing diagnostics: expected at most one $label clock matching '$pattern', found $count"
    }
    if {$count == 0} {
        post_message -type info "No $label clock is present in this revision."
    }
    return $clocks
}

proc s32_report {analysis from_clock to_clock path} {
    set args [list report_timing -npaths 100 -nworst 1 -detail full_path -file $path]
    lappend args -$analysis
    if {[get_collection_size $from_clock] > 0} {
        lappend args -from_clock $from_clock
    }
    if {[get_collection_size $to_clock] > 0} {
        lappend args -to_clock $to_clock
    }
    post_message -type info "Writing $analysis paths to $path"
    eval $args
}

proc s32_corner_tag {op} {
    set model [string tolower [get_operating_conditions_info $op -model]]
    set voltage [get_operating_conditions_info $op -voltage]
    set temperature [get_operating_conditions_info $op -temperature]
    set raw [format "%s-%smv-%sc" $model $voltage $temperature]
    return [string map {"-" "m" "." "p" " " ""} $raw]
}

project_open -revision $revision $revision
create_timing_netlist
read_sdc
update_timing_netlist

# These selectors intentionally mirror s32.sdc and name the
# dedicated game PLL hierarchy. Cardinality checks prevent a wildcard from
# silently reporting an unrelated framework clock.
set fast_clk [s32_exact_clock "game PLL outclk0 (clk_ram)" \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
set sys_clk [s32_exact_clock "game PLL outclk1 (clk_sys)" \
    {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}]
set sdram_clk [s32_exact_clock "forwarded SDRAM_CLK" {SDRAM_CLK}]
set hdmi_clk [s32_optional_exact_clock "MiSTer HDMI pixel clock" \
    {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
set audio_clk [s32_optional_exact_clock "MiSTer audio clock" \
    {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}]
set v25_clk [s32_optional_exact_clock "game PLL outclk3 (clk_v25)" \
    {*|pll|pll_inst|altera_pll_i|*[3].*|divclk}]

foreach_in_collection op [get_available_operating_conditions] {
    set corner [s32_corner_tag $op]
    post_message -type info "Writing full-path timing diagnostics for $corner"
    set_operating_conditions $op
    update_timing_netlist

    set timing_pairs [list \
        [list fast96 $fast_clk $fast_clk] \
        [list sys48 $sys_clk $sys_clk] \
        [list fast96-to-sys48 $fast_clk $sys_clk] \
        [list sys48-to-fast96 $sys_clk $fast_clk] \
        [list fast96-to-sdram $fast_clk $sdram_clk] \
        [list sdram-to-fast96 $sdram_clk $fast_clk]]
    if {[get_collection_size $hdmi_clk] == 1} {
        lappend timing_pairs [list hdmi $hdmi_clk $hdmi_clk]
    }
    if {[get_collection_size $audio_clk] == 1} {
        lappend timing_pairs [list audio $audio_clk $audio_clk]
    }
    foreach pair $timing_pairs {
        lassign $pair label from_clock to_clock
        s32_report setup $from_clock $to_clock \
            "output_files/timing-$label-setup-$corner.rpt"
        s32_report hold $from_clock $to_clock \
            "output_files/timing-$label-hold-$corner.rpt"
    }

    if {[get_collection_size $v25_clk] == 1} {
        s32_report setup $v25_clk $v25_clk \
            "output_files/timing-v25-setup-$corner.rpt"
        s32_report hold $v25_clk $v25_clk \
            "output_files/timing-v25-hold-$corner.rpt"
    }

    set no_from_clock [get_clocks -nowarn {__s32_no_clock__}]
    set recovery_clocks [list \
        [list fast96 $fast_clk] \
        [list sys48 $sys_clk] \
        [list sdram $sdram_clk]]
    if {[get_collection_size $hdmi_clk] == 1} {
        lappend recovery_clocks [list hdmi $hdmi_clk]
    }
    if {[get_collection_size $audio_clk] == 1} {
        lappend recovery_clocks [list audio $audio_clk]
    }
    foreach clock_pair $recovery_clocks {
        lassign $clock_pair label clock
        s32_report recovery $no_from_clock $clock \
            "output_files/timing-$label-recovery-$corner.rpt"
        s32_report removal $no_from_clock $clock \
            "output_files/timing-$label-removal-$corner.rpt"
    }
    if {[get_collection_size $v25_clk] == 1} {
        s32_report recovery $no_from_clock $v25_clk \
            "output_files/timing-v25-recovery-$corner.rpt"
        s32_report removal $no_from_clock $v25_clk \
            "output_files/timing-v25-removal-$corner.rpt"
    }
}

delete_timing_netlist
project_close
