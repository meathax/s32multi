#!/usr/bin/env bash
# Verilator V60 unit-test runner. Builds + runs every self-checking tb_v60_*.sv
# (including the orphaned tb_v60_xch and the spidman trio that the main
# ModelSim regression skips) and checks each PASS marker. Second-simulator
# safety net for V60 fetch/prefetch work. Usage: bash verif/v60/run_v60_verilator.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT="$PWD"
PKG="rtl/s32_pkg.sv"
CPU="rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv"
VERILATOR_SAFE="${VERILATOR_SAFE:-verilator-safe}"
VERILATOR_SIM_SAFE="${VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$VERILATOR_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SAFE" >&2; exit 127; }
source verif/verilator/workspace.sh
s32_verilator_workspace "$VERILATOR_SAFE"
command -v "$VERILATOR_SIM_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SIM_SAFE" >&2; exit 127; }
VFLAGS=(--binary --timing --threads 1 --verilate-jobs 4 --build-jobs 4
  -CFLAGS "-D_GLIBCXX_USE_CXX11_ABI=0"
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
  -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
  -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH
  +define+SIMULATION)

# tb : expected-marker (marker is a grep -F fixed string)
declare -A TB=(
  [tb_v60_smoke]="SMOKE PASS"
  [tb_v60_directed]="DIRECTED PASS"
  [tb_v60_fetch]="FETCH PERF PASS"
  [tb_v60_smc]="V60 SMC PASS"
  [tb_v60_long_ea]="LONG EA PASS"
  [tb_v60_bus_lanes]="V60 BUS LANES PASS"
  [tb_v60_divx]="DIVX PASS"
  [tb_v60_divxmem]="V60 DIVXMEM PASS"
  [tb_v60_flags]="V60 FLAGS PASS"
  [tb_v60_ga2_bossbar]="V60 GA2 BOSSBAR PASS"
  [tb_v60_incdecmem]="V60 INCDECMEM PASS"
  [tb_v60_rotate]="V60 ROTATE PASS"
  [tb_v60_shaov]="V60 SHAOV PASS"
  [tb_v60_xch]="V60 XCH PASS"
  [tb_v60_audit]="AUDIT PASS"
  [tb_v60_bits]="BITS PASS"
  [tb_v60_decimal]="DECIMAL PASS"
  [tb_v60_search]="V60 SEARCH PASS"
  [tb_v60_cmpc]="V60 CMPC PASS"
  [tb_v60_movcd]="V60 MOVCD PASS"
  [tb_v60_schd]="V60 SCHD PASS"
  [tb_v60_strfs]="V60 STRFS PASS"
  [tb_v60_fp]="V60 FP PASS"
  [tb_v60_fpdecode]="V60 FPDECODE PASS"
  [tb_v60_spidman_xchh]="SPIDMAN XCH.H PASS"
  [tb_v60_spidman_window]="SPIDMAN WINDOW PASS"
  [tb_v60_spidman_gate]="SPIDMAN GATE PASS"
  [tb_v60_ea_overlap_disp]="V60 EA_OVERLAP DISP PASS"
)

# Verilator can't elaborate testbenches that poke internal enum FSM state
# (EnumItemRef can't deref back to an Enum). Route those through Icarus.
ICARUS_ONLY="tb_v60_search tb_v60_cmpc tb_v60_movcd tb_v60_schd tb_v60_strfs tb_v60_fp tb_v60_ea_overlap_disp"

ORDER="tb_v60_smoke tb_v60_directed tb_v60_fetch tb_v60_smc tb_v60_long_ea tb_v60_bus_lanes tb_v60_divx tb_v60_divxmem tb_v60_flags tb_v60_ga2_bossbar tb_v60_incdecmem tb_v60_rotate tb_v60_shaov tb_v60_xch tb_v60_audit tb_v60_bits tb_v60_decimal tb_v60_search tb_v60_cmpc tb_v60_movcd tb_v60_schd tb_v60_strfs tb_v60_fp tb_v60_fpdecode tb_v60_spidman_xchh tb_v60_spidman_window tb_v60_spidman_gate tb_v60_ea_overlap_disp"

is_icarus() { case " $ICARUS_ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

work_root="$S32_VERILATOR_WORKSPACE/v60ut"
mkdir -p "$work_root"
pass=0; fail=0; failed=""
for tb in $ORDER; do
  src="verif/v60/${tb}.sv"
  [ -f "$src" ] || { echo "SKIP  $tb (no file)"; continue; }
  bdir="$work_root/$tb"; rm -rf "$bdir"; mkdir -p "$bdir"
  if is_icarus "$tb"; then
    if ! iverilog -g2012 -Wno-timescale -o "$bdir/$tb.vvp" -s "$tb" $PKG $CPU "$src" > "$bdir.log" 2>&1; then
      echo "BUILDFAIL $tb (icarus)  (see $bdir.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
    fi
    out="$(cd "$bdir" && timeout 300 vvp "$tb.vvp" 2>&1)"
  else
    "$VERILATOR_SAFE" status
    if ! "$VERILATOR_SAFE" "${VFLAGS[@]}" --top-module "$tb" --Mdir "$bdir" -o "$tb" $PKG $CPU "$src" > "$bdir.log" 2>&1; then
      echo "BUILDFAIL $tb  (see $bdir.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
    fi
    out="$("$VERILATOR_SIM_SAFE" -- "$bdir/$tb.exe" 2>&1)"
  fi
  if echo "$out" | grep -qF "${TB[$tb]}"; then
    extra="$(echo "$out" | grep -E 'FETCH PERF:|LANES|cycles=' | head -1)"
    echo "PASS  $tb   ${extra}"
    pass=$((pass+1))
  else
    echo "FAIL  $tb   (expected '${TB[$tb]}')"
    echo "$out" | tail -3 | sed 's/^/        /'
    fail=$((fail+1)); failed="$failed $tb"
  fi
done
# gated-ce (production /3 cadence) coherency re-run of the SMC test — catches
# prefetch ack-sampling bugs that ce=1 runs would miss (audit gated-ce gap).
smc_exe="$work_root/tb_v60_smc/tb_v60_smc"
[ -x "${smc_exe}.exe" ] && smc_exe="${smc_exe}.exe"
if [ -x "$smc_exe" ]; then
  if "$VERILATOR_SIM_SAFE" -- "$smc_exe" +CEDIV=3 2>&1 | grep -qF "V60 SMC PASS"; then
    echo "PASS  tb_v60_smc(ce=/3)"
  else
    echo "FAIL  tb_v60_smc(ce=/3)"; fail=$((fail+1)); failed="$failed tb_v60_smc(ce/3)"
  fi
fi
echo "======================================================"
echo "V60 VERILATOR UNIT: $pass passed, $fail failed${failed:+ -> FAILED:$failed}"
[ "$fail" -eq 0 ] && echo "V60 VERILATOR UNIT: ALL PASS"
exit $fail
