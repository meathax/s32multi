# Sega System 32 profile contract

This repository has exactly one universal production FPGA profile. Every change to RTL,
MRA generation, tests, build scripts, or release metadata must be routed using
this contract; do not create a new per-game Quartus revision or silently add a
game-only macro.

## Global profile routing

| Profile | Production macros | RBF | MRA parents | Hardware boundary |
|---|---|---|---|---|
| `Arcade-SegaSystem32Multi` | `S32_PROFILE_STANDARD=1`, `S32_GAME_ONLY_STD=1`, `S32_UNIVERSAL=1`, `S32_V25_HW=1` | `Arcade-SegaSystem32Multi.rbf` | all supported standard parents plus `ga2`, `arabfgt` | Standard-board peripherals and the real NEC V25 core/cache/program memories are compiled together; descriptor fields select V25 versus HLE and optional I/O/protection paths. |

The universal profile uses `rtl/s32_core.sv`; `S32_GAME_ONLY_STD` implies
`GAME_ONLY`, but retains standard-profile descriptor-selected peripherals.
`harddunk`, `orunners`, `scross`, and `titlef` families are Multi 32 and are
not supported or emitted.

## Change-routing rules

1. A common emulation or accuracy enhancement belongs in the universal RTL and
   must be valid for every descriptor. Run the universal lint/boot tests before
   considering it integrated.
2. A resource or hardware change belongs in the universal QSF and must use
   only `S32_PROFILE_STANDARD`, `S32_UNIVERSAL`, `S32_V25_HW`,
   `S32_GAME_ONLY`, or `S32_GAME_ONLY_STD` in production RTL. Descriptor fields
   select differences between games inside the profile. `S32_PROFILE_V25` is
   retired and must never be defined again.
3. Never reintroduce `S32_GA2_ONLY`, `S32_GOLDENAXE_ONLY`,
   `S32_ARABFIGHT_ONLY`, `S32_SONIC_ONLY`, or `S32_V25_GAME_ONLY` in a
   production source, QSF, MRA, or release script. Test-only feature macros
   must not alter production game routing.
4. `tools/gen_mra.py`'s `RBF_BY_PARENT` is the only source of `<rbf>`
   routing. Every supported parent resolves to `Arcade-SegaSystem32Multi`.
5. Use `tools/build-segas32.bat` for hardware builds (a thin wrapper around
   `tools/build.bat`). Preserve Quartus
   databases, obey the eight-worker Fast Fit policy, and do not build merely
   to explore source. A build requires an explicit user request.

## Quartus build isolation

Only one Quartus/RBF build may run on this machine at a time. The build
wrapper owns the machine-wide `Global\SegaS32QuartusBuild` mutex, and direct
preflight invocations reject active Quartus/Qsys compiler processes. Separate
worktrees or project copies are still required for any queued build so each
one has its own `db`, `incremental_db`, `output_files`, generated PLL/IP files,
build logs, provenance manifests, and release-staging directory. Never attach
to, delete, clean, or overwrite another build's process or generated state.

## Required validation

Source/profile routing:

```powershell
python -B -m unittest discover -s verif -p 'test_*.py'
python -B verif/check_ga2_release.py
python -B verif/check_arabianfight_release.py
python -B verif/check_holo_release.py
```

All three release checks are expected to pass.

Native HDL regression:

```powershell
& .\verif\run_regression.ps1
```

The real-V25 firmware runner must call `verilator-safe status` first and use
`verilator-safe` / `verilator-sim-safe`; never invoke an original Verilator
binary directly.

## Persistent status

The current profile matrix and evidence are recorded in `PROFILE_CONTRACT.md`.
Update that file when a hardware family, supported set, or validation gate
changes. Keep private ROMs, NVRAM, captures, generated models, and Quartus
databases local.
