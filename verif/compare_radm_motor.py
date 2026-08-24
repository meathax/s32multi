#!/usr/bin/env python3
"""Bind Rad Mobile's motor-mailbox RTL closure to the pinned MAME gap."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rtl_events(path: Path) -> list[str]:
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("[radm-motor]") or line.startswith("[retrycnt]"):
            events.append(line)
    return events


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mame-trace", type=Path, required=True)
    parser.add_argument("--mame-trace-b", type=Path, required=True)
    parser.add_argument("--mame-source", type=Path, required=True)
    parser.add_argument("--rtl-before", type=Path, required=True)
    parser.add_argument("--rtl-after-a", type=Path, required=True)
    parser.add_argument("--rtl-after-b", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()

    mame_rows = [json.loads(row) for row in args.mame_trace.read_text(encoding="utf-8").splitlines() if row.strip()]
    mame_deterministic = args.mame_trace.read_bytes() == args.mame_trace_b.read_bytes()
    source = args.mame_source.read_text(encoding="utf-8", errors="replace")
    before = rtl_events(args.rtl_before)
    after_a = rtl_events(args.rtl_after_a)
    after_b = rtl_events(args.rtl_after_b)

    mame_gap = "Motors aren't hooked up, as the board isn't emulated" in source
    mame_complete = bool(mame_rows) and mame_rows[-1].get("event") == "final"
    before_success = any("SUCCESS pc=068243" in row for row in before)
    after_success = any("SUCCESS pc=068243 count=1" in row for row in after_a)
    c008_response = any(re.search(r"rd 88\(Cc08\)=02$", row) for row in after_a)
    deterministic = after_a == after_b

    passed = all((mame_gap, mame_complete, mame_deterministic,
                  not before_success, after_success,
                  c008_response, deterministic))
    receipt = {
        "schema": "s32-radm-motor-comparator-v1",
        "status": "REFERENCE_GAP_RTL_CLOSED" if passed else "FAILED",
        "passed": passed,
        "reference": {
            "lane": "MAME",
            "trace": str(args.mame_trace),
            "trace_sha256": sha256(args.mame_trace),
            "repeat_trace": str(args.mame_trace_b),
            "repeat_trace_sha256": sha256(args.mame_trace_b),
            "independently_deterministic": mame_deterministic,
            "source": str(args.mame_source),
            "source_sha256": sha256(args.mame_source),
            "capture_complete": mame_complete,
            "known_gap_confirmed": mame_gap,
            "note": "Pinned MAME does not emulate the 837-7753 moving controller, so motor-response equivalence is unavailable.",
        },
        "rtl": {
            "before": str(args.rtl_before),
            "before_sha256": sha256(args.rtl_before),
            "after_a": str(args.rtl_after_a),
            "after_a_sha256": sha256(args.rtl_after_a),
            "after_b": str(args.rtl_after_b),
            "after_b_sha256": sha256(args.rtl_after_b),
            "normalized_events_sha256": hashlib.sha256("\n".join(after_a).encode()).hexdigest(),
            "independently_deterministic": deterministic,
        },
        "active_divergence": {
            "domain": "radm_motor_mailbox",
            "old_boundary": "PC 0x068236 re-entered; PC 0x068243 absent",
            "new_boundary": "C008=0x02 read; PC 0x068243 reached once; PC 0x068251 reached",
            "old_divergence_absent": not before_success and after_success,
            "matching_prefix_advanced": after_success,
        },
        "checks": {
            "before_did_not_reach_success": not before_success,
            "after_reached_success": after_success,
            "after_read_controller_response": c008_response,
            "repeat_events_match": deterministic,
        },
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
