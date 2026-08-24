#!/usr/bin/env python3
"""Fail fast instead of independently qualifying an unsafe/stale RBF."""

from __future__ import annotations

import sys


def main() -> int:
    print(
        "ERROR: tools/qualify_build.py is disabled. This legacy qualifier does "
        "not implement the locked input-manifest and exact stage-chain gates. "
        r"Use set QUARTUS_ROOT=D:\Q17 then tools\build-s32.bat; "
        "deployment rechecks tools/report-quartus.ps1.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
