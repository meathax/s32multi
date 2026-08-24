#!/usr/bin/env bash
# Full-core MiSTer S32 functional sim under Verilator (fast, no hardware).
# Boots real ROMs through s32_core (HLE protection), renders RGB video, dumps
# frames as PPM.  Requires WSL verilator 5.x.  Run from repo root.
#   ./run_romboot.sh <game> [FRAMES] [extra +plusargs...]
# Set ROMBOOT_SKIP_BUILD=1 when only runtime arguments changed.
# e.g. ./run_romboot.sh ga2 135 +COINAT=64 +COINLEN=6 +STARTAT=84 +DUMPAT=104 +DUMPN=16
set -euo pipefail
cd "$(dirname "$0")/../.."
GAME="${1:-ga2}"; FRAMES="${2:-90}"; shift 2 2>/dev/null || shift $#
VERILATOR_SAFE="${VERILATOR_SAFE:-verilator-safe}"
command -v "$VERILATOR_SAFE" >/dev/null 2>&1 || { echo "missing $VERILATOR_SAFE" >&2; exit 127; }
source verif/verilator/workspace.sh
s32_verilator_workspace "$VERILATOR_SAFE"
MDIR="$(s32_verilator_mdir vromboot_obj)"
WARN="-Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME"
# The board descriptor comes from the image's own desc.txt, which
# make_sim_images.py copies verbatim out of the MRA's ioctl index-0 stream.
# It is deliberately NOT hardcoded here: the previous per-game case defaulted to
# B0=20 (has_ppi) for anything unlisted, so most of the 17 sets simulated a
# machine the core does not ship -- missing ADC, phantom 8255, no protection
# selector, wrong sprite bank mask.  Override individual fields on the command
# line (+B0/+B1/+B2/+SBM) when a test needs to vary one.
DESC="$PWD/roms/sim/$GAME/desc.txt"
if [[ ! -f "$DESC" ]]; then
  echo "run_romboot: no descriptor at $DESC" >&2
  echo "  build the image first: python tools/make_sim_images.py <mra> roms/$GAME.zip roms/sim/$GAME" >&2
  exit 1
fi
# The machine-wide safe launcher serializes model builds and enforces the
# account resource policy.  Keep both Verilator generation and C++ build
# parallelism explicitly bounded; generated models are always single-threaded.
"$VERILATOR_SAFE" status
if [[ "${ROMBOOT_SKIP_BUILD:-0}" != 1 ]]; then
  "$VERILATOR_SAFE" --binary --timing --verilate-jobs 4 --build-jobs 4 --threads 1 $WARN \
    -CFLAGS "-D_GLIBCXX_USE_CXX11_ABI=0" \
    +define+SIMULATION +define+S32_REAL_FB_SIM +define+S32_OUTRUNNERS \
    --top-module tb_core_romboot --Mdir "$MDIR" -o romboot -f scratch/romboot.f
fi
SIM="$MDIR/romboot"
[[ -x "${SIM}.exe" ]] && SIM="${SIM}.exe"
IMG="$PWD/roms/sim/$GAME"
if [[ ! -x "$SIM" ]]; then
  echo "run_romboot: no model executable at $SIM (unset ROMBOOT_SKIP_BUILD)" >&2
  exit 1
fi
# Keep captures isolated when a queued run outlives its terminal caller.  The
# default preserves the historical location; callers doing a matrix sweep can
# set ROMBOOT_OUT to a game-specific directory.
OUTDIR="${ROMBOOT_OUT:-$PWD/scratch/vromboot_out}"
mkdir -p "$OUTDIR" && cd "$OUTDIR"
"$VERILATOR_SAFE" sim -- "$SIM" +IMG="$IMG" \
  +DESC="$DESC" +FRAMES=$FRAMES "$@"
