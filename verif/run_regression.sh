#!/bin/sh
# System 32 core regression (DESIGN.md §11): grows with each milestone.
set -e
cd "$(dirname "$0")/.."
echo "[1/35] full-core lint compile (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_lint \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint | grep -q "CORE UNIVERSAL LINT PASS" || { echo "CORE UNIVERSAL LINT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY -o /tmp/s32_lint_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint_s32 | grep -q "CORE S32-ONLY LINT PASS" && echo "CORE BUILD PROFILES: PASS" || { echo "CORE S32-ONLY LINT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_OUTRUNNERS_ONLY -DS32_RELEASE_MINIMAL -o /tmp/s32_lint_orunners \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint_orunners | grep -q "CORE OUTRUNNERS PROFILE LINT PASS" || { echo "CORE OUTRUNNERS PROFILE LINT: FAIL"; exit 1; }
echo "[2/35] V60 smoke test"
iverilog -g2012 -o /tmp/s32_v60_smoke \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_smoke.sv
vvp /tmp/s32_v60_smoke | grep -q "SMOKE PASS" && echo "V60 SMOKE: PASS" || { echo "V60 SMOKE: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v70_profile \
  rtl/cpu/v60/s32_v60.sv verif/v60/tb_v70_profile.sv
vvp /tmp/s32_v70_profile | grep -q "V70 PROFILE PASS" && echo "V70 PROFILE: PASS" || { echo "V70 PROFILE: FAIL"; exit 1; }
echo "[3/35] V60 directed suite"
iverilog -g2012 -o /tmp/s32_v60_dir \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_directed.sv
vvp /tmp/s32_v60_dir | grep -q "DIRECTED PASS" && echo "V60 DIRECTED: PASS" || { echo "V60 DIRECTED: FAIL"; exit 1; }
echo "[4/35] full-core integration boot (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_boot \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot | grep -q "CORE BOOT PASS" || { echo "CORE UNIVERSAL BOOT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY -o /tmp/s32_boot_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot_s32 | grep -q "CORE BOOT PASS" && echo "CORE BUILD-PROFILE BOOTS: PASS" || { echo "CORE S32-ONLY BOOT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_OUTRUNNERS_ONLY -DS32_RELEASE_MINIMAL -o /tmp/s32_boot_orunners \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot_orunners | grep -q "CORE BOOT PASS" || { echo "CORE OUTRUNNERS BOOT: FAIL"; exit 1; }
echo "[5/35] V60 differential co-sim vs independent reference (50 seeds)"
sh verif/cosim/run_diff.sh 50
echo "[6/35] full-core soak / simulator-tier acceptance (extended multi-frame)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_soak \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_soak.sv
vvp /tmp/s32_soak | grep -q "CORE SOAK PASS" && echo "CORE SOAK: PASS" || { echo "CORE SOAK: FAIL"; exit 1; }
echo "[7/35] V60 audit-fix directed test (string/CALL/RET/RSR — audit.md)"
iverilog -g2012 -o /tmp/s32_v60_audit \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_audit.sv
vvp /tmp/s32_v60_audit | grep -q "AUDIT PASS" && echo "V60 AUDIT: PASS" || { echo "V60 AUDIT: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v60_search \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_search.sv
vvp /tmp/s32_v60_search | grep -q "V60 SEARCH PASS" && echo "V60 SEARCH: PASS" || { echo "V60 SEARCH: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v60_strfs \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_strfs.sv
vvp /tmp/s32_v60_strfs | grep -q "V60 STRFS PASS" && echo "V60 STRFS: PASS" || { echo "V60 STRFS: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v60_fp \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_fp.sv
vvp /tmp/s32_v60_fp | grep -q "V60 FP PASS" && echo "V60 FP: PASS" || { echo "V60 FP: FAIL"; exit 1; }
iverilog -g2012 -o /tmp/s32_v60_fpdecode \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_fpdecode.sv
vvp /tmp/s32_v60_fpdecode | grep -q "V60 FPDECODE PASS" && echo "V60 FPDECODE: PASS" || { echo "V60 FPDECODE: FAIL"; exit 1; }
iverilog -g2012 -DS32_V60_NO_FP -o /tmp/s32_v60_no_fp \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_no_fp.sv
vvp /tmp/s32_v60_no_fp | grep -q "V60 NO-FP PASS" && echo "V60 NO-FP: PASS" || { echo "V60 NO-FP: FAIL"; exit 1; }
echo "[8/35] release contracts + exact Golden Axe profile boot/cache"
python3 verif/check_holo_release.py | grep -q "HOLO RELEASE MRA PASS" || { echo "HOLO RELEASE MRA: FAIL"; exit 1; }
python3 verif/check_ga2_release.py | grep -q "GA2 COMPAT MRA PASS" || { echo "GA2 COMPAT MRA: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_GOLDENAXE_ONLY -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY \
  -DS32_V60_NO_FP -DS32_RELEASE_MINIMAL -o /tmp/s32_ga2 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_ga2path.sv
vvp /tmp/s32_ga2 | grep -q "GA2 PATH PASS" && echo "GA2 PATH: PASS" || { echo "GA2 PATH: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_GOLDENAXE_ONLY -DS32_SYSTEM32_ONLY -DS32_GA2_ONLY \
  -DS32_V60_NO_FP -DS32_RELEASE_MINIMAL -s tb_ga_rom_cache -o /tmp/s32_ga_rom_cache \
  rtl/s32_pkg.sv rtl/s32_core.sv verif/common/tb_ga_rom_cache.sv
vvp /tmp/s32_ga_rom_cache | grep -q "PASS: Golden Axe ROM cache directed/reference tests passed" && \
  echo "GOLDEN AXE ROM CACHE: PASS" || { echo "GOLDEN AXE ROM CACHE: FAIL"; exit 1; }
echo "[9/35] framebuffer interface directed test (runs / shadow RMW / erase / read)"
iverilog -g2012 -o /tmp/s32_fbif rtl/mem/s32_fb_if.sv verif/common/tb_fb_if.sv
vvp /tmp/s32_fbif | grep -q "FB IF PASS" && echo "FB IF: PASS" || { echo "FB IF: FAIL"; exit 1; }
echo "[10/35] mixer directed + 512-case independent differential test"
iverilog -g2012 -o /tmp/s32_mix rtl/video/s32_linebuf.sv rtl/video/s32_mixer.sv \
  rtl/video/s32_palette.sv verif/common/tb_mixer.sv
vvp /tmp/s32_mix | grep -q "MIXER PASS" && echo "MIXER: PASS" || { echo "MIXER: FAIL"; exit 1; }
python3 -m verif.mixer_diff.generate_vectors /tmp/s32_mixer_vectors.hex --seed 5387 --count 512
iverilog -g2012 -o /tmp/s32_mixdiff rtl/video/s32_mixer.sv verif/mixer_diff/tb_mixer_diff.sv
vvp /tmp/s32_mixdiff +VECTORS=/tmp/s32_mixer_vectors.hex | grep -q "MIXER DIFF PASS cases=512" && echo "MIXER DIFFERENTIAL: PASS (512 cases)" || { echo "MIXER DIFFERENTIAL: FAIL"; exit 1; }
echo "[11/35] sprite pixel-path directed test (pen rules / end codes / flip / zoom / indirect)"
iverilog -g2012 -o /tmp/s32_spr rtl/video/s32_sprite.sv verif/common/tb_sprite.sv
vvp /tmp/s32_spr | grep -q "SPRITE PASS" && echo "SPRITE: PASS" || { echo "SPRITE: FAIL"; exit 1; }
echo "[12/35] sprite scale divider exactness / fixed-latency test"
iverilog -g2012 -s tb_sprite_div -o /tmp/s32_sprdiv rtl/video/s32_sprite.sv verif/common/tb_sprite_div.sv
vvp /tmp/s32_sprdiv | grep -q "SPRITE DIV PASS" && echo "SPRITE DIV: PASS" || { echo "SPRITE DIV: FAIL"; exit 1; }
echo "[13/35] V60 DIVX/DIVUX iterative 64/32 exactness / latency test"
iverilog -g2012 -o /tmp/s32_v60_divx rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_divx.sv
vvp /tmp/s32_v60_divx | grep -q "DIVX PASS" && echo "V60 DIVX: PASS" || { echo "V60 DIVX: FAIL"; exit 1; }
echo "[14/35] V60 decimal group directed test (ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP)"
iverilog -g2012 -o /tmp/s32_v60dec rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_decimal.sv
vvp /tmp/s32_v60dec | grep -q "DECIMAL PASS" && echo "V60 DECIMAL: PASS" || { echo "V60 DECIMAL: FAIL"; exit 1; }
echo "[15/35] V60 bit string/field directed test (EXTBF/INSBF/SCHBS/MOVBS)"
iverilog -g2012 -o /tmp/s32_v60bits rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_bits.sv
vvp /tmp/s32_v60bits | grep -q "BITS PASS" && echo "V60 BITS: PASS" || { echo "V60 BITS: FAIL"; exit 1; }
echo "[16/35] V60 short backward-branch fetch performance"
iverilog -g2012 -o /tmp/s32_v60_fetch \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_fetch.sv
vvp /tmp/s32_v60_fetch | grep -q "FETCH PERF PASS" && echo "V60 FETCH PERF: PASS" || { echo "V60 FETCH PERF: FAIL"; exit 1; }
echo "[17/35] ROM loader reset / mapping / completion gating"
iverilog -g2012 -o /tmp/s32_rom_loader \
  rtl/s32_pkg.sv rtl/mem/s32_rom_loader.sv verif/common/tb_rom_loader.sv
vvp /tmp/s32_rom_loader | grep -q "ROM LOADER PASS" && echo "ROM LOADER: PASS" || { echo "ROM LOADER: FAIL"; exit 1; }
echo "[18/35] EEPROM NVRAM upload byte order / dirty-state persistence"
iverilog -g2012 -o /tmp/s32_eeprom_nvram \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_eeprom_nvram.sv
vvp /tmp/s32_eeprom_nvram | grep -q "EEPROM NVRAM PASS" && echo "EEPROM NVRAM: PASS" || { echo "EEPROM NVRAM: FAIL"; exit 1; }
echo "[19/35] V60 20-byte F1 / high fetch-buffer offset regression"
iverilog -g2012 -o /tmp/s32_v60_long_ea \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_long_ea.sv
vvp /tmp/s32_v60_long_ea | grep -q "LONG EA PASS" && echo "V60 LONG EA: PASS" || { echo "V60 LONG EA: FAIL"; exit 1; }
echo "[20/35] RF5C68 dual-port wave RAM / loop-fetch / channel cadence"
iverilog -g2012 -o /tmp/s32_rf5c68 \
  rtl/video/s32_big_dpram.sv rtl/audio/s32_rf5c68.sv verif/common/tb_rf5c68.sv
vvp /tmp/s32_rf5c68 | grep -q "RF5C68 PASS" && echo "RF5C68: PASS" || { echo "RF5C68: FAIL"; exit 1; }
echo "[21/35] palette RAM alias / byte-enable / write-both / dual-port timing"
iverilog -g2012 -o /tmp/s32_palette \
  rtl/video/s32_palette.sv verif/common/tb_palette.sv
vvp /tmp/s32_palette | grep -q "PALETTE PASS" && echo "PALETTE: PASS" || { echo "PALETTE: FAIL"; exit 1; }
echo "[22/35] shared tile/bitmap line-buffer latency / layer / parity isolation"
iverilog -g2012 -o /tmp/s32_linebuf \
  rtl/video/s32_linebuf.sv verif/common/tb_linebuf.sv
vvp /tmp/s32_linebuf | grep -q "LINEBUF PASS" && echo "LINEBUF: PASS" || { echo "LINEBUF: FAIL"; exit 1; }
echo "[23/35] tilemap VRAM fetches and deadline-safe scanline scheduling"
iverilog -g2012 -DSIMULATION -o /tmp/s32_tilemap_vram \
  rtl/video/s32_big_dpram.sv rtl/video/s32_vram.sv \
  rtl/video/s32_tilemap.sv verif/common/tb_tilemap_vram.sv
vvp /tmp/s32_tilemap_vram | grep -q "TILEMAP VRAM PASS" && echo "TILEMAP VRAM: PASS" || { echo "TILEMAP VRAM: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -s tb_tile_scheduler -o /tmp/s32_tile_scheduler \
  rtl/video/s32_tilemap.sv verif/common/tb_tile_scheduler.sv
vvp /tmp/s32_tile_scheduler | grep -q "TILE SCHEDULER PASS" && echo "TILE SCHEDULER: PASS" || { echo "TILE SCHEDULER: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -s tb_tile_backpressure -o /tmp/s32_tile_backpressure \
  rtl/video/s32_tilemap.sv verif/common/tb_tile_backpressure.sv
vvp /tmp/s32_tile_backpressure | grep -q "TILE BACKPRESSURE PASS" && echo "TILE BACKPRESSURE: PASS" || { echo "TILE BACKPRESSURE: FAIL"; exit 1; }
echo "[24/35] byte-wide true-dual-port BRAM timing / hold / collision semantics"
iverilog -g2012 -s tb_byte_dpram -o /tmp/s32_byte_dpram \
  rtl/video/s32_big_dpram.sv verif/common/tb_byte_dpram.sv
vvp /tmp/s32_byte_dpram | grep -q "BYTE DPRAM PASS" && echo "BYTE DPRAM: PASS" || { echo "BYTE DPRAM: FAIL"; exit 1; }
echo "[25/35] V25 mailbox BRAM + production MLAB FIFO profile"
iverilog -g2012 -s tb_v25_dpram -o /tmp/s32_v25_dpram \
  rtl/s32_pkg.sv rtl/video/s32_big_dpram.sv rtl/prot/s32_prot.sv \
  verif/common/tb_v25_dpram.sv
vvp /tmp/s32_v25_dpram | grep -q "V25 DPRAM PASS" && echo "V25 DPRAM: PASS" || { echo "V25 DPRAM: FAIL"; exit 1; }
iverilog -g2012 -DS32_V25_MLAB_FIFO -s Fifo -o /tmp/s32_v25_mlab_fifo \
  rtl/cpu/v25/s80x86/rtl/Fifo.sv
echo "V25 MLAB FIFO COMPILE: PASS"
echo "[26/35] SDRAM CL2 centred input capture / first-word freshness / burst ordering"
iverilog -g2012 -s tb_sdram -o /tmp/s32_sdram \
  rtl/mem/sdram.sv verif/common/tb_sdram.sv
vvp /tmp/s32_sdram | grep -q "SDRAM CAPTURE PASS" && echo "SDRAM CAPTURE: PASS" || { echo "SDRAM CAPTURE: FAIL"; exit 1; }
echo "[27/35] integrated sprite renderer / backpressured DDR framebuffer stress"
iverilog -g2012 -s tb_sprite_fb -o /tmp/s32_sprite_fb \
  rtl/video/s32_sprite.sv rtl/mem/s32_fb_if.sv \
  verif/common/tb_sprite_fb.sv
vvp /tmp/s32_sprite_fb | grep -q "SPRITE FB PASS" && echo "SPRITE FB: PASS" || { echo "SPRITE FB: FAIL"; exit 1; }
iverilog -g2012 -s tb_sprite_vblank -o /tmp/s32_sprite_vblank \
  rtl/video/s32_sprite.sv rtl/mem/s32_fb_if.sv \
  verif/common/tb_sprite_vblank.sv
vvp /tmp/s32_sprite_vblank | grep -q "SPRITE VBLANK PASS" && echo "SPRITE VBLANK: PASS" || { echo "SPRITE VBLANK: FAIL"; exit 1; }
echo "[28/35] interrupt controller reset / source+ack collision / timers / doorbell"
iverilog -g2012 -s tb_intc -o /tmp/s32_intc \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_intc.sv
vvp /tmp/s32_intc | grep -q "INTC PASS" && echo "INTC: PASS" || { echo "INTC: FAIL"; exit 1; }
echo "[29/35] audio route arithmetic + generic/Golden Axe differential"
iverilog -g2012 -s tb_audio_mix -o /tmp/s32_audio_mix \
  rtl/audio/s32_audio_mix.sv verif/common/tb_audio_mix.sv
vvp /tmp/s32_audio_mix | grep -q "AUDIO MIX PASS" && echo "AUDIO MIX: PASS" || { echo "AUDIO MIX: FAIL"; exit 1; }
iverilog -g2012 -s tb_audio_mix_diff -o /tmp/s32_audio_mix_diff_generic \
  rtl/audio/s32_audio_mix.sv verif/common/tb_audio_mix_diff.sv
vvp /tmp/s32_audio_mix_diff_generic | grep -q "PASS: audio mixer differential checks=20012" && \
  echo "AUDIO MIX DIFFERENTIAL (GENERIC): PASS" || { echo "AUDIO MIX DIFFERENTIAL (GENERIC): FAIL"; exit 1; }
iverilog -g2012 -DS32_GOLDENAXE_ONLY -s tb_audio_mix_diff -o /tmp/s32_audio_mix_diff_ga \
  rtl/audio/s32_audio_mix.sv verif/common/tb_audio_mix_diff.sv
vvp /tmp/s32_audio_mix_diff_ga | grep -q "PASS: audio mixer differential checks=20012" && \
  echo "AUDIO MIX DIFFERENTIAL (GOLDEN AXE): PASS" || { echo "AUDIO MIX DIFFERENTIAL (GOLDEN AXE): FAIL"; exit 1; }
echo "[30/35] sound map + production JT12 MLAB-shift reset"
iverilog -g2012 -DSIMULATION -o /tmp/s32_soundsys_bus \
  rtl/s32_pkg.sv rtl/video/s32_big_dpram.sv \
  rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv \
  verif/common/jt12_stub.v verif/common/tb_soundsys_bus.sv
vvp /tmp/s32_soundsys_bus | grep -q "SOUNDSYS BUS PASS" && echo "SOUNDSYS BUS: PASS" || { echo "SOUNDSYS BUS: FAIL"; exit 1; }
jt12_sources=$(sed -n 's/.*"\([^"]*\)".*/rtl\/audio\/jt12\/\1/p' rtl/audio/jt12/jt12.qip)
# QIP paths contain no whitespace; intentional splitting supplies one source per argument.
# shellcheck disable=SC2086
iverilog -g2012 -DS32_JT12_MLAB_SHIFTS -s tb_jt12_reset -o /tmp/s32_jt12_reset \
  $jt12_sources verif/common/tb_jt12_reset.sv
vvp /tmp/s32_jt12_reset | grep -q "JT12 RESET PASS" && echo "JT12 MLAB-SHIFT RESET: PASS" || \
  { echo "JT12 MLAB-SHIFT RESET: FAIL"; exit 1; }
unset jt12_sources
echo "[31/35] MAME-backed MultiPCM descriptor / pitch / pan / loop / ACK semantics"
iverilog -g2012 -o /tmp/s32_multipcm \
  rtl/audio/s32_multipcm.sv verif/common/tb_multipcm.sv
vvp /tmp/s32_multipcm | grep -q "MULTIPCM PASS" && echo "MULTIPCM: PASS" || { echo "MULTIPCM: FAIL"; exit 1; }
echo "[32/35] V60 ROT/ROTC carry and active-width semantics"
iverilog -g2012 -o /tmp/s32_v60_rotate \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_rotate.sv
vvp /tmp/s32_v60_rotate | grep -q "V60 ROTATE PASS" && echo "V60 ROTATE: PASS" || { echo "V60 ROTATE: FAIL"; exit 1; }
echo "[33/35] V60 external bus byte/half/dword lane and alignment cycles"
iverilog -g2012 -o /tmp/s32_v60_bus_lanes \
  rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_bus_lanes.sv
vvp /tmp/s32_v60_bus_lanes | grep -q "V60 BUS LANES PASS" && echo "V60 BUS LANES: PASS" || { echo "V60 BUS LANES: FAIL"; exit 1; }
echo "[34/35] System32 palette/mixer/I-O/V25 mirrored address decode"
iverilog -g2012 -DSIMULATION -s tb_core_map_decode -o /tmp/s32_core_map \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/audio/s32_rf5c68.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv rtl/prot/s32_prot.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_map_decode.sv
vvp /tmp/s32_core_map | grep -q "CORE MAP DECODE PASS" && echo "CORE MAP DECODE: PASS" || { echo "CORE MAP DECODE: FAIL"; exit 1; }
echo "[35/35] real encrypted GA2 V25 firmware and exact 10 MHz CE cadence"
bash verif/v25/run_v25_firmware.sh
echo "SYSTEM 32 REGRESSION: PASS (35/35 tiers)"
