"""Regression guards for the three Multi 32 cabinet input profiles."""

from pathlib import Path
from xml.etree import ElementTree
import unittest


ROOT = Path(__file__).parents[1]
TOP = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")


class Multi32ControlTests(unittest.TestCase):
    def test_hard_dunk_routes_all_six_players(self):
        for player, joystick in enumerate(range(6), start=1):
            self.assertIn(
                f"hard_p{player}a = p_dig4(joystick_{joystick})", TOP
            )
        self.assertIn("wire [7:0] hard_p1b = hard_p4a;", TOP)
        self.assertIn("wire [7:0] hard_p2b = hard_p5a;", TOP)
        self.assertIn("wire [7:0] hard_ppi_pa = hard_p3a;", TOP)
        self.assertIn("wire [7:0] hard_ppi_pb = hard_p6a;", TOP)
        self.assertIn(
            "hard_ppi_pc = ~{6'b000000, joystick_5[10], joystick_2[10]}",
            TOP,
        )
        self.assertIn(
            "Button 1,Button 2,Button 3,Button 4,Start,Coin,Test,Service",
            (ROOT / "tools/gen_mra.py").read_text(encoding="utf-8"),
        )

    def test_stadium_cross_steering_and_handlebar_pitch(self):
        self.assertIn(".left_x(joystick_l_analog_0[7:0])", TOP)
        self.assertIn(".left_x(joystick_l_analog_1[7:0])", TOP)
        self.assertIn(
            "scross_p1a = scross_ctrl(joystick_0, joystick_l_analog_0[15:8])",
            TOP,
        )
        self.assertIn(
            "scross_p1b = scross_ctrl(joystick_1, joystick_l_analog_1[15:8])",
            TOP,
        )
        self.assertIn(".digital_left(joystick_0[1])", TOP)
        self.assertIn(".digital_right(joystick_0[0])", TOP)
        self.assertIn(".digital_left(joystick_1[1])", TOP)
        self.assertIn(".digital_right(joystick_1[0])", TOP)
        self.assertIn("p[3] = ~((y < -9'sd24) || j[3] || j[8])", TOP)
        self.assertIn("p[4] = ~((y >  9'sd24) || j[2] || j[9])", TOP)
        self.assertIn("? joystick_0[7]", TOP)
        self.assertIn("? 1'b0", TOP)
        self.assertIn("? joystick_1[7]", TOP)

    def test_title_fight_uses_both_analog_sticks(self):
        self.assertIn(
            "title_p1_left  = title_stick(joystick_0, joystick_l_analog_0)",
            TOP,
        )
        self.assertIn(
            "title_p1_right = title_right_stick(joystick_0, joystick_r_analog_0)",
            TOP,
        )
        self.assertIn(
            "title_p2_left  = title_stick(joystick_1, joystick_l_analog_1)",
            TOP,
        )
        self.assertIn(
            "title_p2_right = title_right_stick(joystick_1, joystick_r_analog_1)",
            TOP,
        )
        for bit in range(4, 8):
            self.assertIn(f"j[{bit}]", TOP)
        self.assertIn(
            "Right Stick Left,Right Stick Right,Right Stick Up,Right Stick Down,"
            "Start,Coin,Test,Service",
            (ROOT / "tools/gen_mra.py").read_text(encoding="utf-8"),
        )

    def test_service_start_coin_lanes_use_hps_io_contract(self):
        # hps_io joystick bits are D-pad [3:0], action [9:4], Start [10],
        # Coin [11], Test [13], Service [14].  No production service mux may
        # consume the old off-by-one bit 12.
        self.assertIn("joystick_1[10]", TOP)
        self.assertIn("joystick_0[10]", TOP)
        self.assertIn("joystick_1[11]", TOP)
        self.assertIn("joystick_0[11]", TOP)
        self.assertNotIn("joystick_0[12]", TOP)
        self.assertNotIn("joystick_1[12]", TOP)

    def test_new_mras_have_named_controls(self):
        expected = {
            "titlef": (
                "Right Stick Left,Right Stick Right,Right Stick Up,Right Stick Down,"
                "Start,Coin,Test,Service",
                "4",
            ),
            "harddunk": (
                "Button 1,Button 2,Button 3,Button 4,Start,Coin,Test,Service",
                "4",
            ),
            "scross": (
                "Attack,Wheelie,Brake,Accelerate,Handlebar Forward,Handlebar Back,Start,Coin,Test,Service",
                "6",
            ),
        }
        seen = set()
        for path in (ROOT / "releases").rglob("*.mra"):
            root = ElementTree.parse(path).getroot()
            setname = root.findtext("setname", "")
            if setname not in expected:
                continue
            seen.add(setname)
            self.assertEqual(root.findtext("rbf"), "Arcade-SegaSystem32Multi")
            buttons = root.find("buttons")
            self.assertIsNotNone(buttons, path.name)
            names, count = expected[setname]
            self.assertEqual(buttons.attrib.get("names"), names, path.name)
            self.assertEqual(buttons.attrib.get("count"), count, path.name)
        self.assertEqual(seen, set(expected))


if __name__ == "__main__":
    unittest.main()
