#!/bin/sh
# Focused Spider-Man early-enemy-trigger regression (Verilator).
set -eu

cd "$(dirname "$0")/../.."
VERILATOR_SAFE="${VERILATOR_SAFE:-verilator-safe}"
VERILATOR_SIM_SAFE="${VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$VERILATOR_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SAFE" >&2; exit 127; }

. verif/verilator/workspace.sh
s32_verilator_workspace "$VERILATOR_SAFE"
command -v "$VERILATOR_SIM_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SIM_SAFE" >&2; exit 127; }

run_test() {
    top="$1"
    marker="$2"
    mdir="$(s32_verilator_mdir "$top")"
    "$VERILATOR_SAFE" status
    "$VERILATOR_SAFE" --binary --timing --threads 1 --verilate-jobs 4 --build-jobs 4 -Wno-fatal \
        --top-module "$top" --Mdir "$mdir" \
        rtl/cpu/v60/s32_v60.sv \
        rtl/cpu/v60/s32_v60_bus.sv \
        "verif/v60/${top}.sv"
    "$VERILATOR_SIM_SAFE" -- "$mdir/V${top}" | grep -q "$marker"
    echo "$top: PASS"
}

run_test tb_v60_spidman_xchh "SPIDMAN XCH.H PASS"
run_test tb_v60_spidman_window "SPIDMAN WINDOW PASS"
run_test tb_v60_spidman_gate "SPIDMAN GATE PASS (6 cases)"

echo "SPIDMAN TRIGGER REGRESSION: PASS"
