#!/usr/bin/env python3
"""
Build simulation memory images from an MRA + ROM ZIP or unzipped directory.

Interprets the MRA <rom index="0"> stream exactly as MiSTer's mra tool
would (parts concatenated, repeat, interleave with byte-lane maps), then
splits it at the s32_rom_loader OFF_* boundaries and emits $readmemh
images in the SDRAM word packing (little-endian byte pairs; 64-bit tile
words / 128-bit sprite chunks in ascending-address byte order):

  maincpu.hex   1M   x 16-bit   (SDRAM p0, base 0x000000)
  soundcpu.hex  2M   x 16-bit   (SDRAM p3, base 0x200000)
  tiles.hex     512K x 64-bit   (SDRAM p1, base 0x600000)
  multipcm.hex  2M   x 16-bit   (SDRAM p4, base 0xA00000)
  sprites.hex   1M   x 128-bit  (SDRAM p2, base 0x1000000)
  mcu.bin       64KB raw        (V25 program, loader-descrambled order)
  eeprom.hex    64 x 16-bit      (index-2 93C46 default, when present)
  desc.txt      board descriptor bytes

Usage: make_sim_images.py <file.mra> <romdir-or-zip> [additional-romdir-or-zip ...] <outdir>
"""
import sys, os, zlib, binascii, zipfile
import xml.etree.ElementTree as ET

REGIONS = [  # (name, size)
    ("maincpu",  0x200000),
    ("soundcpu", 0x400000),
    ("tiles",    0x400000),
    ("multipcm", 0x400000),
    ("mcu",      0x010000),
    ("sprites",  0x1000000),
]

_crc_index = {}
_zip_index = {}

def normalize_romdirs(romdirs):
    """Accept one ROM source for API compatibility or a source sequence."""
    if isinstance(romdirs, (str, bytes, os.PathLike)):
        return [romdirs]
    return list(romdirs)

def indexed_zip(path):
    if path not in _zip_index:
        archive = zipfile.ZipFile(path, "r")
        by_name = {}
        by_stem = {}
        by_crc = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            base = os.path.basename(info.filename).lower()
            by_name[base] = info
            by_stem[base.rsplit(".", 1)[0]] = info
            by_crc[format(info.CRC & 0xffffffff, "08x")] = info
        _zip_index[path] = (archive, by_name, by_stem, by_crc)
    return _zip_index[path]

def load_part(romdirs, name, crc):
    """Load a part, trying clone media before any explicitly supplied parent media."""
    sources = normalize_romdirs(romdirs)
    for romdir in sources:
        if zipfile.is_zipfile(romdir):
            archive, by_name, by_stem, by_crc = indexed_zip(romdir)
            key = os.path.basename(name).lower()
            info = by_name.get(key) or by_stem.get(key.rsplit(".", 1)[0])
            if info is None and crc:
                info = by_crc.get(crc.lower())
            if info is None:
                continue
            data = archive.read(info)
            have = format(zlib.crc32(data) & 0xffffffff, "08x")
            if crc and have != crc.lower():
                print(f"  WARNING: {name} crc {have} != mra {crc}")
            return data

        path = os.path.join(romdir, name)
        if not os.path.exists(path):
            # sets from other sources drop extensions — try the stem, then CRC
            stem = os.path.join(romdir, name.rsplit(".", 1)[0])
            if os.path.exists(stem):
                path = stem
            elif crc:
                if romdir not in _crc_index:
                    _crc_index[romdir] = {}
                    for f in os.listdir(romdir):
                        fp = os.path.join(romdir, f)
                        with open(fp, "rb") as handle:
                            c = format(zlib.crc32(handle.read()) & 0xffffffff, "08x")
                        _crc_index[romdir][c] = fp
                path = _crc_index[romdir].get(crc.lower())
                if path is None:
                    continue
        with open(path, "rb") as handle:
            data = handle.read()
        have = format(zlib.crc32(data) & 0xffffffff, "08x")
        if crc and have != crc.lower():
            print(f"  WARNING: {name} crc {have} != mra {crc}")
        return data

    joined = ", ".join(os.fspath(source) for source in sources)
    raise AssertionError(f"no entry in {joined} matches {name} (crc {crc})")

def part_bytes(el, romdir):
    if el.get("name"):
        return load_part(romdir, el.get("name"), el.get("crc"))
    text = "".join((el.text or "").split())
    data = binascii.unhexlify(text)
    rep = int(el.get("repeat", "1"))
    return data * rep

def interleave(el, romdir):
    group = int(el.get("output")) // 8
    parts = []
    for p in el.findall("part"):
        data = load_part(romdir, p.get("name"), p.get("crc"))
        mapping = p.get("map")
        # map string: leftmost char = highest lane; digit d = part's d-th byte
        lanes = []
        for pos, ch in enumerate(reversed(mapping)):
            if ch != "0":
                lanes.append((pos, int(ch) - 1))
        k = len(lanes)   # bytes this part contributes per group
        parts.append((data, lanes, k))
    total_k = sum(k for _, _, k in parts)
    assert total_k == group, f"interleave lanes {total_k} != output bytes {group}"
    ngroups = len(parts[0][0]) // parts[0][2]
    out = bytearray(ngroups * group)
    for data, lanes, k in parts:
        assert len(data) // k == ngroups, "interleave part length mismatch"
        for g in range(ngroups):
            src = data[g*k:(g+1)*k]
            base = g * group
            for pos, idx in lanes:
                out[base + pos] = src[idx]
    return bytes(out)

def build_rom(rom, romdir):
    stream = bytearray()
    for el in rom:
        if el.tag == "part":
            stream += part_bytes(el, romdir)
        elif el.tag == "interleave":
            stream += interleave(el, romdir)
    for el in rom.findall("patch"):
        offset_text = el.get("offset")
        assert offset_text is not None, "MRA patch is missing an offset"
        offset = int(offset_text, 0)
        patch = binascii.unhexlify("".join((el.text or "").split()))
        assert patch, f"MRA patch at {offset:#x} is empty"
        end = offset + len(patch)
        assert end <= len(stream), (
            f"MRA patch {offset:#x}..{end - 1:#x} exceeds stream size {len(stream):#x}")
        stream[offset:end] = patch
    return bytes(stream)

def build_stream(mra_path, romdir):
    """Build index 0; retained for legacy callers and focused patch tests."""
    root = ET.parse(mra_path).getroot()
    rom0 = next((r for r in root.findall("rom") if r.get("index") == "0"), None)
    assert rom0 is not None
    return build_rom(rom0, romdir)

def build_regions(mra_path, romdir):
    """Return descriptor and fixed-size simulation regions for either format."""
    root = ET.parse(mra_path).getroot()
    by_index = {int(r.get("index")): r for r in root.findall("rom")}
    if any(index in by_index for index in range(4, 10)):
        desc = build_rom(by_index[0], romdir)
        assert len(desc) == 0x40, f"descriptor {len(desc):#x} != 0x40"
        blobs = []
        for index, (name, size) in enumerate(REGIONS, start=4):
            data = build_rom(by_index[index], romdir) if index in by_index else b""
            assert len(data) <= size, f"{name} {len(data):#x} exceeds slot {size:#x}"
            blobs.append(data.ljust(size, b"\xff"))
        return desc, blobs

    stream = build_rom(by_index[0], romdir)
    expect = 0x40 + sum(size for _, size in REGIONS)
    assert len(stream) == expect, f"stream {len(stream):#x} != expected {expect:#x}"
    desc, off, blobs = stream[:0x40], 0x40, []
    for _, size in REGIONS:
        blobs.append(stream[off:off + size])
        off += size
    return desc, blobs

def emit_hex(path, data, width_bytes):
    with open(path, "w") as f:
        for i in range(0, len(data), width_bytes):
            chunk = data[i:i+width_bytes]
            # SDRAM words are little-endian byte pairs; multi-word bursts put
            # the lowest-address word in the LSBs -> whole chunk is LE
            f.write(format(int.from_bytes(chunk, "little"), f"0{width_bytes*2}x") + "\n")

def main():
    mra_path, outdir = sys.argv[1], sys.argv[-1]
    romdirs = sys.argv[2:-1]
    assert romdirs, "at least one ROM source is required"
    os.makedirs(outdir, exist_ok=True)
    desc, blobs = build_regions(mra_path, romdirs)
    root = ET.parse(mra_path).getroot()
    eeprom_rom = next(
        (rom for rom in root.findall("rom") if rom.get("index") == "2"),
        None,
    )
    eeprom = build_rom(eeprom_rom, romdirs) if eeprom_rom is not None else b"\xff" * 128
    assert len(eeprom) <= 128, f"EEPROM default {len(eeprom):#x} exceeds 93C46"
    eeprom = eeprom.ljust(128, b"\xff")
    with open(os.path.join(outdir, "desc.txt"), "w") as f:
        f.write(desc.hex() + "\n")
    emit_hex(os.path.join(outdir, "eeprom.hex"), eeprom, 2)
    for (name, _), blob in zip(REGIONS, blobs):
        if name == "mcu":
            open(os.path.join(outdir, "mcu.bin"), "wb").write(blob)
        elif name == "tiles":
            emit_hex(os.path.join(outdir, "tiles.hex"), blob, 8)
        elif name == "sprites":
            emit_hex(os.path.join(outdir, "sprites.hex"), blob, 16)
        else:
            emit_hex(os.path.join(outdir, f"{name}.hex"), blob, 2)
    print(f"OK: {outdir} (desc flags b0={desc[0]:02x} b1={desc[1]:02x} b2={desc[2]:02x})")

if __name__ == "__main__":
    main()
