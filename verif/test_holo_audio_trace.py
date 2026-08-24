import unittest

from verif.holo_audio_trace import parse_sound_frames


class HoloAudioTraceTests(unittest.TestCase):
    def test_parse_sound_frames(self) -> None:
        transcript = """\
# frame 0: pc=0006008c halted=0
#    snd: rom=0 op=0 bank=0/0(000) fm=0/0 rf=0/0 irqctl=0 audio=0/0 x=0
# frame 1: pc=000604e8 halted=0
#    snd: rom=15659 op=130470 bank=1/2(143) fm=3/4 rf=5/6 irqctl=7 audio=-64/128 x=0
"""
        self.assertEqual(
            parse_sound_frames(transcript),
            [
                {
                    "rom": 0,
                    "opcodes": 0,
                    "bank_lo": 0,
                    "bank_hi": 0,
                    "bank": 0,
                    "fm1": 0,
                    "fm2": 0,
                    "rf_regs": 0,
                    "rf_ram": 0,
                    "irq_ctl": 0,
                    "audio_l": 0,
                    "audio_r": 0,
                    "audio_x": 0,
                    "frame": 0,
                },
                {
                    "rom": 15659,
                    "opcodes": 130470,
                    "bank_lo": 1,
                    "bank_hi": 2,
                    "bank": 0x143,
                    "fm1": 3,
                    "fm2": 4,
                    "rf_regs": 5,
                    "rf_ram": 6,
                    "irq_ctl": 7,
                    "audio_l": -64,
                    "audio_r": 128,
                    "audio_x": 0,
                    "frame": 1,
                },
            ],
        )


if __name__ == "__main__":
    unittest.main()
