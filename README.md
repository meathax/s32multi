# SEGA SYSTEM MULTI 32: Four fully supported games for MiSTer FPGA

MiSTer FPGA core for SEGA's System Multi 32 board family
(837-8676 / 171-6253C). This is one universal production image for four fully
supported games: OutRunners, Title Fight, Hard Dunk, and Stadium Cross. It
targets the DE10-Nano with SDRAM and uses the descriptor-selected
`Arcade-SegaSystem32Multi.rbf`; the MRAs select each supported ROM set without
creating per-game Quartus images.

The universal profile contains the common dual-screen Multi 32 video path, two
315-5296 cockpit I/O lanes, the 837-7536 analog board, the Hard Dunk mode-0
8255 expansion, and the 315-5560 MultiPCM path. All four games have their
cabinet-specific controls, video, audio, ROM routing, and MRA descriptors
implemented in this profile. Stadium Cross link mode (`scrossa`) is
intentionally not emitted; the supported Stadium Cross sets are the normal
non-link cabinets. Other System 32, Multi 32, and AS-1 games are not exposed.
Commercial ROMs are not included.

## Features in the OSD

- Original 4:3 or full-screen aspect ratio
- Normal, vertical-integer, or full-integer scaling
- Optional CRT 25%, 50%, and 75% scandoubler effects
- Multi 32 screen A/B selection and an optional side-by-side split-screen
  gameplay view; split-screen keeps the standard MiSTer aspect, scaling,
  scandoubler, direct-video, HDMI, sync, and blanking paths
- Persistent 128-byte 93C46 high-score/settings storage
- Service mode and reset, with independent Test/Service controls for each
  cockpit
- Descriptor-selected controls for each fully supported cabinet:
  - OutRunners: shift up/down, DJ/music, track previous/next, accelerator,
    brake, start, coin, test, and service
  - Title Fight: P1/P2 left-hand sticks on the left analog sticks or D-pad
    directions; right-hand sticks on the right analog sticks or named Right
    Stick Left/Right/Up/Down buttons; start, coin, test, and service
  - Hard Dunk: six independent digital or left-analog movement controls for
    the 3-vs-3 cabinet, with Pass / Steal, Shoot / Block, and Special Move /
    Turbo / Screen Toggle, plus player starts, coin, test, and service
  - Stadium Cross: P1/P2 left-analog X steering with D-pad left/right fallback;
    right-analog Y accelerator/brake, left-analog Y handlebar pitch (up pushes
    forward, down pulls back), D-pad up/down pitch fallback, Attack, Wheelie,
    Brake, Accelerate, Handlebar Forward, Handlebar Back, start, coin, test,
    and service
- Independent P1/P2 steering from signed analog wheel/stick coordinates,
  absolute paddle devices, or relative spinners, including reversible spinner
  direction
- Accelerator and brake inputs from analog axes or dedicated digital fallbacks

## PCB Accuracy

This table lists only shared custom-chip roles supported by the available
schematic or silicon evidence. It is not a blanket board-level or
cycle-accuracy claim for every supported title. Open timing, analogue, PLD,
protection, and link-board questions remain outside this release's verified scope.

| Area | Evidence | Core implementation |
| --- | --- | --- |
| Scroll hardware | Sega schematics, sheet 2; Sega 315-5387 | Four tilemap layers and dual-port VRAM in [`s32_tilemap.sv`](rtl/video/s32_tilemap.sv) |
| Objects/frame memory | Sega schematics, sheets 3-4; Sega 315-5386 | Object processing and buffered framebuffer in [`s32_sprite.sv`](rtl/video/s32_sprite.sv) and [`s32_fb_if.sv`](rtl/mem/s32_fb_if.sv) |
| Colour/video output | Sega schematics, sheet 5; [315-5242 silicon evidence](https://github.com/furrtek/SiliconRE/tree/master/Sega/315-5242) | Palette, priority, shadow/highlight, and RGB output in [`s32_mixer.sv`](rtl/video/s32_mixer.sv) and [`s32_palette.sv`](rtl/video/s32_palette.sv) |
| I/O and EEPROM | Sega schematics, sheet 6 | 315-5296 I/O and BR93C46 serial storage in [`s32_io.sv`](rtl/io/s32_io.sv) |


## Supported games

The following four SEGA System Multi 32 games are fully supported. Every listed
variant uses the same production RBF and its curated MRA descriptor:

- **OutRunners (World):** MAME set `orunners`
- **OutRunners (US):** MAME set `orunnersu`, parent `orunners`
- **OutRunners (Japan):** MAME set `orunnersj`, parent `orunners`
- **Title Fight (World):** MAME set `titlef`
- **Title Fight (US):** MAME set `titlefu`, parent `titlef`
- **Title Fight (Japan):** MAME set `titlefj`, parent `titlef`
- **Hard Dunk (World):** MAME set `harddunk`
- **Hard Dunk (Japan):** MAME set `harddunkj`, parent `harddunk`
- **Stadium Cross (World):** MAME set `scross`
- **Stadium Cross (US):** MAME set `scrossu`, parent `scross`

The linkable Stadium Cross clone (`scrossa`) and all other System 32, Multi 32,
or AS-1 sets are not distributed or supported by this production profile.

## **Hardware emulated**

| Chip or subsystem | Interface | Implementation / reference |
| --- | --- | --- |
| NEC V70-compatible CPU path | 20 MHz Multi 32 bus-rate CE, 16-bit adapter / 24-bit address space | [`s32_v60.sv`](rtl/cpu/v60/s32_v60.sv), [`s32_v60_bus.sv`](rtl/cpu/v60/s32_v60_bus.sv) |
| Dual Sega 315-5296 I/O | Two JAMMA-edge lanes, buttons, service, coin, timers | [`s32_io.sv`](rtl/io/s32_io.sv), [`Arcade-SegaSystem32Multi.sv`](Arcade-SegaSystem32Multi.sv) |
| 315-5386 / 315-5387 video engines | Objects, four tilemap layers, VRAM, and buffered dual-screen frame memory | [`s32_sprite.sv`](rtl/video/s32_sprite.sv), [`s32_tilemap.sv`](rtl/video/s32_tilemap.sv), [`s32_fb_if.sv`](rtl/mem/s32_fb_if.sv) |
| Dual 315-5388 / 315-5242 video output | Two palettes, priority, shadow/highlight, RGB, and A/B composition | [`s32_mixer.sv`](rtl/video/s32_mixer.sv), [`s32_palette.sv`](rtl/video/s32_palette.sv), [`s32_splitscreen_composer.sv`](rtl/video/s32_splitscreen_composer.sv) |
| BR93C46 EEPROM | Serial NVRAM and MiSTer upload/download | [`s32_io.sv`](rtl/io/s32_io.sv) |
| 837-7536 / OKI M6253 A/D board | Four-channel ADC for title-selected P1/P2 steering, accelerator, and brake channels | [`s32_driving_controls.sv`](rtl/io/s32_driving_controls.sv), [`s32_io.sv`](rtl/io/s32_io.sv) |
| Multi 32 8255A expansion | Descriptor-gated mode-0 PPI for Hard Dunk's players 3/6 and control latches | [`s32_io.sv`](rtl/io/s32_io.sv), [`Arcade-SegaSystem32Multi.sv`](Arcade-SegaSystem32Multi.sv) |
| Z80 sound CPU | 8 MHz Multi 32 sound domain | [`s32_soundsys.sv`](rtl/audio/s32_soundsys.sv), vendored [`T80`](rtl/audio/T80/) |
| YM3438 | One FM sound device at the Multi 32 sound rate | [`JT12`](rtl/audio/jt12/), [`s32_soundsys.sv`](rtl/audio/s32_soundsys.sv) |
| Sega 315-5560 MultiPCM | 10 MHz sample engine, 28 voices, SDRAM sample ROM | [`s32_multipcm.sv`](rtl/audio/s32_multipcm.sv) |
| MiSTer memory services | HPS download, SDRAM ROMs, DDR3 framebuffers | [`Arcade-SegaSystem32Multi.sv`](Arcade-SegaSystem32Multi.sv), [`sys/`](sys/) |

## Credits

- **Meathax** - System Multi 32 RTL, descriptor routing, MRA generation,
  verification, and packaging for the supported Multi 32 titles.
- **Sega, Nemesis1207, and System 32 researchers** - original hardware and
  public schematic material.
- **MAME developers** - [System 32/Multi 32 behavioural reference](https://github.com/mamedev/mame).
- **Jose Tejada Gomez / Jotego** - [JT12](https://github.com/jotego/jt12)
  and audited [JTCORES](https://github.com/jotego/jtcores/tree/c990f843c7bd8eaf26179a0632bac1436cc05b52)
  reference work.
- **Daniel Wallner, MikeJ, Mike Johnson, TobiFlex, Sean Riddle, and Sorgelig**
  - the vendored T80 Z80 core.
- **furrtek / SiliconRE** - Sega 315-5242 and 315-5385 silicon research.
- **Umberto Parisi (rmonic79) and Andrea Bogazzi (@asturur)** -
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust/tree/c682de9f4acc61d8f4c7779efb48149d3baa3a8e).
- **MiSTer-devel and reference-core authors** - MiSTer framework, MRA tooling,
  and integration references.
- Intel Quartus, Verilator, Icarus Verilog, ModelSim, and MAME tool authors.

## License

Original core source is licensed under [GNU GPLv3](LICENSE). Vendored
components retain their own terms and notices:

- JT12: GPLv3 ([LICENSE](rtl/audio/jt12/LICENSE))
- T80: BSD-style terms in [`rtl/audio/T80/`](rtl/audio/T80/)
- SiliconRE material retains its original licence terms
- MiSTer framework and Intel/Altera IP: retained upstream/vendor notices

Linked reference projects and arcade ROMs remain under their respective terms.

## How to install

Copy `Arcade-SegaSystem32Multi.rbf` and the MRA files to `/media/fat/_Arcade/`.
Place the required MAME ROM ZIPs in `/media/fat/games/mame/`, then launch a
game from the MiSTer Arcade menu.

For automatic installation, add this to `/media/fat/downloader.ini` and run
**Update All**:

```ini
[meathax/meatcores]
db_url = https://raw.githubusercontent.com/meathax/meatcores/db/db.json.zip
```

## Development

Quartus Prime 17.0.2 Build 602 is the pinned toolchain. Open
`Arcade-SegaSystem32Multi.qpf` and compile the
`Arcade-SegaSystem32Multi` revision.
