"""Run Holosseum's sound ROM through the production T80/JT12/RF5C68 chain."""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

from verif.sprite_replay.capture_holo import REPO_ROOT, _run, _tool


def _jt12_sources() -> list[Path]:
    directory = REPO_ROOT / "rtl/audio/jt12"
    sources: list[Path] = []
    for line in (directory / "jt12.qip").read_text(encoding="utf-8").splitlines():
        match = re.search(r'"([^"]+)"', line)
        if match:
            sources.append(directory / match.group(1))
    if not sources:
        raise RuntimeError("JT12 QIP contains no Verilog sources")
    return sources


def run_trace(
    *,
    sound_rom: Path,
    output: Path,
    cycles: int,
    model_sim_bin: Path | None,
    cache_sets: int = 4,
) -> str:
    if not sound_rom.is_file():
        raise ValueError(f"missing Holosseum sound image {sound_rom}")
    if cycles < 1:
        raise ValueError("cycles must be positive")
    if cache_sets < 1 or cache_sets & (cache_sets - 1):
        raise ValueError("cache sets must be a positive power of two")

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="s32-holo-soundsys-") as temporary:
        work = Path(temporary)
        library = work / "work"
        vlib = _tool("vlib", model_sim_bin)
        vcom = _tool("vcom", model_sim_bin)
        vlog = _tool("vlog", model_sim_bin)
        vsim = _tool("vsim", model_sim_bin)
        _run([vlib, str(library)], work, "vlib Holo sound system")
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
        _run(
            [
                vlog,
                "-sv",
                "-work",
                str(library),
                *map(
                    str,
                    [
                        REPO_ROOT / "rtl/s32_pkg.sv",
                        REPO_ROOT / "rtl/video/s32_big_dpram.sv",
                        REPO_ROOT / "rtl/audio/s32_rf5c68.sv",
                        REPO_ROOT / "rtl/audio/s32_audio_mix.sv",
                        *_jt12_sources(),
                        REPO_ROOT / "rtl/audio/s32_soundsys.sv",
                        REPO_ROOT / "verif/common/tb_soundsys_realrom.sv",
                    ],
                ),
            ],
            work,
            "vlog production Holo sound system",
        )
        transcript = _run(
            [
                vsim,
                "-c",
                "-lib",
                str(library),
                "tb_soundsys_realrom",
                f"-gZROM_CACHE_SETS={cache_sets}",
                f"+ROM={sound_rom.resolve().as_posix()}",
                f"+CYCLES={cycles}",
                "-do",
                "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; "
                "run -all; quit -f",
            ],
            work,
            "vsim production Holo sound system",
            progress_markers=(
                "SOUNDSYS REALROM prerelease",
                "SOUNDSYS REALROM activity",
                "SOUNDSYS REALROM writes",
                "SOUNDSYS REALROM PASS",
            ),
        )

    if "SOUNDSYS REALROM PASS" not in transcript:
        raise RuntimeError("production Holo sound-system trace did not pass")
    (output / "trace.log").write_text(transcript, encoding="utf-8")
    return transcript


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sound-rom",
        type=Path,
        default=REPO_ROOT / "roms/sim/holo/soundcpu.hex",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "roms/audio_trace/holo-soundsys",
    )
    parser.add_argument("--cycles", type=int, default=5_000_000)
    parser.add_argument("--cache-sets", type=int, default=4)
    parser.add_argument("--modelsim-bin", type=Path)
    args = parser.parse_args(argv)
    try:
        run_trace(
            sound_rom=args.sound_rom.resolve(),
            output=args.output.resolve(),
            cycles=args.cycles,
            cache_sets=args.cache_sets,
            model_sim_bin=args.modelsim_bin,
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"HOLO SOUNDSYS TRACE: FAIL: {exc}", file=sys.stderr)
        return 1
    print("HOLO SOUNDSYS TRACE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
