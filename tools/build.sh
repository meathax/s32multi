#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
  'ERROR: tools/build.sh is disabled.' \
  '' \
  'This legacy Linux/CI path bypasses the locked, fingerprinted, per-game' \
  'release gates and must not produce or qualify a public RBF.' \
  '' \
  'Use the supported Windows universal-profile pipeline:' \
  '  set QUARTUS_ROOT=D:\Q17' \
  '  tools\build-s32.bat' \
  '' \
  'The supported path validates Quartus Lite 17.0.2.602, performs a clean' \
  'synthesis, classifies fitter retries, runs STA before assembly, and stages' \
  'only a hash-verified RBF.' >&2
exit 2
