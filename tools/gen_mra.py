#!/usr/bin/env python3
"""
MRA generator for the Sega System 32 / Multi 32 MiSTer core.

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
#   b0: flags {multi32,v25,v25table,adc,track,ppi,dsp_hle,cd_stub}
#   b1: bit0=dual_pcb, bit1=vertical orientation flip, bit2=positional-gun
#       analog default-invert (alien3/jpark), bit3=coin swap,
#       bit4=OutRunners two-station I/O/analog wiring
#   b2: prot_sel
#   b3: bit7=physical sprite-bank metadata valid; bits1:0=bank mask
PROT = dict(NONE=0, SONIC=1, BRIVAL=2, DARKEDGE=3, F1LAP=4, DBZVRVS=5, JLEAGUE=6)
def desc(multi32=0, v25=0, v25table=0, adc=0, track=0, ppi=0, dsp=0, cd=0,
         dual=0, flip_y=0, prot=0, gun=0, coin_swap=0, orunners=0):
    b0 = (multi32 | v25 << 1 | v25table << 2 | adc << 3 | track << 4 |
          ppi << 5 | dsp << 6 | cd << 7)
    b1 = (dual | (flip_y << 1) | (gun << 2) | (coin_swap << 3) |
          (orunners << 4))
    d = bytes([b0, b1, prot]) + bytes(61)
    return d

GAMES = {
    # parent: (descriptor, per-set list built from clones automatically)
    "arescue":  desc(adc=1, dsp=1, dual=1),
    "alien3":   desc(adc=1, gun=1, coin_swap=1),
    "arabfgt":  desc(v25=1, v25table=1, ppi=1),
    "brival":   desc(ppi=1, prot=PROT["BRIVAL"]),
    "darkedge": desc(ppi=1, prot=PROT["DARKEDGE"]),
    "dbzvrvs":  desc(adc=1, prot=PROT["DBZVRVS"]),
    "f1en":     desc(adc=1, dual=1),
    "f1lap":    desc(adc=1, prot=PROT["F1LAP"]),
    "ga2":      desc(v25=1, v25table=0, ppi=1),
    "holo":     desc(flip_y=1),
    "jpark":    desc(adc=1, gun=1),
    "kokoroj":  desc(cd=1),
    "kokoroj2": desc(cd=1),
    "radm":     desc(adc=1),
    "radr":     desc(adc=1),
    "slipstrm": desc(adc=1),
    "sonic":    desc(track=1, prot=PROT["SONIC"]),
    "sonicp":   desc(track=1),
    "spidman":  desc(ppi=1),
    "svf":      desc(),
    "jleague":  desc(prot=PROT["JLEAGUE"]),
    "harddunk": desc(multi32=1, ppi=1),
    "orunners": desc(multi32=1, adc=1, orunners=1),
    "scross":   desc(multi32=1, adc=1),
    "titlef":   desc(multi32=1),
}

# Per-game button labels/defaults are part of the MRA contract, not the board
# descriptor. Keep them here so regenerating tracked MRAs preserves the
# remapping UI metadata as well as the ROM stream.
BUTTONS = {
    "ga2": (
        "Attack,Jump,Magic,-,-,-,Start,Coin,Test,Service",
        "A,B,X,Start,Select,R,L",
    ),
    "jpark": (
        "Shoot,-,-,-,-,-,Start,Coin,Test,Service",
        "A,Start,Select,R,L",
    ),
    "alien3": (
        "Trigger,Button,-,-,-,-,Start,Coin,Test,Service",
        "A,B,Start,Select,R,L",
    ),
    "spidman": (
        "Attack,Jump,-,-,-,-,Start,Coin,Test,Service",
        "A,B,Start,Select,R,L",
    ),
    "orunners": (
        "Shift Up,Shift Down,DJ Music,Music Back,Music Forward,Brake,Start,Coin,Test,Service",
        "A,B,X,Y,L,R,Start,Select,-,-",
    ),
}

BUTTON_COUNTS = {"ga2": 3, "jpark": 1, "alien3": 2, "spidman": 2,
                 "orunners": 6}
RBF_BY_PARENT = {"ga2": "s32GoldenAxe", "orunners": "s32OutRunners"}

UNSUPPORTED = {"as1", "as1a", "as1b", "as1c"}

# MAME init_* ROM pokes the hardware cannot supply, keyed by parent and applied
# to every set of that parent. Offsets are local to the maincpu index-4 stream.
#   jpark: init_jpark (segas32.cpp) pokes pROM[0xC15A8/2]=0xCD70 and
#   pROM[0xC15AA/2]=0xD8CD -- "Temp. Patch until we emulate the 'Drive
#   Board', thanks to Malice" -- letting the MAIN BD -> DRIVE BD network
#   check pass without the cabinet's drive-board Z80.  V60 is little-endian,
#   so the words become bytes 70 CD / CD D8.
PATCHES = {
    "jpark": [(0xC15A8, "70 CD CD D8")],
}

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
    d_base = GAMES.get(parent) or GAMES.get(setname)
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
    lines.append(f'  <rbf>{RBF_BY_PARENT.get(parent, "SegaS32")}</rbf>')
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
        if reg == "maincpu":
            for off, patch_hex in PATCHES.get(parent, []):
                lines.append(f'    <patch offset="0x{off:X}">{patch_hex}</patch>')
        lines.append('  </rom>')

    # Defaults precede index 0 so the descriptor is the final boot commit.
    ee = regions.get("eeprom")
    if ee and ee["loads"]:
        lines.append('  <rom index="2">')
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
