# Report the N worst setup paths with readable from/to node names.
#
# report_timing -stdout often prints nothing useful under `quartus_sta -t`
# for this project; the collection API below is the reliable way to see
# which specific nodes are on a failing path (CLAUDE.md's own documented
# technique for this repo). Usage:
#
#   D:\Q17\quartus\bin64\quartus_sta.exe -t verif/timing/get_worst_paths.tcl -- segas32
#
# Run from the project root (or edit PROJECT/REVISION below). Requires an
# existing fit database (run the fit stage first).

set project_name segas32
set revision_name segas32
set n_paths 10

if {[llength $quartus(args)] > 0} {
    set project_name [lindex $quartus(args) 0]
    set revision_name $project_name
}
if {[llength $quartus(args)] > 1} {
    set revision_name [lindex $quartus(args) 1]
}

project_open $project_name -revision $revision_name
create_timing_netlist
read_sdc
update_timing_netlist

foreach_in_collection p [get_timing_paths -setup -npaths $n_paths] {
    set fn [get_node_info [get_path_info $p -from] -name]
    set tn [get_node_info [get_path_info $p -to] -name]
    set ck [get_clock_info [get_path_info $p -to_clock] -name]
    puts "SETUP slack=[get_path_info $p -slack] CLK=$ck  FROM=$fn  TO=$tn"
}

foreach_in_collection p [get_timing_paths -hold -npaths $n_paths] {
    set fn [get_node_info [get_path_info $p -from] -name]
    set tn [get_node_info [get_path_info $p -to] -name]
    set ck [get_clock_info [get_path_info $p -to_clock] -name]
    puts "HOLD slack=[get_path_info $p -slack] CLK=$ck  FROM=$fn  TO=$tn"
}

project_close
