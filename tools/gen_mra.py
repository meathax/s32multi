#!/usr/bin/env python3
"""
MRA generator for the descriptor-selected Sega System Multi 32 MiSTer core.

The production image is the shared 837-8676 / 171-6253C Multi 32 profile.
Each supported parent emits a descriptor byte selecting its small I/O/audio
conventions; clones are derived automatically from the MAME GAME macro's
parent field.

Parses MAME's segas32.cpp (ROM_START blocks + GAME macros) and emits one
.mra per supported set using independent download regions:

  index 0: 64-byte board descriptor (emitted last as the boot commit)
  indexes 4..9: maincpu, soundcpu, tiles, multipcm, mcu, sprites
  index 2: eeprom default image (128B), when the set provides one

Only regions present in the MAME set are transferred, eliminating fixed-slot
padding while retaining a backward-compatible legacy index-0 RTL path.
Region padding/interleave is derived from the ROM_LOAD macros:
  ROM_LOAD                → linear
  ROM_LOAD16_BYTE         → interleave 2, map 01/10
  ROM_LOAD32_WORD         → interleave 4, two words
  ROM_LOAD32_BYTE         → interleave 4, map per offset&3
  ROM_LOAD_x2/_x4         → repeat each byte group (handled as repeats)
  ROM_LOAD16_WORD         → linear 16-bit

Usage: gen_mra.py <path-to-segas32.cpp> <outdir>
"""

import re, sys, os, textwrap
from html import escape

REGION_SIZES = {
    "maincpu":  0x200000,
    "soundcpu": 0x400000,
    "tiles":    0x400000,
    "sega":     0x400000,   # multipcm
    "mcu":      0x010000,
    "sprites":  0x1000000,
}
STREAM_ORDER = ["maincpu", "soundcpu", "tiles", "sega", "mcu", "sprites"]
REGION_INDEX = dict(zip(STREAM_ORDER, range(4, 10)))

# board descriptor per parent (DESIGN.md §3.4):
#   b0: flags {multi32,v25,v25table,adc,reserved,ppi,motor_hle}
#       multi32 is set for all production parents; game_profile is encoded in
#       byte 4 bits 4:2 so the universal RBF can select title conventions.
#   b1: bit0=dual_pcb, bit1=vertical orientation flip, bit2=positional gun,
#       bit3=Alien3 SERVICE12 coin layout, bits5:4=analog profile;
#       bit6=dual-PCB comm RAM reset-to-FF
#   b2: bits6:0=prot_sel; bit7=descriptor-selected EPR-14084 link HLE
#   b3: bit7=physical sprite-bank metadata valid; bits1:0=bank mask
ANALOG = dict(CENTERED=0, DRIVING=1, ALL_FF=2)
DIGITAL = dict(GENERIC=0, RADM=1)
def desc(multi32=0, v25=0, v25table=0, adc=0, ppi=0,
         dual=0, flip_y=0, gun=0, coin_swap=0, prot=0, analog=0, dual_ff=0,
         comm_hle=0, gear_toggle=0, digital=0, motor_hle=0, game=0):
    b0 = (multi32 | v25 << 1 | v25table << 2 | adc << 3 |
          ppi << 5 | motor_hle << 6)
    b1 = (dual | (flip_y << 1) | (gun << 2) | (coin_swap << 3) |
          (analog << 4) |
          (dual_ff << 6) | (gear_toggle << 7))
    b2 = prot | (comm_hle << 7)
    # Byte 3 is populated from the physical sprite region by gen(); byte 4
    # carries the semantic player-port layout and title profile selector.
    d = bytes([b0, b1, b2, 0, digital | (game << 2)]) + bytes(59)
    return d

GAMES = {
    # parent: (descriptor, per-set list built from clones automatically)
    # OutRunners is a Sega System Multi 32 board (837-8676 / 171-6253C): NEC
    # V70 at 20 MHz, two 315-5388/5242/5296 video+I/O sets driving two JAMMA
    # edges, one YM3438 and one 315-5560 MultiPCM, and the 837-7536 A/D board.
    # This repository targets that board, so multi32 is set here and the RTL
    # no longer folds it to a constant.
    #
    # The analog board is an OKI M6253 -- a *four*-channel ADC -- plus a
    # 74HC4053 bank mux, not an eight-channel converter.  MAME wires ADC
    # channels 0 and 1 straight to ANALOG1/ANALOG2 and takes only channels 2
    # and 3 through the bank (segas32.cpp in2_analog_read/in3_analog_read), so
    # the six OutRunners axes are reached as:
    #
    #   ch0 = P1 steering   ch1 = P1 accel
    #   ch2 = bank0 P1 brake  / bank1 P2 accel
    #   ch3 = bank0 P2 steer  / bank1 P2 brake
    #
    # There is no gear_toggle: OutRunners has discrete shift-up/shift-down
    # buttons on P1_A/P1_B bits 0-1, not the latched single-input toggle Rad
    # Rally and Slip Stream use.
    "orunners": desc(multi32=1, adc=1, analog=ANALOG["DRIVING"]),
    # Title Fight uses both sticks as independent left/right joysticks and
    # has no ADC/PPI expansion board.
    "titlef": desc(multi32=1, analog=ANALOG["CENTERED"], game=1),
    # Hard Dunk is the six-player Multi 32 board.  Its i8255 is mode-0 input
    # only in the MAME driver; PPI/extra-player routing is selected in RTL.
    "harddunk": desc(multi32=1, ppi=1, game=2),
    # Stadium Cross normal and US sets use the analog Multi 32 board.  The
    # linkable clone (scrossa) is intentionally excluded below: this core
    # implements the non-link cabinet path only.
    "scross": desc(multi32=1, adc=1, analog=ANALOG["DRIVING"], game=3),
}

# No supported parent/set is excluded from the generator.  Clones inherit the
# descriptor from their parent unless a set-specific entry is added above.
IGNORED_PARENTS = set()
IGNORED_SETS = {"scrossa"}

# Per-game button labels/defaults are part of the MRA contract, not the board
# descriptor. Keep them here so regenerating tracked MRAs preserves the
# remapping UI metadata as well as the ROM stream.
BUTTONS = {
    # OutRunners drives its pedals and wheel through the A/D board, so the
    # digital buttons are the shifter, the in-car music selector, and two
    # dedicated digital pedal fallbacks: BUTTON1/2 = shift up/down,
    # BUTTON3 = DJ/music, BUTTON4/5 = track skip back/forward (segas32.cpp
    # INPUT_PORTS_START(orunners)), BUTTON6/7 = assignable digital
    # Accelerate/Brake feeding the MSM6253 pedal channels (previously
    # aliased onto the shifter buttons, so shifting also floored a pedal).
    "orunners": (
        "Shift Up,Shift Down,DJ/Music,Music Prev,Music Next,Accelerate,Brake,"
        "Start,Coin,Test,Service",
        "A,B,X,Y,R,-,-,Start,Select,R,L",
    ),
    "titlef": (
        "Right Stick Left,Right Stick Right,Right Stick Up,Right Stick Down,-,-,-,Start,Coin,Test,Service",
        "A,B,X,Y,Start,Select,R,L",
    ),
    "harddunk": (
        "Pass / Steal,Shoot / Dunk / Block,-,-,-,-,-,Start,Coin,Test,Service",
        "A,B,Start,Select,R,L",
    ),
    "scross": (
        "Attack,Wheelie,Brake,Accelerate,Handlebar Forward,Handlebar Back,-,Start,Coin,Test,Service",
        "A,B,X,Y,L,R,Start,Select,R,L",
    ),
}

BUTTON_COUNTS = {
    "orunners": 7,
    "titlef": 4,
    "harddunk": 2,
    "scross": 6,
}

# Descriptive joystick metadata is shown by MiSTer front ends; the actual
# axis/button wiring is implemented in Arcade-SegaSystem32Multi.sv.
JOYSTICKS = {
    "titlef": "Dual analog sticks (left hand / right hand)",
    "harddunk": "Six digital joysticks (3 vs 3)",
    "scross": "Left-stick steering / Y-axis handlebar pitch / D-pad pitch fallback",
}
# Every supported parent uses the one universal production image.
RBF_BY_PARENT = {
    "orunners": "Arcade-SegaSystem32Multi",
    "titlef": "Arcade-SegaSystem32Multi",
    "harddunk": "Arcade-SegaSystem32Multi",
    "scross": "Arcade-SegaSystem32Multi",
}

UNSUPPORTED = set()

def parse(src):
    """Return {setname: {'regions': [(region, size, loads)], 'title', 'parent'}}"""
    sets = {}
    # ROM_START blocks
    for m in re.finditer(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", src, re.S):
        name, body = m.group(1), m.group(2)
        regions = []
        cur = None
        for line in body.splitlines():
            rm = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([\w:]+)"', line)
            if rm:
                # strip the mainpcb: prefix; keep other prefixes (subpcb:) as
                # distinct names so their loads never leak into the previous
                # region (they are intentionally not part of the stream — the
                # dual-PCB sub board is an HLE responder in the RTL)
                rname = rm.group(2)
                rname = rname[8:] if rname.startswith("mainpcb:") else rname.replace(":", "_")
                cur = {"region": rname, "size": int(rm.group(1), 16), "loads": []}
                regions.append(cur)
                continue
            lm = re.search(
                r'(ROM_LOAD(?:16_BYTE(?:_x2|_x4)?|16_WORD|32_WORD(?:_x2|_x4)?|32_BYTE|64_BYTE|64_WORD|_x2|_x4|_x8|_x16)?)\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)\s*SHA1\(([0-9a-fA-F]+)\)',
                line)
            if lm and cur is not None:
                cur["loads"].append(dict(
                    macro=lm.group(1), file=lm.group(2),
                    offset=int(lm.group(3), 16), size=int(lm.group(4), 16),
                    crc=lm.group(5)))
        sets[name] = {"regions": regions}
    # GAME macros for titles/parents
    for m in re.finditer(
            r'^GAMEL?\(\s*(\d+),\s*(\w+),\s*(\w+),\s*[\w]+,\s*\w+,\s*\w+,\s*init_\w+,\s*[\w_]+,\s*"([^"]*)",\s*"([^"]*)"',
            src, re.M):
        year, name, parent, manu, title = m.groups()
        if name in sets:
            sets[name].update(year=year, parent=parent if parent != "0" else "",
                              manu=manu, title=title)
    return sets

def macro_base_rep(mac):
    """Split a ROM_LOAD macro into its base form and repeat count."""
    m = re.match(r"(.*?)(_x(2|4|8|16))?$", mac)
    base = m.group(1)
    rep = int(m.group(3)) if m.group(3) else 1
    # plain ROM_LOAD_xN parses as base "ROM_LOAD"
    return base, rep

def interleave_parts(loads, region_size, ctx=""):
    """Emit MRA <part> XML for a region's loads, padded to region_size.
    Every load must be consumed and the emitted bytes tracked by a cursor —
    silent drops previously left ga2 without its second program megabyte,
    its Z80 program, and all sprite data."""
    out = []
    cursor = 0
    i = 0
    loads = sorted(loads, key=lambda l: l["offset"])

    def pad_to(off):
        nonlocal cursor
        assert off >= cursor, f"{ctx}: overlapping loads at 0x{off:x}"
        if off > cursor:
            out.append(f'    <part repeat="{off - cursor}">FF</part>')
            cursor = off

    while i < len(loads):
        l = loads[i]
        base, rep = macro_base_rep(l["macro"])
        if base == "ROM_LOAD16_BYTE":
            pair = loads[i:i+2]
            assert len(pair) == 2 and pair[1]["offset"] == pair[0]["offset"] + 1, \
                f"{ctx}: unpaired ROM_LOAD16_BYTE {l['file']}"
            pad_to(pair[0]["offset"])
            block = ['    <interleave output="16">',
                     f'      <part name="{escape(pair[0]["file"])}" crc="{pair[0]["crc"]}" map="01"/>',
                     f'      <part name="{escape(pair[1]["file"])}" crc="{pair[1]["crc"]}" map="10"/>',
                     '    </interleave>']
            for _ in range(rep):
                out.extend(block)
            cursor += rep * (pair[0]["size"] + pair[1]["size"])
            i += 2
            continue
        if base == "ROM_LOAD32_WORD":
            pair = loads[i:i+2]
            assert len(pair) == 2 and pair[1]["offset"] == pair[0]["offset"] + 2, \
                f"{ctx}: unpaired ROM_LOAD32_WORD {l['file']}"
            pad_to(pair[0]["offset"])
            # each part is a 16-bit word per 32-bit group: map digits name the
            # part's 1st/2nd byte, lanes read right-to-left
            block = ['    <interleave output="32">',
                     f'      <part name="{escape(pair[0]["file"])}" crc="{pair[0]["crc"]}" map="0021"/>',
                     f'      <part name="{escape(pair[1]["file"])}" crc="{pair[1]["crc"]}" map="2100"/>',
                     '    </interleave>']
            for _ in range(rep):
                out.extend(block)
            cursor += rep * (pair[0]["size"] + pair[1]["size"])
            i += 2
            continue
        if base == "ROM_LOAD64_WORD":
            grp = loads[i:i+4]
            assert len(grp) == 4 and all(
                grp[k]["offset"] == grp[0]["offset"] + 2*k for k in range(4)), \
                f"{ctx}: bad ROM_LOAD64_WORD group at {l['file']}"
            pad_to(grp[0]["offset"])
            out.append('    <interleave output="64">')
            for k, g in enumerate(grp):
                lanes = ["00"] * 4
                lanes[k] = "21"
                out.append(f'      <part name="{escape(g["file"])}" crc="{g["crc"]}" map="{"".join(reversed(lanes))}"/>')
            out.append('    </interleave>')
            cursor += sum(g["size"] for g in grp)
            i += 4
            continue
        if base in ("ROM_LOAD32_BYTE", "ROM_LOAD64_BYTE"):
            n = 4 if base == "ROM_LOAD32_BYTE" else 8
            grp = loads[i:i+n]
            assert len(grp) == n, f"{ctx}: short {base} group at {l['file']}"
            pad_to(grp[0]["offset"])
            out.append(f'    <interleave output="{n*8}">')
            for k, g in enumerate(grp):
                mp = "".join("1" if j == k else "0" for j in range(n))[::-1]
                out.append(f'      <part name="{escape(g["file"])}" crc="{g["crc"]}" map="{mp}"/>')
            out.append('    </interleave>')
            cursor += sum(g["size"] for g in grp)
            i += n
            continue
        # plain ROM_LOAD / ROM_LOAD16_WORD, with optional _xN repeats
        pad_to(l["offset"])
        for _ in range(rep):
            out.append(f'    <part name="{escape(l["file"])}" crc="{l["crc"]}"/>')
        cursor += l["size"] * rep
        i += 1
    assert cursor <= region_size, f"{ctx}: loads overflow region (0x{cursor:x} > 0x{region_size:x})"
    if cursor < region_size:
        out.append(f'    <part repeat="{region_size - cursor}">FF</part>')
    return out, cursor

def gen(setname, data, outdir):
    parent = data.get("parent") or setname
    if (setname in IGNORED_SETS or setname in IGNORED_PARENTS or
            parent in IGNORED_PARENTS):
        return False
    # A set-specific entry must override its parent's board descriptor when
    # MAME installs a different init/protection handler for the clone;
    # falling back to the parent is correct only when no explicit set entry
    # exists.
    d_base = GAMES.get(setname) or GAMES.get(parent)
    if d_base is None or setname in UNSUPPORTED:
        return False
    regions = {r["region"]: r for r in data["regions"]}
    d = bytearray(d_base)
    sprite_region_size = regions.get("sprites", {}).get("size", 0x1000000)
    assert sprite_region_size in (0x400000, 0x800000, 0x1000000), (
        f"{setname}: unsupported sprite region size {sprite_region_size:#x}")
    sprite_banks = sprite_region_size // 0x400000
    d[3] = 0x80 | (sprite_banks - 1)
    # D1: no region may exceed its declared SDRAM slot size.
    for reg, size in REGION_SIZES.items():
        r = regions.get(reg)
        if r:
            loaded = sum(l["size"] for l in r["loads"])
            assert loaded <= size, (
                f"{setname}: region {reg} loads {loaded:#x} > slot {size:#x}")
    lines = []
    lines.append('<misterromdescription>')
    lines.append(f'  <name>{escape(data.get("title", setname))}</name>')
    lines.append(f'  <setname>{setname}</setname>')
    if parent != setname:
        lines.append(f'  <parent>{parent}</parent>')
    lines.append(f'  <year>{data.get("year", "")}</year>')
    lines.append(f'  <manufacturer>{escape(data.get("manu", "Sega"))}</manufacturer>')
    lines.append(f'  <rbf>{RBF_BY_PARENT.get(parent, "Arcade-SegaSystem32Multi")}</rbf>')
    joystick_meta = JOYSTICKS.get(parent)
    if joystick_meta:
        lines.append(f'  <joystick>{escape(joystick_meta)}</joystick>')
    button_meta = BUTTONS.get(parent)
    if button_meta:
        names, defaults = button_meta
        count = BUTTON_COUNTS[parent]
        lines.append(
            f'  <buttons names="{names}" default="{defaults}" count="{count}"/>'
        )
    # A clone MRA must be usable with all standard MAME set layouts.  The
    # parent archive is needed by split sets, while merged sets keep the clone
    # ROMs in that same parent-named archive.  MiSTer/mra-tools accepts a
    # pipe-separated list and combines every archive that is present, so a
    # missing side of the pair is harmless for standalone/non-merged sets.
    rom_zips = f"{setname}.zip"
    if parent != setname:
        rom_zips = f"{parent}.zip|{rom_zips}"
    # Region downloads precede the descriptor commit. Each is padded only to
    # its MAME-declared size, rather than every core slot's maximum size.
    for reg in STREAM_ORDER:
        r = regions.get(reg)
        if not r or not r["loads"]:
            continue
        region_size = r["size"]
        assert region_size <= REGION_SIZES[reg], (
            f"{setname}: region {reg} size {region_size:#x} exceeds slot")
        lines.append(f'  <rom index="{REGION_INDEX[reg]}" zip="{rom_zips}" md5="none">')
        parts, _ = interleave_parts(r["loads"], region_size, ctx=f"{setname}/{reg}")
        lines += parts
        lines.append('  </rom>')

    # Defaults precede index 0 so the descriptor is the final boot commit.
    ee = regions.get("eeprom")
    if ee and ee["loads"]:
        # Every external part needs an archive source on its own rom/part
        # element. Archive selection is not inherited from earlier region
        # downloads, so omitting zip here makes MiSTer report the EEPROM as a
        # missing loose file even when it is present in the MAME set archive.
        lines.append(f'  <rom index="2" zip="{rom_zips}" md5="none">')
        lines.append(f'    <part name="{escape(ee["loads"][0]["file"])}" crc="{ee["loads"][0]["crc"]}"/>')
        lines.append('  </rom>')
    lines.append('  <nvram index="3" size="128"/>')

    hexd = bytes(d).hex().upper()
    lines.append('  <rom index="0">')
    lines.append(f'    <part>{hexd}</part>')
    lines.append('  </rom>')
    lines.append('</misterromdescription>')
    title = data.get("title", setname).replace("/", "-").replace(":", "")
    with open(os.path.join(outdir, f"{title}.mra"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return True

def main():
    src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    # D2: the emitted stream layout must match the RTL loader's OFF_* stream
    # boundaries (rtl/mem/s32_rom_loader.sv) — descriptor(0x40) then each
    # region padded to REGION_SIZES in STREAM_ORDER. This is the real
    # generator<->loader contract (the loader's map_addr then translates
    # each stream offset to its SDRAM region base, DESIGN.md §4.2/§9.3).
    LOADER_OFF = {"maincpu": 0x40}
    acc = 0x40
    for reg in STREAM_ORDER:
        LOADER_OFF.setdefault(reg, acc)
        acc += REGION_SIZES[reg]
    assert LOADER_OFF["soundcpu"] == 0x40 + 0x200000
    assert LOADER_OFF["sprites"] == 0x40 + 0x200000 + 0x400000*3 + 0x10000, \
        "stream layout drifted from s32_rom_loader OFF_SPRITES"
    sets = parse(src)
    n = 0
    for name, data in sorted(sets.items()):
        if "title" not in data:
            continue
        if gen(name, data, outdir):
            n += 1
        else:
            print(f"skip {name} (unsupported)")
    print(f"generated {n} MRAs")

if __name__ == "__main__":
    main()
