"""Run a production-CPU Holosseum audio trace in the full System 32 core.

The ROM images stay under the ignored roms/ tree.  Only aggregate bus and
audio activity is written to the output directory; ROM bytes are never copied
into a result artifact.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

from verif.sprite_replay.capture_holo import REPO_ROOT, _run, _tool


SOUND_LINE = re.compile(
    r"^#\s+snd: rom=(?P<rom>\d+) op=(?P<opcodes>\d+) "
    r"bank=(?P<bank_lo>\d+)/(?P<bank_hi>\d+)\((?P<bank>[0-9a-fA-F]+)\) "
    r"fm=(?P<fm1>\d+)/(?P<fm2>\d+) "
    r"rf=(?P<rf_regs>\d+)/(?P<rf_ram>\d+) "
    r"irqctl=(?P<irq_ctl>\d+) audio=(?P<audio_l>-?\d+)/(?P<audio_r>-?\d+) "
    r"x=(?P<audio_x>\d+)$"
)


def parse_sound_frames(transcript: str) -> list[dict[str, int]]:
    """Extract cumulative sound counters from tb_core_romboot output."""
    result: list[dict[str, int]] = []
    pending_frame: int | None = None
    for raw_line in transcript.splitlines():
        line = raw_line.rstrip()
        frame_match = re.match(r"^# frame (\d+):", line)
        if frame_match:
            pending_frame = int(frame_match.group(1))
            continue
        sound_match = SOUND_LINE.match(line)
        if sound_match and pending_frame is not None:
            item = {key: int(value, 16) if key == "bank" else int(value)
                    for key, value in sound_match.groupdict().items()}
            item["frame"] = pending_frame
            result.append(item)
            pending_frame = None
    return result


def run_trace(
    *,
    image_dir: Path,
    output: Path,
    frames: int,
    model_sim_bin: Path | None,
) -> list[dict[str, int]]:
    if frames < 2:
        raise ValueError("at least two frames are required to observe CNT2 releasing the Z80")
    for name in ("maincpu.hex", "soundcpu.hex", "tiles.hex", "sprites.hex"):
        if not (image_dir / name).is_file():
            raise ValueError(f"missing Holosseum simulation image {image_dir / name}")

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="s32-holo-audio-") as temporary:
        work = Path(temporary)
        library = work / "work"
        vlib = _tool("vlib", model_sim_bin)
        vcom = _tool("vcom", model_sim_bin)
        vlog = _tool("vlog", model_sim_bin)
        vsim = _tool("vsim", model_sim_bin)
        _run([vlib, str(library)], work, "vlib Holo audio")
        _run(
            [
                vcom,
                "-2008",
                "-work",
                str(library),
                *map(
                    str,
                    [
                        REPO_ROOT / "rtl/audio/T80/T80_ALU.vhd",
                        REPO_ROOT / "rtl/audio/T80/T80_MCode.vhd",
                        REPO_ROOT / "rtl/audio/T80/T80_Reg.vhd",
                        REPO_ROOT / "rtl/audio/T80/T80.vhd",
                        REPO_ROOT / "rtl/audio/T80/T80s.vhd",
                    ],
                ),
            ],
            work,
            "vcom production T80",
        )
        sources = [
            REPO_ROOT / "rtl/s32_pkg.sv",
            REPO_ROOT / "rtl/cpu/v60/s32_v60.sv",
            REPO_ROOT / "rtl/cpu/v60/s32_v60_bus.sv",
            *sorted((REPO_ROOT / "rtl/video").glob("*.sv")),
            REPO_ROOT / "rtl/audio/s32_rf5c68.sv",
            REPO_ROOT / "rtl/audio/s32_multipcm.sv",
            REPO_ROOT / "rtl/audio/s32_audio_mix.sv",
            REPO_ROOT / "rtl/audio/s32_soundsys.sv",
            REPO_ROOT / "rtl/io/s32_io.sv",
            REPO_ROOT / "rtl/prot/s32_prot.sv",
            REPO_ROOT / "verif/common/jt12_stub.v",
            REPO_ROOT / "rtl/s32_core.sv",
            REPO_ROOT / "verif/common/tb_core_romboot.sv",
        ]
        _run(
            [
                vlog,
                "-sv",
                "+define+SIMULATION",
                "+define+S32_REAL_Z80_SIM",
                "-work",
                str(library),
                *map(str, sources),
            ],
            work,
            "vlog Holo audio",
        )
        transcript = _run(
            [
                vsim,
                "-c",
                "-lib",
                str(library),
                "tb_core_romboot",
                f"+IMG={image_dir.resolve()}",
                "+B0=0",
                "+B1=2",
                "+SBM=1",
                f"+FRAMES={frames}",
                "-do",
                "run -all; quit -f",
            ],
            work,
            "vsim Holo audio",
            progress_markers=("# frame ", "#    snd:", "# ROMBOOT DONE"),
        )

    sound_frames = parse_sound_frames(transcript)
    if "ROMBOOT DONE" not in transcript:
        raise RuntimeError("full-core trace did not reach ROMBOOT DONE")
    if len(sound_frames) != frames:
        raise RuntimeError(f"expected {frames} sound frames, found {len(sound_frames)}")
    if sound_frames[-1]["rom"] == 0 or sound_frames[-1]["opcodes"] == 0:
        raise RuntimeError("CNT2 never released the production T80")
    if any(item["audio_x"] for item in sound_frames):
        raise RuntimeError("unknown samples reached the audio outputs")

    (output / "trace.log").write_text(transcript, encoding="utf-8")
    (output / "summary.json").write_text(
        json.dumps(
            {
                "game": "holo",
                "sound_cpu": "production T80",
                "frames": sound_frames,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return sound_frames


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-dir", type=Path, default=REPO_ROOT / "roms/sim/holo")
    parser.add_argument("--output", type=Path, default=REPO_ROOT / "roms/audio_trace/holo")
    # A two-frame run is sufficient to observe the V60 CNT2 handoff and keeps
    # the production-T80 full-core gate practical under ModelSim Starter.
    parser.add_argument("--frames", type=int, default=2)
    parser.add_argument("--modelsim-bin", type=Path)
    args = parser.parse_args(argv)
    try:
        frames = run_trace(
            image_dir=args.image_dir.resolve(),
            output=args.output.resolve(),
            frames=args.frames,
            model_sim_bin=args.modelsim_bin,
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"HOLO AUDIO TRACE: FAIL: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(frames, indent=2))
    print("HOLO AUDIO TRACE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
