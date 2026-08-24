#!/usr/bin/env bash
# Verilator cross-validation matrix for the sdram.sv request-latch fix.
# {fixed RTL, pre-fix reconstruction} x {edge-aligned PLL, half-offset TB phase}.
set -u
cd "$(dirname "$0")/../.." || exit 1   # repo root
WARN="-Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-INITIALDLY"
VERILATOR_SAFE="${VERILATOR_SAFE:-verilator-safe}"
VERILATOR_SIM_SAFE="${VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$VERILATOR_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SAFE" >&2; exit 127; }

source verif/verilator/workspace.sh
s32_verilator_workspace "$VERILATOR_SAFE"
MDIR="$(s32_verilator_mdir vsdram)"
BUILD_LOG="$S32_VERILATOR_WORKSPACE/vbuild.log"
command -v "$VERILATOR_SIM_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SIM_SAFE" >&2; exit 127; }

run() {
  local tag="$1" dut="$2" phase="$3" vcd="$4" expected="$5"
  local def="+define+SIMULATION"
  [ "$phase" = "half" ] && def="$def +define+HALF_OFFSET"
  "$VERILATOR_SAFE" status
  "$VERILATOR_SAFE" --binary --timing --trace --threads 1 \
     --verilate-jobs 4 --build-jobs 4 $WARN --top-module tb_sdram_edge $def \
     -CFLAGS "-D_GLIBCXX_USE_CXX11_ABI=0" \
     --Mdir "$MDIR" -o tb_sdram_edge verif/verilator/tb_sdram_edge.sv "$dut" >"$BUILD_LOG" 2>&1
  local build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    echo "[$tag] BUILD FAILED"
    tail -20 "$BUILD_LOG"
    return "$build_rc"
  fi
  # rename the vcd this run produces so runs don't clobber each other
  local sim_exe="$MDIR/tb_sdram_edge"
  if command -v cygpath >/dev/null 2>&1; then
    sim_exe="$(cygpath -w "$sim_exe")"
  fi
  local out
  if ! out="$("$VERILATOR_SIM_SAFE" -- "$sim_exe" 2>&1)"; then
    echo "[$tag] SIMULATION FAILED"
    printf '%s\n' "$out" | tail -20
    return 1
  fi
  [ -n "$vcd" ] && [ -f verif/verilator/tb_sdram_edge.vcd ] && mv verif/verilator/tb_sdram_edge.vcd "$vcd"
  local res; res="$(echo "$out" | grep -E 'RESULT|HUNG|lost' | head -3 | tr '\n' ' ')"
  local cnt; cnt="$(echo "$out" | grep -E 'icache|V25 burst' | tr '\n' ' ')"
  printf '[%-22s] %s || %s\n' "$tag" "$res" "$cnt"
  if [ "$expected" = "PASS" ]; then
    echo "$out" | grep -Fq 'RESULT: PASS' || { echo "[$tag] expected PASS marker"; return 1; }
  elif [ "$expected" = "FAIL" ]; then
    echo "$out" | grep -Eq 'RESULT: FAIL|HUNG|lost' || { echo "[$tag] expected pre-fix failure marker"; return 1; }
  else
    echo "$out" | grep -Eq 'RESULT: PASS|RESULT: FAIL|HUNG|lost' || { echo "[$tag] expected a completed result marker"; return 1; }
  fi
}

echo "=== sdram.sv arbitration cross-validation (Verilator 5.032) ==="
run "FIXED  edge-aligned"  rtl/mem/sdram.sv        edge verif/verilator/tb_sdram_edge_fixed.vcd PASS || exit $?
run "FIXED  half-offset"   rtl/mem/sdram.sv        half "" PASS || exit $?
run "PREFIX edge-aligned"  scratch/sdram_prefix.sv edge verif/verilator/tb_sdram_edge_prefix.vcd EITHER || exit $?
run "PREFIX half-offset"   scratch/sdram_prefix.sv half "" FAIL || exit $?
echo "=== VCDs: tb_sdram_edge_fixed.vcd (pass), tb_sdram_edge_prefix.vcd (hang) ==="
