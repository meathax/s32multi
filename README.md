# Sega System 32 for MiSTer FPGA

MiSTer FPGA core for Sega's standard single-screen System 32 arcade board
(837-7428 / 171-5964E). It targets the DE10-Nano with SDRAM and uses one
universal `Arcade-SegaSystem32.rbf`; each MRA selects the required game
hardware, including the real NEC V25 path for Arabian Fight and Golden Axe II.

Commercial ROMs are not included. Multi 32 and AS-1 hardware are not supported.

## Features in the OSD

- Original 4:3 or full-screen aspect ratio
- Normal, vertical-integer, or full-integer scaling
- Optional CRT 25%, 50%, and 75% scandoubler effects
- CRT horizontal size/position and vertical-shift controls for 15 kHz output
- Persistent 128-byte 93C46 high-score/settings storage
- Service mode and reset, with independent Test/Service controls for each
  Multi 32 screen
- Per-game remappable controls defined by each MRA
- Alien3: The Gun and Jurassic Park positional-gun inputs through the generic
  MiSTer/JTFRAME-compatible analog, USB-relative-mouse, and d-pad paths;
  Jurassic Park additionally supports GunCon 2 over SNAC

## PCB Accuracy

This table lists only areas supported by schematics or silicon evidence. It
defines the implemented hardware boundary, not a blanket cycle-accuracy claim.
Open timing, analogue, PLD, and protection questions are tracked in the
[PCB evidence ledger](docs/pcb/system32_evidence.json).

| Area | Evidence | Core implementation |
| --- | --- | --- |
| Board and clocks | Sega schematics 171-5964D / 171-5965C | Standard single-screen board; V60, Z80/YM3438, and PCM domains |
| Main CPU/controller | Schematics, sheet 1 | 16-bit V60 bus, interrupts, timers, and system control |
| Scroll hardware | Schematics, sheet 2; Sega 315-5387 | Four tilemap layers and dual-port VRAM |
| Objects/frame memory | Schematics, sheets 3-4; Sega 315-5386 | Object processing and double-buffered framebuffer |
| Colour/video output | Schematics, sheet 5; [315-5242 silicon evidence](https://github.com/furrtek/SiliconRE/tree/master/Sega/315-5242) | Palette, priority, shadow/highlight, and RGB output |
| I/O, EEPROM, and sound | Schematics, sheets 6-8 | 315-5296 I/O, 93C46 storage, Z80, dual YM3438, and PCM |

See [hardware references](docs/references.md) for the schematic provenance and
detailed source record.

## Supported games

The 32 tracked MRA variants use the same universal RBF:

- **Arabian Fight:** World, US, Japan
- **Burning Rival:** World, Japan
- **Dark Edge:** World, Japan
- **Golden Axe: The Revenge of Death Adder:** World Rev B, US Rev A, Japan
- **Holosseum:** US Rev A
- **Alien3: The Gun:** World, US Rev A, Japan
- **Jurassic Park:** World Rev A, Japan Rev A Deluxe, Japan Deluxe, Japan Rev A Conversion
- **Rad Mobile:** World, US
- **Rad Rally:** World, US, Japan
- **Slip Stream:** Brazil, Hispanic
- **Spider-Man: The Videogame:** World, US Rev A, Japan
- **Super Visual Football / Soccer:** European Rev A, US Rev A
- **The J.League 1994:** Japan, Japan Rev A

SegaSonic The Hedgehog, Hard Dunk, OutRunners, Stadium Cross, Title Fight, AS-1,
and other Multi 32 games remain outside the production profile. Alien3 retains
its special SERVICE12 coin wiring; Jurassic Park keeps its one-button Shoot
assignment and MRA compatibility patch. Neither game uses the retired
framebuffer/HUD blending workaround.

## **Hardware emulated**

| Chip or subsystem | Interface | Implementation / reference |
| --- | --- | --- |
| NEC µPD70616 V60 | ~16.108 MHz, 16-bit data / 24-bit address bus | [`s32_v60.sv`](rtl/cpu/v60/s32_v60.sv), [`s32_v60_bus.sv`](rtl/cpu/v60/s32_v60_bus.sv) |
| Sega 315-5385 controller | V60 registers, IRQs, timers | [`s32_io.sv`](rtl/io/s32_io.sv); schematics and MAME behaviour |
| Sega 315-5386 objects | Object RAM and framebuffer | [`s32_sprite.sv`](rtl/video/s32_sprite.sv); schematic sheets 3-4 |
| Sega 315-5387 scroll | Tilemap VRAM and registers | [`s32_tilemap.sv`](rtl/video/s32_tilemap.sv); schematic sheet 2 |
| Sega 315-5388 / 315-5242 video | Palette, priority, RGB | [`s32_mixer.sv`](rtl/video/s32_mixer.sv); schematic and silicon evidence |
| Sega 315-5296 I/O | JAMMA, DIP, service, coin | [`s32_io.sv`](rtl/io/s32_io.sv); schematic sheet 6 |
| BR93C46 EEPROM | Serial NVRAM | `s32_io.sv`; MiSTer NVRAM upload/download |
| MSM6253 ADC / 8255 PPI | Driving and parallel I/O, including Burning Rival's two-player six-button map | Descriptor-selected interfaces in `s32_io.sv`, `Arcade-SegaSystem32.sv`, and `s32_prot.sv` |
| Generic MiSTer/JTFRAME positional-gun input | Signed analog reports, PS/2 mouse packets, d-pad events, native raster overlay | [`s32_lightgun.sv`](rtl/io/s32_lightgun.sv) and [`s32_lightgun_overlay.sv`](rtl/video/s32_lightgun_overlay.sv); descriptor-selected ADC channels and core-side Sinden border/crosshair controls |
| Jurassic Park GunCon 2 | SNAC serial pins, normalized optical coordinates and buttons | [`s32_guncon_snac.sv`](rtl/io/s32_guncon_snac.sv); descriptor-gated Jurassic-only override |
| NEC V25 protection | Program/cache and mailbox RAM | [`s32_v25_cpu.sv`](rtl/cpu/v25/s32_v25_cpu.sv); [s80x86 provenance](rtl/cpu/v25/s80x86/README.system32.md) |
| Z80 sound CPU | ~8.054 MHz | [`s32_soundsys.sv`](rtl/audio/s32_soundsys.sv); vendored [`T80`](rtl/audio/T80/) |
| 2 × YM3438 | Z80 register bus | [`JT12`](rtl/audio/jt12/) |
| RF5C68-family PCM | ~12.5 MHz, wave RAM | [`s32_rf5c68.sv`](rtl/audio/s32_rf5c68.sv) |
| MiSTer memory services | HPS download, SDRAM, DDR3 | [`Arcade-SegaSystem32.sv`](Arcade-SegaSystem32.sv), [`sys/`](sys/) |

## Credits

- **Meathax** - System 32 RTL, integration, MRA generation, verification, and packaging.
- **Sega, Nemesis1207, and System 32 researchers** - original hardware and
  public schematic material recorded in [the source ledger](docs/references.md).
- **MAME developers** - [System 32 behavioural reference](https://github.com/mamedev/mame).
- **Jamie Iles** - [s80x86](https://github.com/jamieiles/80x86), used by the
  V25 wrapper; pin and licence details are retained with the source.
- **Jose Tejada Gomez / Jotego** - [JT12](https://github.com/jotego/jt12),
  [JT8255](https://github.com/jotego/jt8255/tree/3bb5f7ea461fc7d72b847ec55ce997e5d5bc1754),
  and audited [JTCORES](https://github.com/jotego/jtcores/tree/c990f843c7bd8eaf26179a0632bac1436cc05b52)
  reference work, including the generic lightgun input/video contract used by
  the project-owned adapter.
- **jlrh** - [taito-fpga](https://github.com/jlrh/taito-fpga/tree/405a68eac741918e627cda563cc1a0c219ed18fd)
  Operation Wolf lightgun integration, inspected for the core-side
  `gun_1p_x/gun_1p_y` contract; no upstream RTL was copied.
- **Daniel Wallner, MikeJ, Mike Johnson, TobiFlex, Sean Riddle, and Sorgelig**
  - the vendored T80 Z80 core.
- **furrtek / SiliconRE** - Sega 315-5242 and 315-5385 silicon research.
- **Umberto Parisi (rmonic79) and Andrea Bogazzi (@asturur)** -
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust/tree/c682de9f4acc61d8f4c7779efb48149d3baa3a8e).
- **misteraddons / SYSTEM11_MiSTer** - GunCon-only PSX/SNAC transport reference
  ([pinned commit c2f2374](https://github.com/misteraddons/SYSTEM11_MiSTer/commit/c2f2374386c28923d98588d25d509ea075ef9746)); GPL-2.0-or-later source
  attribution is retained in [`s32_guncon_snac.sv`](rtl/io/s32_guncon_snac.sv).
- **MiSTer-devel and reference-core authors** - MiSTer framework, MRA tooling,
  and the audited S32X, Irem M92, WonderSwan, and MegaCD integration references
  listed in [reference-cores.md](docs/reference-cores.md).
- Intel Quartus, Verilator, Icarus Verilog, ModelSim, and MAME tool authors.

## License

Original core source is licensed under [GNU GPLv3](LICENSE). Vendored
components retain their own terms and notices:

- s80x86: GPLv3 or later ([COPYING](rtl/cpu/v25/s80x86/COPYING))
- JT12: GPLv3 ([LICENSE](rtl/audio/jt12/LICENSE))
- JT8255 conformance reference: MIT ([LICENSE](verif/donors/LICENSE.jt8255))
- T80: BSD-style terms in [`rtl/audio/T80/`](rtl/audio/T80/)
- JTFRAME/jlrh lightgun references: GPL-3.0-or-later upstream projects;
  only interface semantics were adapted into the project-owned
  [`s32_lightgun.sv`](rtl/io/s32_lightgun.sv) and
  [`s32_lightgun_overlay.sv`](rtl/video/s32_lightgun_overlay.sv), with pinned
  provenance in [`verif/donors/README.md`](verif/donors/README.md)
- GunCon SNAC transport reference: GPL-2.0-or-later; pinned source and notice in [`rtl/io/s32_guncon_snac.sv`](rtl/io/s32_guncon_snac.sv)
- SiliconRE material: [SiliconRE licence](docs/references/siliconre/315-5385/SiliconRE-LICENSE)
- MiSTer framework and Intel/Altera IP: retained upstream/vendor notices

Linked reference projects and arcade ROMs remain under their respective terms.

## How to install

Copy `Arcade-SegaSystem32.rbf` and the MRA files to `/media/fat/_Arcade/`.
Place the required MAME ROM ZIPs in `/media/fat/games/mame/`, then launch a
game from the MiSTer Arcade menu.

For automatic installation, add this to `/media/fat/downloader.ini` and run
**Update All**:

```ini
[meathax/meatcores]
db_url = https://raw.githubusercontent.com/meathax/meatcores/db/downloader_meathax_meatcores.zip
```

## Development

Quartus Prime 17.0.2 Build 602 is the pinned toolchain. Build the universal
profile with `tools/build-segas32.bat`. See [PROFILE_CONTRACT.md](PROFILE_CONTRACT.md)
for profile rules and verification commands.
