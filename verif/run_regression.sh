#!/bin/sh
# System 32 core regression (DESIGN.md §11): grows with each milestone.
set -e
cd "$(dirname "$0")/.."
echo "[1/33] full-core lint compile (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_lint \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint | grep -q "CORE UNIVERSAL LINT PASS" || { echo "CORE UNIVERSAL LINT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_PROFILE_STANDARD -DS32_PCB_TIMING -o /tmp/s32_lint_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_lint.sv
vvp /tmp/s32_lint_s32 | grep -q "CORE STANDARD PROFILE LINT PASS" && echo "CORE BUILD PROFILES: PASS" || { echo "CORE STANDARD LINT: FAIL"; exit 1; }
echo "[2/33] V60 smoke test"
iverilog -g2012 -o /tmp/s32_v60_smoke \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_smoke.sv
vvp /tmp/s32_v60_smoke | grep -q "SMOKE PASS" && echo "V60 SMOKE: PASS" || { echo "V60 SMOKE: FAIL"; exit 1; }
echo "[3/33] V60 directed suite"
iverilog -g2012 -o /tmp/s32_v60_dir \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_directed.sv
vvp /tmp/s32_v60_dir | grep -q "DIRECTED PASS" && echo "V60 DIRECTED: PASS" || { echo "V60 DIRECTED: FAIL"; exit 1; }
echo "[4/33] full-core integration boot (universal + System32-only profile)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_boot \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot | grep -q "CORE BOOT PASS" || { echo "CORE UNIVERSAL BOOT: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -DS32_SYSTEM32_ONLY -DS32_PROFILE_STANDARD -DS32_PCB_TIMING -o /tmp/s32_boot_s32 \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_boot.sv
vvp /tmp/s32_boot_s32 | grep -q "CORE BOOT PASS" && echo "CORE BUILD-PROFILE BOOTS: PASS" || { echo "CORE S32-ONLY BOOT: FAIL"; exit 1; }
echo "[5/33] V60 differential co-sim vs independent reference (50 seeds)"
sh verif/cosim/run_diff.sh 50
echo "[6/33] full-core soak / simulator-tier acceptance (extended multi-frame)"
iverilog -g2012 -DSIMULATION -o /tmp/s32_soak \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_soak.sv
vvp /tmp/s32_soak | grep -q "CORE SOAK PASS" && echo "CORE SOAK: PASS" || { echo "CORE SOAK: FAIL"; exit 1; }
echo "[7/33] V60 audit-fix directed test (string/CALL/RET/RSR — audit.md)"
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
echo "[8/33] framebuffer interface directed test (runs / shadow RMW / erase / read)"
iverilog -g2012 -o /tmp/s32_fbif rtl/mem/s32_fb_if.sv verif/common/tb_fb_if.sv
vvp /tmp/s32_fbif | grep -q "FB IF PASS" && echo "FB IF: PASS" || { echo "FB IF: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -s tb_fb_if_throughput -o /tmp/s32_fbif_throughput \
  rtl/mem/s32_fb_if.sv verif/common/tb_fb_if_throughput.sv
vvp /tmp/s32_fbif_throughput | grep -q "FB THROUGHPUT PASS" && \
  echo "FB THROUGHPUT: PASS" || { echo "FB THROUGHPUT: FAIL"; exit 1; }
echo "[9/33] mixer directed + pixel latency + 512-case independent differential test"
iverilog -g2012 -o /tmp/s32_mix rtl/video/s32_linebuf.sv rtl/video/s32_mixer.sv \
  rtl/video/s32_palette.sv verif/common/tb_mixer.sv
vvp /tmp/s32_mix | grep -q "MIXER PASS" && echo "MIXER: PASS" || { echo "MIXER: FAIL"; exit 1; }
# The mixer must finish a pixel inside one 416-wide pixel period (12 clk_ram
# edges).  At 13 the picture is displayed one column right of MAME in
# 416-wide mode only.
iverilog -g2012 -o /tmp/s32_mixlat rtl/video/s32_linebuf.sv rtl/video/s32_mixer.sv \
  rtl/video/s32_palette.sv verif/common/tb_mixer_pixel_latency.sv
vvp /tmp/s32_mixlat | grep -q "MIXER PIXEL LATENCY PASS" && echo "MIXER PIXEL LATENCY: PASS" || { echo "MIXER PIXEL LATENCY: FAIL"; exit 1; }
python3 -m verif.mixer_diff.generate_vectors /tmp/s32_mixer_vectors.hex --seed 5387 --count 512
iverilog -g2012 -o /tmp/s32_mixdiff rtl/video/s32_mixer.sv verif/mixer_diff/tb_mixer_diff.sv
vvp /tmp/s32_mixdiff +VECTORS=/tmp/s32_mixer_vectors.hex | grep -q "MIXER DIFF PASS cases=512" && echo "MIXER DIFFERENTIAL: PASS (512 cases)" || { echo "MIXER DIFFERENTIAL: FAIL"; exit 1; }
echo "[10/33] sprite pixel-path directed test (pen rules / end codes / flip / zoom / indirect)"
iverilog -g2012 -s tb_sprite -o /tmp/s32_spr rtl/video/s32_sprite.sv verif/common/tb_sprite.sv
vvp /tmp/s32_spr | grep -q "SPRITE PASS" && echo "SPRITE: PASS" || { echo "SPRITE: FAIL"; exit 1; }
iverilog -g2012 -s tb_sprite_fallback -o /tmp/s32_spr_fallback \
  rtl/video/s32_sprite.sv verif/common/tb_sprite.sv \
  verif/common/tb_sprite_fallback.sv
vvp /tmp/s32_spr_fallback | grep -q "SPRITE FALLBACK PASS" && \
  echo "SPRITE FALLBACK: PASS" || { echo "SPRITE FALLBACK: FAIL"; exit 1; }
echo "[11/33] sprite scale divider exactness / fixed-latency test"
iverilog -g2012 -s tb_sprite_div -o /tmp/s32_sprdiv rtl/video/s32_sprite.sv verif/common/tb_sprite_div.sv
vvp /tmp/s32_sprdiv | grep -q "SPRITE DIV PASS" && echo "SPRITE DIV: PASS" || { echo "SPRITE DIV: FAIL"; exit 1; }
echo "[12/33] V60 DIVX/DIVUX iterative 64/32 exactness / latency test"
iverilog -g2012 -o /tmp/s32_v60_divx rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_divx.sv
vvp /tmp/s32_v60_divx | grep -q "DIVX PASS" && echo "V60 DIVX: PASS" || { echo "V60 DIVX: FAIL"; exit 1; }
echo "[13/33] V60 decimal group directed test (ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP)"
iverilog -g2012 -o /tmp/s32_v60dec rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_decimal.sv
vvp /tmp/s32_v60dec | grep -q "DECIMAL PASS" && echo "V60 DECIMAL: PASS" || { echo "V60 DECIMAL: FAIL"; exit 1; }
echo "[14/33] V60 bit string/field directed test (EXTBF/INSBF/SCHBS/MOVBS)"
iverilog -g2012 -o /tmp/s32_v60bits rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_bits.sv
vvp /tmp/s32_v60bits | grep -q "BITS PASS" && echo "V60 BITS: PASS" || { echo "V60 BITS: FAIL"; exit 1; }
echo "[15/33] V60 EA-overlap displacement / high fetch-buffer offset regression"
iverilog -g2012 -o /tmp/s32_v60_ea_overlap \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_ea_overlap_disp.sv
vvp /tmp/s32_v60_ea_overlap | grep -q "V60 EA_OVERLAP DISP PASS" && echo "V60 EA OVERLAP: PASS" || { echo "V60 EA OVERLAP: FAIL"; exit 1; }
echo "[16/33] ROM loader reset / mapping / completion gating"
iverilog -g2012 -o /tmp/s32_rom_loader \
  rtl/s32_pkg.sv rtl/mem/s32_rom_loader.sv verif/common/tb_rom_loader.sv
vvp /tmp/s32_rom_loader | grep -q "ROM LOADER PASS" && echo "ROM LOADER: PASS" || { echo "ROM LOADER: FAIL"; exit 1; }
iverilog -g2012 -s tb_rom_loader_wave_clear -o /tmp/s32_rom_loader_wave_clear \
  rtl/s32_pkg.sv rtl/mem/s32_rom_loader.sv verif/common/tb_rom_loader_wave_clear.sv
vvp /tmp/s32_rom_loader_wave_clear | grep -q "ROM LOADER WAVE CLEAR PASS" && echo "ROM LOADER WAVE CLEAR: PASS" || { echo "ROM LOADER WAVE CLEAR: FAIL"; exit 1; }
echo "[17/33] EEPROM persistence directed test"
iverilog -g2012 -o /tmp/s32_eeprom_nvram \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_eeprom_nvram.sv
vvp /tmp/s32_eeprom_nvram | grep -q "EEPROM NVRAM PASS" && echo "EEPROM NVRAM: PASS" || { echo "EEPROM NVRAM: FAIL"; exit 1; }
echo "[18/33] V60 20-byte F1 / high fetch-buffer offset regression"
iverilog -g2012 -o /tmp/s32_v60_long_ea \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_long_ea.sv
vvp /tmp/s32_v60_long_ea | grep -q "LONG EA PASS" && echo "V60 LONG EA: PASS" || { echo "V60 LONG EA: FAIL"; exit 1; }
echo "[19/33] palette RAM alias / byte-enable / write-both / dual-port timing"
iverilog -g2012 -o /tmp/s32_palette \
  rtl/video/s32_palette.sv verif/common/tb_palette.sv
vvp /tmp/s32_palette | grep -q "PALETTE PASS" && echo "PALETTE: PASS" || { echo "PALETTE: FAIL"; exit 1; }
echo "[20/33] shared tile/bitmap line-buffer latency / layer / parity isolation"
iverilog -g2012 -o /tmp/s32_linebuf \
  rtl/video/s32_linebuf.sv verif/common/tb_linebuf.sv
vvp /tmp/s32_linebuf | grep -q "LINEBUF PASS" && echo "LINEBUF: PASS" || { echo "LINEBUF: FAIL"; exit 1; }
echo "[21/33] tilemap VRAM fetches and deadline-safe scanline scheduling"
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
echo "[22/33] byte-wide true-dual-port BRAM timing / hold / collision semantics"
iverilog -g2012 -s tb_byte_dpram -o /tmp/s32_byte_dpram \
  rtl/video/s32_big_dpram.sv verif/common/tb_byte_dpram.sv
vvp /tmp/s32_byte_dpram | grep -q "BYTE DPRAM PASS" && echo "BYTE DPRAM: PASS" || { echo "BYTE DPRAM: FAIL"; exit 1; }
echo "[23/33] SDRAM CL2 centred input capture / first-word freshness / burst ordering"
iverilog -g2012 -s tb_sdram -o /tmp/s32_sdram \
  rtl/mem/sdram.sv verif/common/tb_sdram.sv
vvp /tmp/s32_sdram | grep -q "SDRAM CAPTURE PASS" && echo "SDRAM CAPTURE: PASS" || { echo "SDRAM CAPTURE: FAIL"; exit 1; }
iverilog -g2012 -DSIMULATION -s tb_sdram_write_mux2 -o /tmp/s32_sdram_write_mux2 \
  rtl/mem/s32_sdram_write_mux2.sv verif/common/tb_sdram_write_mux2.sv
vvp /tmp/s32_sdram_write_mux2 | grep -q "SDRAM WRITE MUX2 PASS" && echo "SDRAM WRITE MUX2: PASS" || { echo "SDRAM WRITE MUX2: FAIL"; exit 1; }
iverilog -g2012 -s tb_sdram_tile_deadline -o /tmp/s32_sdram_tile_deadline \
  rtl/mem/sdram.sv verif/common/tb_sdram_tile_deadline.sv
vvp /tmp/s32_sdram_tile_deadline | grep -q "SDRAM TILE DEADLINE PASS" && echo "SDRAM TILE DEADLINE: PASS" || { echo "SDRAM TILE DEADLINE: FAIL"; exit 1; }
iverilog -g2012 -s tb_sdram_p0_throughput -o /tmp/s32_sdram_p0_throughput \
  rtl/mem/sdram.sv verif/common/tb_sdram_p0_throughput.sv
vvp /tmp/s32_sdram_p0_throughput | grep -q "SDRAM P0 THROUGHPUT PASS" && echo "SDRAM P0 THROUGHPUT: PASS" || { echo "SDRAM P0 THROUGHPUT: FAIL"; exit 1; }
echo "[24/33] integrated sprite renderer / backpressured DDR framebuffer stress"
iverilog -g2012 -s tb_sprite_fb -o /tmp/s32_sprite_fb \
  rtl/video/s32_sprite.sv rtl/mem/s32_fb_if.sv \
  verif/common/tb_sprite_fb.sv
vvp /tmp/s32_sprite_fb | grep -q "SPRITE FB PASS" && echo "SPRITE FB: PASS" || { echo "SPRITE FB: FAIL"; exit 1; }
iverilog -g2012 -s tb_sprite_vblank -o /tmp/s32_sprite_vblank \
  rtl/video/s32_sprite.sv rtl/mem/s32_fb_if.sv \
  verif/common/tb_sprite_vblank.sv
vvp /tmp/s32_sprite_vblank | grep -q "SPRITE VBLANK PASS" && echo "SPRITE VBLANK: PASS" || { echo "SPRITE VBLANK: FAIL"; exit 1; }
echo "[25/33] interrupt controller reset / source+ack collision / timers / doorbell"
iverilog -g2012 -s tb_intc -o /tmp/s32_intc \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_intc.sv
vvp /tmp/s32_intc | grep -q "INTC PASS" && echo "INTC: PASS" || { echo "INTC: FAIL"; exit 1; }
echo "[26/33] audio route arithmetic + generic/Golden Axe differential"
iverilog -g2012 -s tb_audio_mix -o /tmp/s32_audio_mix \
  rtl/audio/s32_audio_mix.sv verif/common/tb_audio_mix.sv
vvp /tmp/s32_audio_mix | grep -q "AUDIO MIX PASS" && echo "AUDIO MIX: PASS" || { echo "AUDIO MIX: FAIL"; exit 1; }
# s32_audio_mix is Multi 32-only now (no S32_SYSTEM32_ONLY arm exists in the
# file), so one compile covers it -- the old GENERIC/GOLDEN AXE split tested
# two identical code paths.
iverilog -g2012 -s tb_audio_mix_diff -o /tmp/s32_audio_mix_diff \
  rtl/audio/s32_audio_mix.sv verif/common/tb_audio_mix_diff.sv
vvp /tmp/s32_audio_mix_diff | grep -q "PASS: audio mixer differential checks=20012" && \
  echo "AUDIO MIX DIFFERENTIAL: PASS" || { echo "AUDIO MIX DIFFERENTIAL: FAIL"; exit 1; }
echo "[27/33] sound map/cache throughput + production JT12 default-storage reset"
iverilog -g2012 -DSIMULATION -o /tmp/s32_soundsys_bus \
  rtl/s32_pkg.sv rtl/video/s32_big_dpram.sv \
  rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv \
  verif/common/jt12_stub.v verif/common/tb_soundsys_bus.sv
vvp /tmp/s32_soundsys_bus | grep -q "SOUNDSYS BUS PASS" && echo "SOUNDSYS BUS: PASS" || { echo "SOUNDSYS BUS: FAIL"; exit 1; }
for cache_sets in 1 4; do
  iverilog -g2012 -DSIMULATION -s tb_soundsys_zrom_cache \
    -P "tb_soundsys_zrom_cache.ZROM_CACHE_SETS=$cache_sets" \
    -o "/tmp/s32_soundsys_zrom_cache_$cache_sets" \
    rtl/s32_pkg.sv rtl/video/s32_big_dpram.sv \
    rtl/audio/s32_multipcm.sv \
    rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv \
    verif/common/jt12_stub.v verif/common/tb_soundsys_zrom_cache.sv
  vvp "/tmp/s32_soundsys_zrom_cache_$cache_sets" | grep -q "SOUNDSYS ZROM CACHE PASS" || {
    echo "SOUNDSYS ZROM CACHE ($cache_sets sets): FAIL"; exit 1;
  }
done
echo "SOUNDSYS ZROM CACHE A/B: PASS"
jt12_sources=$(sed -n 's/.*"\([^"]*\)".*/rtl\/audio\/jt12\/\1/p' rtl/audio/jt12/jt12.qip)
# QIP paths contain no whitespace; intentional splitting supplies one source per argument.
# shellcheck disable=SC2086
iverilog -g2012 -s tb_jt12_reset -o /tmp/s32_jt12_reset \
  $jt12_sources verif/common/tb_jt12_reset.sv
vvp /tmp/s32_jt12_reset | grep -q "JT12 RESET PASS" && echo "JT12 DEFAULT-STORAGE RESET: PASS" || \
  { echo "JT12 DEFAULT-STORAGE RESET: FAIL"; exit 1; }
unset jt12_sources
echo "[28/33] MAME-backed MultiPCM descriptor / pitch / pan / loop / ACK semantics"
iverilog -g2012 -o /tmp/s32_multipcm \
  rtl/audio/s32_multipcm.sv verif/common/tb_multipcm.sv
vvp /tmp/s32_multipcm | grep -q "MULTIPCM PASS" && echo "MULTIPCM: PASS" || { echo "MULTIPCM: FAIL"; exit 1; }
# Fixed 224-ce frame cadence under realistic SDRAM ack latency: the real
# 315-5560 outputs at clk/224 regardless of ROM traffic. The stall-on-fetch
# scheduler this replaces stretched the frame to 175% under load and played
# hardware music slow and warbling.
iverilog -g2012 -o /tmp/s32_mpcm_cad   rtl/audio/s32_multipcm.sv verif/common/tb_multipcm_cadence.sv
vvp /tmp/s32_mpcm_cad +ACK=30 +VOICES=28 | grep -q "MULTIPCM CADENCE PASS"   && vvp /tmp/s32_mpcm_cad +ACK=20 +VOICES=8 | grep -q "MULTIPCM CADENCE PASS"   && echo "MULTIPCM CADENCE: PASS" || { echo "MULTIPCM CADENCE: FAIL"; exit 1; }
# OutRunners engine voice: MAME-captured key-on ordering (r4 KEY ON before
# the r1 sample select), continuous pitch/TL/LFO updates, and depth-1
# tremolo (r7=01). The engine is the only voice with tremolo enabled, and
# the amp-LFO index slice bug ([6:0] instead of [14:8]) attenuated exactly
# this voice by -35..-48 dB oscillating -- car engine inaudible on hardware
# while music/tires/announcer (lfo_amp=0 descriptors) stayed correct.
iverilog -g2012 -o /tmp/s32_mpcm_engv rtl/audio/s32_multipcm.sv verif/common/tb_multipcm_engine_voice.sv
vvp /tmp/s32_mpcm_engv +ACK=30 | grep -q "ENGINE PASS"   && vvp /tmp/s32_mpcm_engv +ACK=100 | grep -q "ENGINE PASS"   && echo "MULTIPCM ENGINE VOICE: PASS" || { echo "MULTIPCM ENGINE VOICE: FAIL"; exit 1; }
echo "[29/33] V60 ROT/ROTC carry and active-width semantics"
iverilog -g2012 -o /tmp/s32_v60_rotate \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_rotate.sv
vvp /tmp/s32_v60_rotate | grep -q "V60 ROTATE PASS" && echo "V60 ROTATE: PASS" || { echo "V60 ROTATE: FAIL"; exit 1; }
echo "[30/33] V60 external bus byte/half/dword lane and alignment cycles"
iverilog -g2012 -o /tmp/s32_v60_bus_lanes \
  rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_bus_lanes.sv
vvp /tmp/s32_v60_bus_lanes | grep -q "V60 BUS LANES PASS" && echo "V60 BUS LANES: PASS" || { echo "V60 BUS LANES: FAIL"; exit 1; }
cadence_flags="-DS32_SYSTEM32_ONLY -DS32_PROFILE_STANDARD -DS32_UNIVERSAL -DS32_V25_HW -DS32_GAME_ONLY_STD -DS32_PCB_TIMING"
# shellcheck disable=SC2086 -- cadence_flags intentionally expands to defines
iverilog -g2012 -DSIMULATION $cadence_flags -s tb_v60_exec_cadence \
  -o /tmp/s32_v60_exec_cadence_universal \
  rtl/s32_pkg.sv rtl/s32_core.sv verif/common/tb_v60_exec_cadence.sv
vvp /tmp/s32_v60_exec_cadence_universal | grep -q "V60 EXEC CADENCE PASS" || {
  echo "V60 EXEC CADENCE (universal): FAIL"; exit 1;
}
echo "V60 EXEC CADENCE (universal): PASS"
iverilog -g2012 -s tb_v60_exec_retire -o /tmp/s32_v60_exec_retire \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  verif/common/tb_v60_exec_retire.sv
vvp /tmp/s32_v60_exec_retire | grep -q "V60 EXEC RETIRE PASS" && \
  echo "V60 EXEC RETIRE: PASS" || { echo "V60 EXEC RETIRE: FAIL"; exit 1; }
echo "[31/33] System32 palette/mixer/I-O mirrored address decode"
iverilog -g2012 -DSIMULATION -s tb_core_map_decode -o /tmp/s32_core_map \
  rtl/s32_pkg.sv rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv \
  rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/s32_multipcm.sv \
  rtl/audio/s32_audio_mix.sv rtl/audio/s32_soundsys.sv rtl/io/s32_io.sv \
  verif/common/jt12_stub.v rtl/s32_core.sv verif/common/tb_core_map_decode.sv
vvp /tmp/s32_core_map | grep -q "CORE MAP DECODE PASS" && echo "CORE MAP DECODE: PASS" || { echo "CORE MAP DECODE: FAIL"; exit 1; }
echo "[32/33] direct positional wheel, right-stick pedals, and digital fallbacks"
iverilog -g2012 -s tb_driving_controls -o /tmp/s32_driving_controls \
  rtl/io/s32_driving_controls.sv verif/common/tb_driving_controls.sv
vvp /tmp/s32_driving_controls | grep -q "PASS: System 32 driving controls" && \
  echo "SLIP STREAM DRIVING CONTROLS: PASS" || { echo "SLIP STREAM DRIVING CONTROLS: FAIL"; exit 1; }
echo "[33/33] MAME-backed Rad Mobile MSM6253 channel and MSB-first read semantics"
iverilog -g2012 -s tb_radm_msm6253 -o /tmp/s32_radm_msm6253 \
  rtl/s32_pkg.sv rtl/io/s32_io.sv verif/common/tb_radm_msm6253.sv
vvp /tmp/s32_radm_msm6253 | grep -q "RAD MOBILE MSM6253 PASS" && \
  echo "RAD MOBILE MSM6253: PASS" || { echo "RAD MOBILE MSM6253: FAIL"; exit 1; }
echo "SYSTEM 32 REGRESSION: PASS (33/33 tiers)"
