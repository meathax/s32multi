#!/usr/bin/env bash
# Deterministic full-core Arabian Fight performance/visual regression.
# Uses the production real-V25 configuration and persistent Verilator output.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root="$PWD"
run_id="${ARAB_RUN_ID:-latest}"
out_dir="scratch/arabfgt-regression/$run_id"
microcode="$root/rtl/cpu/v25/s80x86/generated"
warn="-Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-SYNCASYNCNET"
verilator_safe="${VERILATOR_SAFE:-verilator-safe}"
verilator_sim_safe="${VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$verilator_safe" >/dev/null 2>&1 || { echo "missing $verilator_safe" >&2; exit 127; }

source verif/verilator/workspace.sh
s32_verilator_workspace "$verilator_safe"
build_dir="$(s32_verilator_mdir arabfgt_obj)"
command -v "$verilator_sim_safe" >/dev/null 2>&1 || { echo "missing $verilator_sim_safe" >&2; exit 127; }

mkdir -p "$build_dir" "$out_dir"
"$verilator_safe" status
"$verilator_safe" --binary --timing -O3 --threads 1 \
  --verilate-jobs 4 --build-jobs 4 $warn \
  +define+SIMULATION +define+S32_REAL_FB_SIM \
  +define+S32_SYSTEM32_ONLY \
  +define+S32_PROFILE_STANDARD +define+S32_GAME_ONLY \
  +define+S32_UNIVERSAL +define+S32_V25_HW +define+S80X86_PSEUDO_286_INT=0 \
  "-DMICROCODE_ROM_PATH=\"$microcode\"" \
  --top-module tb_core_romboot --Mdir "$build_dir" -o romboot \
  -f verif/v25/s80x86.f \
  rtl/cpu/v25/s32_v25_rom_cache.sv rtl/cpu/v25/s32_v25_cpu.sv \
  -f scratch/romboot.f

(
  cd "$out_dir"
  "$verilator_sim_safe" -- "$build_dir/romboot" \
    +IMG="$root/roms/sim/arabfgt" +B0=26 +B1=0 +B2=0 +SBM=3 \
    +CPUDIV=2 +FRAMES=155 +ARABPERFAT=140 +ARABPERFN=13 \
    +ARABHEAVYAT=148 +ARABHEAVYN=6 +ARABHEAVYMIN=3 \
    +DUMPAT=148 +DUMPN=6 +DUMPSPRAT=148 \
    +PCHIST=140 +PCHISTLEN=10 +SPRLOG=1 +OVLOG=1 \
    2>&1 | tee regression.log
)
