#!/usr/bin/env bash
# Long-form Golden Axe framebuffer run using the production real-V25 profile.
# Unlike run_romboot.sh, this includes the encrypted MCU, its external p5 ROM
# path, internal data RAM, CDC bridge, and Golden Axe-only synthesis choices.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

frames="${1:-650}"
shift 2>/dev/null || true
output_dir="${REAL_V25_OUT:-scratch/vromboot_real_out}"
microcode="$repo_root/rtl/cpu/v25/s80x86/generated"
warnings=(
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
  -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN
  -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-SYNCASYNCNET
)
verilator_safe="${VERILATOR_SAFE:-verilator-safe}"
verilator_sim_safe="${VERILATOR_SIM_SAFE:-verilator-sim-safe}"
command -v "$verilator_safe" >/dev/null 2>&1 || { echo "missing $verilator_safe" >&2; exit 127; }

source verif/verilator/workspace.sh
s32_verilator_workspace "$verilator_safe"
build_dir="$(s32_verilator_mdir real_v25_romboot)"
command -v "$verilator_sim_safe" >/dev/null 2>&1 || { echo "missing $verilator_sim_safe" >&2; exit 127; }

# The machine-wide safe launcher serializes model builds and limits both
# Verilator generation and the C++ build.  This runner is part of the V25 gate.
"$verilator_safe" status
"$verilator_safe" --binary --timing --verilate-jobs 4 --build-jobs 4 --threads 1 "${warnings[@]}" \
  -CFLAGS "-D_GLIBCXX_USE_CXX11_ABI=0" \
  +define+SIMULATION +define+S32_REAL_FB_SIM \
  +define+S32_SYSTEM32_ONLY +define+S32_PROFILE_STANDARD \
  +define+S32_UNIVERSAL +define+S32_V25_HW +define+S80X86_PSEUDO_286_INT=0 \
  "-DMICROCODE_ROM_PATH=\"$microcode\"" \
  --top-module tb_core_romboot --Mdir "$build_dir" -o romboot \
  -f verif/v25/s80x86.f \
  rtl/cpu/v25/s32_v25_rom_cache.sv rtl/cpu/v25/s32_v25_cpu.sv \
  -f scratch/romboot.f

mkdir -p "$output_dir"
cd "$output_dir"
romboot_exe="$build_dir/romboot"
[[ -x "${romboot_exe}.exe" ]] && romboot_exe="${romboot_exe}.exe"
"$verilator_sim_safe" -- "$romboot_exe" \
  +IMG="$repo_root/roms/sim/ga2" +DESC="$repo_root/roms/sim/ga2/desc.txt" \
  +FRAMES="$frames" "$@"
