import unittest
from pathlib import Path
from xml.etree import ElementTree

from tools.gen_mra import BUTTONS, GAMES, RBF_BY_PARENT


class BoardDescriptorTests(unittest.TestCase):
    def test_holosseum_is_regular_flipped_two_bank_sprite_board(self) -> None:
        descriptor = bytearray(GAMES["holo"])
        # Generator fills physical sprite metadata after parsing the ROM region.
        descriptor[3] = 0x81
        self.assertEqual(descriptor[0], 0x00)
        self.assertEqual(descriptor[1] & 0x01, 0x00)  # no dual PCB
        self.assertEqual(descriptor[1] & 0x02, 0x02)  # ORIENTATION_FLIP_Y
        self.assertEqual(descriptor[2], 0x00)         # no protection HLE
        self.assertEqual(descriptor[3], 0x81)         # 8 MiB sprites

    def test_gun_games_default_invert_aim(self) -> None:
        # alien3/jpark carry gun_aim (b1 bit2) so their positional-gun analog
        # aim defaults to inverted; the ADC (b0 bit3) stays set.
        for game in ("alien3", "jpark"):
            descriptor = bytearray(GAMES[game])
            self.assertEqual(descriptor[0] & 0x08, 0x08, game)  # ADC present
            self.assertEqual(descriptor[1] & 0x04, 0x04, game)  # gun_aim invert
        # a non-gun analog board (radm steering) must NOT default-invert
        self.assertEqual(bytearray(GAMES["radm"])[1] & 0x04, 0x00)

    def test_outrunners_selects_two_station_wiring(self) -> None:
        descriptor = bytearray(GAMES["orunners"])
        self.assertEqual(descriptor[0] & 0x09, 0x09)  # Multi32 + ADC
        self.assertEqual(descriptor[1] & 0x10, 0x10)  # OutRunners wiring
        self.assertEqual(RBF_BY_PARENT["orunners"], "s32Multi32")

    def test_all_four_multi32_titles_share_one_rbf(self) -> None:
        # The whole point of the Multi 32 revision: one bitstream, four games.
        # harddunk/scross/titlef previously pointed at the System 32 release,
        # which contains no Multi 32 support at all.
        for parent in ("harddunk", "orunners", "scross", "titlef"):
            self.assertEqual(RBF_BY_PARENT[parent], "s32Multi32", parent)
            self.assertEqual(GAMES[parent][0] & 0x01, 0x01, f"{parent} multi32 bit")
            self.assertEqual(GAMES[parent][0] & 0x02, 0x00, f"{parent} must be unprotected")
            # byte 3 (sprite bank valid/mask) is computed at generation time
            # from the real ROM region size, not carried in GAMES.
        # The per-game selectors the RTL keeps descriptor-driven must actually
        # differ, or a single build could not tell the four apart.
        self.assertEqual(GAMES["harddunk"][0] & 0x20, 0x20)   # has_ppi
        self.assertEqual(GAMES["harddunk"][0] & 0x08, 0x00)   # no adc
        self.assertEqual(GAMES["scross"][0]   & 0x08, 0x08)   # has_adc
        self.assertEqual(GAMES["scross"][0]   & 0x20, 0x00)   # no ppi
        self.assertEqual(GAMES["scross"][1]   & 0x10, 0x00)   # not orunners wiring
        self.assertEqual(GAMES["titlef"][0]   & 0x28, 0x00)   # neither

    def test_multi32_revision_qsf(self) -> None:
        qsf = (Path(__file__).parents[1] / "s32Multi32.qsf").read_text(encoding="utf-8")
        self.assertIn('VERILOG_MACRO "S32_MULTI32_ONLY=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_RELEASE_MINIMAL=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_JT12_MLAB_SHIFTS=1"', qsf)
        # Both screens are retained on this revision by decision.
        self.assertNotIn("S32_SINGLE_SCREEN_MIX", qsf)


class ButtonMetadataTests(unittest.TestCase):
    def test_outrunners_exposes_cabinet_controls(self) -> None:
        names, defaults = BUTTONS["orunners"]
        self.assertEqual(names.split(",")[:6],
                         ["Shift Up", "Shift Down", "DJ Music",
                          "Music Back", "Music Forward", "Brake"])
        self.assertEqual(len(defaults.split(",")), 10)

    def test_spiderman_has_two_action_buttons_and_system_controls(self) -> None:
        names, defaults = BUTTONS["spidman"]
        self.assertEqual(names.split(","),
                         ["Attack", "Jump", "-", "-", "-", "-", "Start", "Coin", "Test", "Service"])
        self.assertEqual(defaults.split(","),
                         ["A", "B", "Start", "Select", "R", "L"])

    def test_all_spiderman_mras_expose_button_metadata(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        for path in sorted(mra_dir.glob("Spider-Man The Videogame*.mra")):
            root = ElementTree.parse(path).getroot()
            buttons = root.find("buttons")
            self.assertIsNotNone(buttons, path.name)
            self.assertEqual(buttons.attrib["names"], BUTTONS["spidman"][0])
            self.assertEqual(buttons.attrib["default"], BUTTONS["spidman"][1])
            self.assertEqual(buttons.attrib["count"], "2")


class OptimizedLayoutTests(unittest.TestCase):
    def test_every_mra_commits_descriptor_after_region_downloads(self) -> None:
        mra_dir = Path(__file__).parents[1] / "mra"
        paths = sorted(mra_dir.glob("*.mra"))
        self.assertEqual(len(paths), 59)
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


if __name__ == "__main__":
    unittest.main()
