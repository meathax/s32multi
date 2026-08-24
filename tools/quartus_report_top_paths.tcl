set codex_paths [get_timing_paths -setup -npaths 100]
set codex_ordinal 0

foreach_in_collection codex_path $codex_paths {
	set codex_from [get_path_info $codex_path -from]
	set codex_to [get_path_info $codex_path -to]
	set codex_slack [get_path_info $codex_path -slack]
	set codex_from_name [get_node_info $codex_from -name]
	set codex_to_name [get_node_info $codex_to -name]
	post_message "CODEX_TOP_SETUP_PATH ordinal=$codex_ordinal slack=$codex_slack from={$codex_from_name} to={$codex_to_name}"
	incr codex_ordinal
}

report_timing -setup -npaths 100 -detail full_path -panel_name "Codex Top 100 Setup Paths"
