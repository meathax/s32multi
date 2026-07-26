#!/usr/bin/env bash
# Full-core MiSTer S32 functional sim under Verilator (fast, no hardware).
# Boots real ROMs through s32_core (HLE protection), renders RGB video, dumps
# frames as PPM.  Requires WSL verilator 5.x.  Run from repo root.
#   ./run_romboot.sh <game> [FRAMES] [extra +plusargs...]
# e.g. ./run_romboot.sh orunners 20
set -u
cd "$(dirname "$0")/../.."
GAME="${1:-ga2}"; FRAMES="${2:-90}"; shift 2 2>/dev/null || shift $# 
MDIR=/tmp/vromboot
WARN="-Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME"
# B0 board bits: bit1=has_v25 bit2=v25_table(1=arabfgt) bit5=has_ppi
# B2 protection selector: 1 = SegaSonic rev. C level-loader HLE
B1=0; B2=0; SBM=3
case "$GAME" in
  ga2)     B0=22 ;;   # has_v25 + has_ppi
  arabfgt) B0=26 ;;   # has_v25 + v25_table + has_ppi
  spidman) B0=20 ;;   # has_ppi only
  sonic)   B0=10; B2=1; SBM=1 ;; # has_track + Sonic protection + 4 MiB sprites
  orunners) B0=09; B1=10 ;; # Multi32 + ADC + OutRunners station wiring
  *)       B0=20 ;;
esac
verilator --binary --timing -j 0 $WARN +define+SIMULATION +define+S32_REAL_FB_SIM \
  --top-module tb_core_romboot --Mdir "$MDIR" -o romboot -f scratch/romboot.f 2>&1 | grep -E "%Error" && exit 1
mkdir -p scratch/vromboot_out && cd scratch/vromboot_out
"$MDIR/romboot" +IMG="$(cd ../.. && pwd)/roms/sim/$GAME" +B0=$B0 +B1=$B1 +B2=$B2 +SBM=$SBM +FRAMES=$FRAMES "$@"
