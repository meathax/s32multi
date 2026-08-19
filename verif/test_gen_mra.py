import sys
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree

from tools.gen_mra import BUTTONS, GAMES, IGNORED_PARENTS, IGNORED_SETS, gen


class BoardDescriptorTests(unittest.TestCase):
    def test_ignored_parents_are_not_profile_descriptors(self) -> None:
        self.assertTrue(IGNORED_PARENTS.isdisjoint(GAMES))

    def test_only_orunners_is_a_supported_parent(self) -> None:
        self.assertEqual(set(GAMES), {"orunners"})

    def test_orunners_selects_multi32_adc_and_driving_analog(self) -> None:
        # b0 bit0=multi32, bit3=adc; b1[5:4]=analog profile (DRIVING=1).
        self.assertEqual(GAMES["orunners"][:3], bytes.fromhex("091000"))


class ButtonMetadataTests(unittest.TestCase):
    def test_orunners_has_shifter_and_music_buttons(self) -> None:
        names, defaults = BUTTONS["orunners"]
        self.assertEqual(names.split(","),
                         ["Shift Up", "Shift Down", "DJ/Music", "Music Prev",
                          "Music Next", "-", "Start", "Coin", "Test",
                          "Service"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "X", "Y", "R", "Start", "Select", "L"])


class EepromArchiveSourceTests(unittest.TestCase):
    def generate_orunners(self, setname: str, parent: str) -> ElementTree.Element:
        data = {
            "parent": parent,
            "title": f"EEPROM source fixture {setname}",
            "year": "1992",
            "manu": "Sega",
            "regions": [
                {
                    "region": "maincpu", "size": 1,
                    "loads": [{
                        "macro": "ROM_LOAD", "file": "program.bin",
                        "offset": 0, "size": 1, "crc": "00000000",
                    }],
                },
                {
                    "region": "eeprom", "size": 0x80,
                    "loads": [{
                        "macro": "ROM_LOAD16_WORD",
                        "file": "eeprom-orunners.ic76",
                        "offset": 0, "size": 0x80, "crc": "602032c6",
                    }],
                },
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(gen(setname, data, tmp))
            path = next(Path(tmp).glob("*.mra"))
            return ElementTree.parse(path).getroot()

    def test_parent_and_clone_eeprom_roms_name_their_archives(self) -> None:
        for setname, parent, expected_zip in (
            ("orunners", "", "orunners.zip"),
            ("orunnersu", "orunners", "orunners.zip|orunnersu.zip"),
        ):
            with self.subTest(setname=setname):
                root = self.generate_orunners(setname, parent)
                eeprom = next(
                    rom for rom in root.findall("rom")
                    if rom.attrib["index"] == "2"
                )
                self.assertEqual(eeprom.attrib.get("zip"), expected_zip)
                self.assertEqual(eeprom.attrib.get("md5"), "none")
                self.assertEqual(
                    eeprom.find("part").attrib,
                    {"name": "eeprom-orunners.ic76", "crc": "602032c6"},
                )


class OptimizedLayoutTests(unittest.TestCase):
    def test_every_supported_mra_declares_persistent_score_storage(self) -> None:
        """Every supported variant must expose the EEPROM to MiSTer NVRAM.

        OutRunners high scores live in the board's 93C46-backed persistent
        storage. The core's loader and EEPROM model use index 3 as the
        upload/save image; a missing tag makes a title appear to work while
        silently losing its score table between launches.
        """
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.glob("*.mra"))
        self.assertEqual(len(paths), 3, str(mra_dir))
        for path in paths:
            root = ElementTree.parse(path).getroot()
            self.assertEqual(len(root.findall("nvram")), 1, path.name)
            nvram = root.find("nvram[@index='3']")
            self.assertIsNotNone(nvram, path.name)
            self.assertEqual(nvram.attrib, {"index": "3", "size": "128"}, path.name)

    def test_every_mra_commits_descriptor_after_region_downloads(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.glob("*.mra"))
        self.assertEqual(len(paths), 3)
        for path in paths:
            root = ElementTree.parse(path).getroot()
            roms = root.findall("rom")
            indexes = [int(rom.attrib["index"]) for rom in roms]
            self.assertEqual(indexes[-1], 0, path.name)
            self.assertTrue(all(index in {0, 2, 4, 5, 6, 7, 8, 9}
                                for index in indexes), path.name)
            descriptor_rom = roms[-1]
            self.assertNotIn("zip", descriptor_rom.attrib, path.name)
            descriptor = bytes.fromhex(descriptor_rom.findtext("part", ""))
            self.assertEqual(len(descriptor), 64, path.name)
            self.assertTrue(any(index >= 4 for index in indexes), path.name)

    def test_orunners_family_ships_parent_and_two_clones(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.glob("OutRunners*.mra"))
        self.assertEqual([path.name for path in paths],
                         ["OutRunners (Japan).mra", "OutRunners (US).mra",
                          "OutRunners (World).mra"])
        expected_setnames = {
            "OutRunners (Japan).mra": "orunnersj",
            "OutRunners (US).mra": "orunnersu",
            "OutRunners (World).mra": "orunners",
        }
        for path in paths:
            root = ElementTree.parse(path).getroot()
            self.assertEqual(root.findtext("setname"), expected_setnames[path.name])
            if expected_setnames[path.name] != "orunners":
                self.assertEqual(root.findtext("parent"), "orunners")
            self.assertEqual(root.findtext("rbf"), "Arcade-SegaSystem32Multi")
            buttons = root.find("buttons")
            self.assertIsNotNone(buttons, path.name)
            self.assertEqual(buttons.attrib["names"], BUTTONS["orunners"][0], path.name)
            self.assertEqual(buttons.attrib["default"], BUTTONS["orunners"][1], path.name)
            descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
            self.assertEqual(descriptor[:3], bytes.fromhex("091000"), path.name)


class RegenerationFidelityTests(unittest.TestCase):
    """The tracked MRAs must be exactly what gen_mra.py emits today.

    Drift here is silent and lossy: a regeneration overwrites hand-carried
    metadata with whatever the generator tables happen to say.
    """

    MAME_SRC = (Path(__file__).parents[1] / "scratch" / "upstream" /
                "mame-master-20260719" / "src" / "mame" / "sega" /
                "segas32.cpp")

    def test_generator_reproduces_every_tracked_mra(self) -> None:
        if not self.MAME_SRC.is_file():
            self.skipTest(f"MAME reference source not present: {self.MAME_SRC}")
        import subprocess, tempfile
        repo = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(
                [sys.executable, str(repo / "tools" / "gen_mra.py"),
                 str(self.MAME_SRC), tmp],
                 check=True, capture_output=True)
            generated = sorted(Path(tmp).glob("*.mra"))
            mra_dir = repo / "releases"
            tracked = sorted(mra_dir.glob("*.mra"), key=lambda path: path.name)
            self.assertEqual([p.name for p in generated],
                             [p.name for p in tracked],
                             str(mra_dir))
            for want, got in zip(tracked, generated):
                # Compare text, not bytes: the tracked files carry CRLF
                # from git's autocrlf checkout while the generator emits
                # LF.
                self.assertEqual(
                    want.read_text(encoding="utf-8").splitlines(),
                    got.read_text(encoding="utf-8").splitlines(),
                    want.name,
                )


class OutRunnersInclusionTests(unittest.TestCase):
    """This repository is OutRunners-only Sega System Multi 32.

    The RTL builds the Multi 32 profile (837-8676): a second palette, second
    mixer, the MultiPCM path and the full work RAM complement. OutRunners is
    therefore the one game this core supports, and it must always be present
    -- these tests fail if the generator or the tracked release stops
    emitting it.
    """

    def test_generator_defines_the_orunners_multi32_set(self) -> None:
        self.assertIn("orunners", GAMES)

    def test_orunners_descriptor_sets_the_multi32_bit(self) -> None:
        # b0 bit0 is the multi32 flag the RTL parses out of the index-0
        # descriptor. orunners must assert it.
        self.assertEqual(GAMES["orunners"][0] & 0x01, 0x01)

    def test_orunners_mra_is_emitted_and_not_excluded(self) -> None:
        self.assertNotIn("orunners", IGNORED_PARENTS)
        self.assertNotIn("orunners", IGNORED_SETS)
        mra_dir = Path(__file__).parents[1] / "releases"
        paths = sorted(mra_dir.glob("*.mra"))
        self.assertTrue(paths)
        setnames = set()
        for path in paths:
            root = ElementTree.parse(path).getroot()
            setnames.add(root.findtext("setname", ""))
            descriptor = bytes.fromhex(root.findall("rom")[-1].findtext("part", ""))
            self.assertEqual(descriptor[0] & 0x01, 0x01, path.name)
        self.assertEqual(setnames, {"orunners", "orunnersu", "orunnersj"})

    def test_every_tracked_mra_targets_the_multi32_rbf(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        for path in sorted(mra_dir.glob("*.mra")):
            rbf = ElementTree.parse(path).getroot().findtext("rbf", "")
            self.assertEqual(rbf, "Arcade-SegaSystem32Multi", path.name)


if __name__ == "__main__":
    unittest.main()
