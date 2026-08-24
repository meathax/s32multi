"""The simulator must boot the machine the core actually ships.

verif/common/tb_core_romboot.sv used to take its board descriptor from four
hand-maintained +B0/+B1/+B2/+SBM plusargs that verif/verilator/run_romboot.sh
set from a per-game `case` with a `B0=20` default.  Fifteen of the seventeen
System 32 sets therefore simulated a board the core does not ship -- no ADC on
the analog games, a phantom 8255 on holo, `prot_sel` forced to zero on
brival/darkedge/f1lap/dbzvrvs, and a 16 MB sprite bank mask on 4 and 8 MB sets.
Every per-game diagnosis taken that way was taken against the wrong hardware.

The harness now reads the image's desc.txt, which make_sim_images.py copies out
of the MRA's ioctl index-0 stream.  These tests pin both halves of that chain:

  * the extraction is faithful -- what make_sim_images.py would write equals the
    bytes the MRA ships (no ROM archive needed, index 0 is inline hex);
  * a locally staged image is not stale -- its desc.txt still matches its MRA.

The second test skips when roms/sim is absent, which is the normal case in CI:
roms/ is gitignored.
"""

import binascii
import sys
import unittest
from pathlib import Path
from xml.etree import ElementTree

REPO = Path(__file__).parents[1]
sys.path.insert(0, str(REPO / "tools"))

import make_sim_images  # noqa: E402


def _mra_descriptor(path: Path) -> bytes:
    """The 64 descriptor bytes an MRA delivers on ioctl index 0."""
    root = ElementTree.parse(path).getroot()
    rom0 = next((r for r in root.findall("rom") if r.get("index") == "0"), None)
    assert rom0 is not None, f"{path.name} has no index-0 stream"
    text = "".join("".join(p.itertext()) for p in rom0.findall("part"))
    return binascii.unhexlify("".join(text.split()))


def _parents() -> dict:
    """setname -> mra path, for every shipped MRA."""
    out = {}
    for path in sorted((REPO / "releases").glob("*.mra")):
        root = ElementTree.parse(path).getroot()
        setname = root.findtext("setname")
        assert setname, f"{path.name} has no setname"
        assert setname not in out, (
            f"{path.name} and {out.get(setname, Path()).name} both claim "
            f"setname {setname}")
        out[setname] = path
    return out


class MraDescriptorExtractionTests(unittest.TestCase):
    def test_every_mra_ships_a_64_byte_descriptor_on_index_0(self) -> None:
        expected_profiles = {
            "orunners": 0x00,
            "titlef": 0x04,
            "harddunk": 0x08,
            "scross": 0x0C,
        }
        mras = _parents()
        self.assertGreater(len(mras), 0, "no MRAs found")
        for setname, path in mras.items():
            with self.subTest(set=setname):
                desc = _mra_descriptor(path)
                self.assertEqual(len(desc), 0x40, path.name)
                # Byte 4 carries the digital profile in bits 1:0 and the
                # universal Multi 32 title selector in bits 4:2.
                self.assertIn(setname, expected_profiles, path.name)
                self.assertEqual(desc[4], expected_profiles[setname], path.name)
                # Bytes 5..63 remain reserved and must stay zero.
                self.assertEqual(desc[5:], bytes(0x3B), path.name)

    def test_make_sim_images_reproduces_the_shipped_descriptor(self) -> None:
        """The staging tool must not transform the descriptor on its way in."""
        for setname, path in _parents().items():
            with self.subTest(set=setname):
                # Index 0 is inline hex, so no ROM archive is touched here.
                built = make_sim_images.build_stream(str(path), "")
                self.assertEqual(built, _mra_descriptor(path), path.name)


class StagedSimImageTests(unittest.TestCase):
    """Guard against a staged roms/sim image going stale against its MRA."""

    def test_staged_desc_txt_matches_the_mra_it_came_from(self) -> None:
        sim_root = REPO / "roms" / "sim"
        if not sim_root.is_dir():
            self.skipTest("roms/sim is not staged (roms/ is gitignored)")
        mras = _parents()
        checked = 0
        for staged in sorted(p for p in sim_root.iterdir() if p.is_dir()):
            desc_txt = staged / "desc.txt"
            if not desc_txt.is_file():
                continue
            # Parent sets only; clone/variant staging dirs (e.g. jpark_patched)
            # deliberately differ from any single shipped MRA.
            if staged.name not in mras:
                continue
            with self.subTest(set=staged.name):
                have = binascii.unhexlify(desc_txt.read_text().strip())
                want = _mra_descriptor(mras[staged.name])
                self.assertEqual(
                    have.hex(), want.hex(),
                    f"roms/sim/{staged.name}/desc.txt is stale against "
                    f"{mras[staged.name].name}; re-run tools/make_sim_images.py")
                checked += 1
        self.assertGreater(checked, 0, "no staged parent-set images found")


if __name__ == "__main__":
    unittest.main()
