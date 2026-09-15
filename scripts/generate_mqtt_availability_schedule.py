#!/usr/bin/env python3
"""Generate deterministic fixed-DAR MQTT subscriber outage schedules.

Sampling deliberately uses the PCG-XSH-RR 32-bit algorithm implemented below,
rather than Python's version-dependent ``random`` module.  Each draw is a
uniform integer number of milliseconds in the inclusive interval
``[5_000, cycle_ms - off_ms - 5_000]``.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path


VALID_DARS = (1.0, 0.8, 0.6, 0.4, 0.2)
FIELDS = (
    "subscriber_index",
    "cycle_index",
    "cycle_start_s",
    "off_start_s",
    "off_end_s",
    "off_duration_s",
)


class Pcg32:
    """Small, fully specified PCG32 generator with unbiased bounded draws."""

    MASK64 = (1 << 64) - 1
    MULT = 6364136223846793005

    def __init__(self, seed: int) -> None:
        self.state = 0
        self.inc = ((seed << 1) | 1) & self.MASK64
        self.next_u32()
        self.state = (self.state + (seed & self.MASK64)) & self.MASK64
        self.next_u32()

    def next_u32(self) -> int:
        old = self.state
        self.state = (old * self.MULT + self.inc) & self.MASK64
        xorshifted = (((old >> 18) ^ old) >> 27) & 0xFFFFFFFF
        rot = old >> 59
        return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & 0xFFFFFFFF

    def bounded(self, bound: int) -> int:
        if not 0 < bound <= (1 << 32):
            raise ValueError("PCG32 bound must be in 1..2^32")
        threshold = ((1 << 32) - bound) % bound
        while True:
            value = self.next_u32()
            if value >= threshold:
                return value % bound


def canonical_dar(value: float) -> float:
    for allowed in VALID_DARS:
        if math.isclose(value, allowed, abs_tol=1e-9):
            return allowed
    raise ValueError(f"DAR must be one of {', '.join(map(str, VALID_DARS))}")


def generate(subscribers: int, cycles: int, cycle_secs: int, dar: float, seed: int):
    if subscribers <= 0 or cycles <= 0 or cycle_secs <= 0:
        raise ValueError("subscribers, cycles, and cycle-secs must be positive")
    dar = canonical_dar(dar)
    cycle_ms = cycle_secs * 1000
    off_ms = round(cycle_ms * (1.0 - dar))
    rows: list[dict[str, str | int]] = []
    rng = Pcg32(seed)
    if off_ms:
        # Production cycles retain the specified five-second boundary. For the
        # documented short integration tests, scale it to half the online time.
        boundary_ms = min(5_000, (cycle_ms - off_ms) // 2)
        low_ms = boundary_ms
        high_ms = cycle_ms - off_ms - boundary_ms
        if high_ms < low_ms:
            raise ValueError("cycle is too short to retain five online seconds at both boundaries")
        for subscriber in range(subscribers):
            for cycle in range(cycles):
                relative_start_ms = low_ms + rng.bounded(high_ms - low_ms + 1)
                cycle_start_ms = cycle * cycle_ms
                off_start_ms = cycle_start_ms + relative_start_ms
                rows.append(
                    {
                        "subscriber_index": subscriber,
                        "cycle_index": cycle,
                        "cycle_start_s": f"{cycle_start_ms / 1000:.3f}",
                        "off_start_s": f"{off_start_ms / 1000:.3f}",
                        "off_end_s": f"{(off_start_ms + off_ms) / 1000:.3f}",
                        "off_duration_s": f"{off_ms / 1000:.3f}",
                    }
                )
    rows.sort(key=lambda row: (float(row["off_start_s"]), int(row["subscriber_index"])))
    validate_rows(rows, subscribers, cycles, cycle_secs, dar)
    return rows


def validate_rows(rows, subscribers: int, cycles: int, cycle_secs: int, dar: float) -> None:
    dar = canonical_dar(dar)
    if dar == 1.0:
        if rows:
            raise ValueError("DAR 1.0 schedule must not contain outages")
        return
    expected = subscribers * cycles
    if len(rows) != expected:
        raise ValueError(f"expected {expected} outage rows, found {len(rows)}")
    seen = set()
    expected_off = cycle_secs * (1.0 - dar)
    for row in rows:
        subscriber = int(row["subscriber_index"])
        cycle = int(row["cycle_index"])
        cycle_start = float(row["cycle_start_s"])
        start = float(row["off_start_s"])
        end = float(row["off_end_s"])
        duration = float(row["off_duration_s"])
        if not 0 <= subscriber < subscribers or not 0 <= cycle < cycles:
            raise ValueError("subscriber or cycle index out of range")
        if (subscriber, cycle) in seen:
            raise ValueError("duplicate subscriber/cycle outage")
        seen.add((subscriber, cycle))
        if not math.isclose(cycle_start, cycle * cycle_secs, abs_tol=0.0005):
            raise ValueError("incorrect cycle_start_s")
        boundary = min(5.0, cycle_secs * dar / 2.0)
        if start < cycle_start + boundary or end > cycle_start + cycle_secs - boundary:
            raise ValueError("outage violates five-second online boundary")
        if not math.isclose(end - start, duration, abs_tol=0.0005):
            raise ValueError("outage duration does not match its endpoints")
        if not math.isclose(duration, expected_off, abs_tol=0.0005):
            raise ValueError("outage duration does not match requested DAR")


def write_schedule(path: Path, rows, metadata: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_suffix(".sha256").write_text(
        f"{digest}  {path.name}\n", encoding="utf-8"
    )
    metadata.update({"schedule_sha256": digest, "outage_rows": len(rows)})
    path.with_suffix(".metadata.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscribers", type=int, required=True)
    parser.add_argument("--cycles", type=int, required=True)
    parser.add_argument("--cycle-secs", type=int, required=True)
    parser.add_argument("--dar", type=float, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    dar = canonical_dar(args.dar)
    rows = generate(args.subscribers, args.cycles, args.cycle_secs, dar, args.seed)
    write_schedule(
        args.out,
        rows,
        {
            "format_version": 1,
            "subscribers": args.subscribers,
            "cycles": args.cycles,
            "cycle_secs": args.cycle_secs,
            "dar": dar,
            "seed": args.seed,
            "prng": "PCG-XSH-RR 32 (64-bit state), stream=(seed<<1)|1",
            "sampling": "unbiased inclusive integer milliseconds",
        },
    )
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
