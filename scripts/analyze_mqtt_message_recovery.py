#!/usr/bin/env python3
"""Validate and analyze one MQTT message-recovery run directory."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


MODES = {"q0_clean", "q1_clean", "q1_persistent"}


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def percentile(values: list[float], probability: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    fraction = position - low
    return ordered[low] * (1 - fraction) + ordered[high] * fraction


def bool_value(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes"}


def snapshot_delta(path: Path, start_s: float, end_s: float) -> tuple[int, int]:
    rows = read_csv(path)
    points = sorted(
        (float(row["timestamp"]), int(row["sent_count"]), int(row["error_count"]))
        for row in rows
    )
    if len(points) < 2:
        raise ValueError(f"{path.name} has fewer than two snapshots")

    def at_or_before(target: float):
        eligible = [point for point in points if point[0] <= target]
        return eligible[-1] if eligible else points[0]

    start = at_or_before(start_s)
    end = at_or_before(end_s)
    if end[0] <= start[0]:
        raise ValueError(f"{path.name} does not span the measurement interval")
    return max(0, end[1] - start[1]), max(0, end[2] - start[2])


def validate_schedule(
    rows: list[dict[str, str]], subscribers: int, cycles: int, cycle_secs: float, dar: float
) -> list[str]:
    reasons: list[str] = []
    expected_rows = 0 if math.isclose(dar, 1.0) else subscribers * cycles
    if len(rows) != expected_rows:
        reasons.append(f"schedule_rows:{len(rows)}!=expected:{expected_rows}")
    seen = set()
    for row in rows:
        try:
            subscriber = int(row["subscriber_index"])
            cycle = int(row["cycle_index"])
            cycle_start = float(row["cycle_start_s"])
            start = float(row["off_start_s"])
            end = float(row["off_end_s"])
            duration = float(row["off_duration_s"])
        except (KeyError, ValueError) as error:
            reasons.append(f"malformed_schedule:{error}")
            continue
        identity = (subscriber, cycle)
        if identity in seen:
            reasons.append(f"duplicate_schedule_row:{subscriber}:{cycle}")
        seen.add(identity)
        if not 0 <= subscriber < subscribers or not 0 <= cycle < cycles:
            reasons.append(f"schedule_index_out_of_range:{subscriber}:{cycle}")
        expected_start = cycle * cycle_secs
        expected_off = cycle_secs * (1.0 - dar)
        if abs(cycle_start - expected_start) > 0.001:
            reasons.append(f"cycle_start_mismatch:{subscriber}:{cycle}")
        boundary = min(5.0, cycle_secs * dar / 2.0)
        if start < expected_start + boundary - 0.001 or end > expected_start + cycle_secs - boundary + 0.001:
            reasons.append(f"schedule_boundary_violation:{subscriber}:{cycle}")
        if abs(end - start - duration) > 0.001 or abs(duration - expected_off) > 0.001:
            reasons.append(f"schedule_duration_mismatch:{subscriber}:{cycle}")
    return reasons


def event_state(
    events: list[dict[str, str]], subscribers: int, cycles: int, persistent: bool
):
    reasons: list[str] = []
    grouped: dict[int, list[dict[str, str]]] = defaultdict(list)
    for event in events:
        try:
            grouped[int(event["subscriber_index"])].append(event)
        except (KeyError, ValueError):
            reasons.append("malformed_subscriber_event")
    intervals: dict[int, list[tuple[float, float, int]]] = defaultdict(list)
    actual_dars: list[float] = []
    for subscriber in range(subscribers):
        rows = sorted(grouped.get(subscriber, []), key=lambda row: float(row["elapsed_s"]))
        counts = Counter(row.get("event", "") for row in rows)
        for required in ("initial_connect", "forced_online_for_drain", "final_disconnect"):
            if counts[required] != 1:
                reasons.append(f"event_count:{subscriber}:{required}:{counts[required]}")
        if cycles and counts["power_off"] != cycles:
            reasons.append(f"event_count:{subscriber}:power_off:{counts['power_off']}")
        if cycles and counts["reconnect_complete"] != cycles:
            reasons.append(f"event_count:{subscriber}:reconnect_complete:{counts['reconnect_complete']}")
        initial = [row for row in rows if row.get("event") == "initial_connect"]
        if initial and bool_value(initial[0].get("session_present", "false")):
            reasons.append(f"initial_session_present:{subscriber}")
        offs: dict[int, float] = {}
        for row in rows:
            if row.get("status") not in {"ok", "already_online"}:
                reasons.append(
                    f"event_status:{subscriber}:{row.get('event')}:{row.get('status')}"
                )
            cycle = int(row.get("cycle_index", -1))
            elapsed = float(row["elapsed_s"])
            if row.get("event") == "power_off":
                offs[cycle] = elapsed
            elif row.get("event") == "reconnect_complete":
                expected = persistent
                if bool_value(row.get("session_present", "false")) != expected:
                    reasons.append(f"session_present_mismatch:{subscriber}:{cycle}")
                if cycle not in offs or elapsed <= offs[cycle]:
                    reasons.append(f"unpaired_reconnect:{subscriber}:{cycle}")
                else:
                    intervals[subscriber].append((offs[cycle], elapsed, cycle))
    return reasons, intervals


def analyze(run_dir: Path) -> tuple[dict, dict]:
    reasons: list[str] = []
    warnings: list[str] = []
    metadata_path = run_dir / "metadata.json"
    if not metadata_path.exists():
        raise ValueError("missing metadata.json")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    required = [
        "run_id", "mode", "dar", "seed", "subscribers", "cycles", "cycle_secs",
        "warmup_secs", "final_drain_secs", "subscriber_start_ns", "publisher_count",
        "topic_ranges", "schedule_sha256",
    ]
    for key in required:
        if key not in metadata:
            reasons.append(f"missing_metadata:{key}")
    if reasons:
        return {}, {"valid": False, "reasons": reasons, "warnings": warnings}

    mode = metadata["mode"]
    dar = float(metadata["dar"])
    subscribers = int(metadata["subscribers"])
    cycles = int(metadata["cycles"])
    cycle_secs = float(metadata["cycle_secs"])
    warmup = float(metadata["warmup_secs"])
    drain = float(metadata["final_drain_secs"])
    start_ns = int(metadata["subscriber_start_ns"])
    measurement_start_ns = start_ns + round(warmup * 1e9)
    measurement_end_ns = measurement_start_ns + round(cycles * cycle_secs * 1e9)
    drain_end_ns = measurement_end_ns + round(drain * 1e9)
    if mode not in MODES:
        reasons.append(f"unknown_mode:{mode}")

    schedule_path = run_dir / "schedule.csv"
    events_path = run_dir / "subscriber_events.csv"
    trace_path = run_dir / "receive_trace.csv"
    for path in (schedule_path, events_path, trace_path):
        if not path.exists():
            reasons.append(f"missing_file:{path.name}")
    if reasons:
        return {}, {"valid": False, "reasons": reasons, "warnings": warnings}

    digest = hashlib.sha256(schedule_path.read_bytes()).hexdigest()
    if digest != metadata["schedule_sha256"]:
        reasons.append("schedule_checksum_mismatch")
    schedule_rows = read_csv(schedule_path)
    reasons.extend(validate_schedule(schedule_rows, subscribers, cycles, cycle_secs, dar))
    schedule_by_key = {
        (int(row["subscriber_index"]), int(row["cycle_index"])): row for row in schedule_rows
    }

    ranges = metadata["topic_ranges"]
    covered: list[int] = []
    for item in ranges:
        covered.extend(range(int(item["start"]), int(item["start"]) + int(item["count"])))
    if len(ranges) != int(metadata["publisher_count"]):
        reasons.append("publisher_range_count_mismatch")
    if sorted(covered) != list(range(subscribers)) or len(set(covered)) != len(covered):
        reasons.append("publisher_ranges_do_not_partition_topics")

    events = read_csv(events_path)
    persistent = mode == "q1_persistent"
    event_reasons, intervals = event_state(
        events, subscribers, 0 if math.isclose(dar, 1.0) else cycles, persistent
    )
    reasons.extend(event_reasons)
    event_by_sub = defaultdict(list)
    for row in events:
        event_by_sub[int(row["subscriber_index"])].append(row)
        event_name = row.get("event")
        subscriber = int(row["subscriber_index"])
        cycle = int(row.get("cycle_index", -1))
        elapsed = float(row["elapsed_s"])
        if event_name == "initial_connect" and elapsed > warmup:
            reasons.append(f"initial_connect_after_warmup:{subscriber}:{elapsed:.6f}")
        if event_name == "power_off" and elapsed < warmup:
            reasons.append(f"warmup_outage:{subscriber}:{cycle}")
        if event_name in {"power_off", "reconnect_start"} and cycle >= 0:
            scheduled = schedule_by_key.get((subscriber, cycle))
            if scheduled:
                requested = warmup + float(
                    scheduled["off_start_s" if event_name == "power_off" else "off_end_s"]
                )
                if abs(elapsed - requested) > 2.0:
                    reasons.append(
                        f"event_late:{subscriber}:{cycle}:{event_name}:{elapsed-requested:.6f}"
                    )
        if event_name == "forced_online_for_drain":
            expected = warmup + cycles * cycle_secs
            if abs(elapsed - expected) > 2.0:
                reasons.append(f"drain_barrier_late:{subscriber}:{elapsed-expected:.6f}")

    measurement_start_s = measurement_start_ns / 1e9
    measurement_end_s = measurement_end_ns / 1e9
    published = 0
    send_errors = 0
    published_by_cycle = [0] * cycles
    for publisher in range(int(metadata["publisher_count"])):
        path = run_dir / f"pub_{publisher}.csv"
        if not path.exists():
            reasons.append(f"missing_file:{path.name}")
            continue
        try:
            sent, errors = snapshot_delta(path, measurement_start_s, measurement_end_s)
            published += sent
            send_errors += errors
            for cycle in range(cycles):
                cycle_start = measurement_start_s + cycle * cycle_secs
                cycle_sent, _ = snapshot_delta(path, cycle_start, cycle_start + cycle_secs)
                published_by_cycle[cycle] += cycle_sent
        except (KeyError, ValueError) as error:
            reasons.append(f"publisher_snapshot:{publisher}:{error}")
    if published <= 0:
        reasons.append("no_primary_cohort_publishes")
    if send_errors:
        reasons.append(f"publisher_send_errors:{send_errors}")
    for child, exit_code in metadata.get("exit_codes", {}).items():
        if int(exit_code) != 0:
            reasons.append(f"child_exit:{child}:{exit_code}")
    for flag, active in metadata.get("failure_flags", {}).items():
        if active:
            reasons.append(f"failure_flag:{flag}")

    unique: dict[tuple[int, int], dict[str, str]] = {}
    total_primary_receipts = 0
    per_second_receipts: Counter[int] = Counter()
    malformed_trace = 0
    for row in read_csv(trace_path):
        try:
            send_ns = int(row["send_timestamp_ns"])
            receive_ns = int(row["receive_timestamp_ns"])
            topic = int(row["topic_index"])
            sequence = int(row["sequence"])
        except (KeyError, ValueError):
            malformed_trace += 1
            continue
        if measurement_start_ns <= send_ns < measurement_end_ns and receive_ns <= drain_end_ns:
            total_primary_receipts += 1
            identity = (topic, sequence)
            if identity not in unique or receive_ns < int(unique[identity]["receive_timestamp_ns"]):
                unique[identity] = row
    if malformed_trace:
        reasons.append(f"malformed_trace_rows:{malformed_trace}")
    delivered = len(unique)
    for row in unique.values():
        elapsed_second = max(0, int((int(row["receive_timestamp_ns"]) - start_ns) / 1e9))
        per_second_receipts[elapsed_second] += 1
    duplicates = max(0, total_primary_receipts - delivered)
    if published and delivered > published:
        reasons.append(f"unique_receipts_exceed_publishes:{delivered}>{published}")

    offline_latencies_ms: list[float] = []
    recovered_same = recovered_later = recovered_drain = 0
    for (topic, _sequence), row in unique.items():
        send_elapsed = (int(row["send_timestamp_ns"]) - start_ns) / 1e9
        receive_ns = int(row["receive_timestamp_ns"])
        for off, reconnect, cycle in intervals.get(topic, []):
            if off <= send_elapsed < reconnect:
                reconnect_ns = start_ns + round(reconnect * 1e9)
                offline_latencies_ms.append(max(0, receive_ns - reconnect_ns) / 1e6)
                receive_elapsed = (receive_ns - start_ns) / 1e9
                if receive_elapsed >= warmup + cycles * cycle_secs:
                    recovered_drain += 1
                elif int((receive_elapsed - warmup) // cycle_secs) == cycle:
                    recovered_same += 1
                else:
                    recovered_later += 1
                break

    actual_dars = []
    measurement_start_elapsed = warmup
    measurement_end_elapsed = warmup + cycles * cycle_secs
    for subscriber in range(subscribers):
        offline = 0.0
        for start, end, _cycle in intervals.get(subscriber, []):
            offline += max(
                0.0,
                min(end, measurement_end_elapsed) - max(start, measurement_start_elapsed),
            )
        actual_dars.append(1.0 - offline / (cycles * cycle_secs))
    median_actual_dar = statistics.median(actual_dars) if actual_dars else math.nan
    if abs(median_actual_dar - dar) > 0.01:
        reasons.append(f"median_actual_dar:{median_actual_dar:.6f}:requested:{dar:.6f}")

    eventual = delivered / published if published else math.nan
    miss_rate = 1.0 - eventual if published else math.nan
    duplicate_ratio = duplicates / total_primary_receipts if total_primary_receipts else 0.0
    summary = {
        "run_id": metadata["run_id"],
        "run_kind": metadata.get("run_kind", "measured"),
        "mode": mode,
        "dar": f"{dar:.2f}",
        "seed": metadata["seed"],
        "published_primary": published,
        "unique_delivered_primary": delivered,
        "total_primary_receipts": total_primary_receipts,
        "duplicates": duplicates,
        "duplicate_ratio": f"{duplicate_ratio:.9f}",
        "eventual_delivery_ratio": f"{eventual:.9f}" if math.isfinite(eventual) else "",
        "miss_rate": f"{miss_rate:.9f}" if math.isfinite(miss_rate) else "",
        "requested_dar": f"{dar:.6f}",
        "median_actual_dar": f"{median_actual_dar:.6f}",
        "mean_actual_dar": f"{statistics.mean(actual_dars):.6f}",
        "max_abs_dar_error": f"{max(abs(value - dar) for value in actual_dars):.6f}",
        "recovery_latency_p50_ms": f"{percentile(offline_latencies_ms, .50):.6f}" if offline_latencies_ms else "",
        "recovery_latency_p95_ms": f"{percentile(offline_latencies_ms, .95):.6f}" if offline_latencies_ms else "",
        "recovery_latency_p99_ms": f"{percentile(offline_latencies_ms, .99):.6f}" if offline_latencies_ms else "",
        "recovered_same_cycle": recovered_same,
        "recovered_later_cycle": recovered_later,
        "recovered_final_drain": recovered_drain,
        "publisher_send_errors": send_errors,
        "broker_cpu_mean_pct": "",
        "broker_memory_mean_pct": "",
        "valid": not reasons,
    }
    stats_path = run_dir / "docker_stats.csv"
    if stats_path.exists():
        cpu_values, memory_values = [], []
        for row in read_csv(stats_path):
            try:
                cpu_values.append(float(row["cpu_perc"].rstrip("%")))
                memory_values.append(float(row["mem_perc"].rstrip("%")))
            except (KeyError, ValueError):
                continue
        if cpu_values:
            summary["broker_cpu_mean_pct"] = f"{statistics.mean(cpu_values):.6f}"
        if memory_values:
            summary["broker_memory_mean_pct"] = f"{statistics.mean(memory_values):.6f}"

    cycle_rows = []
    for cycle in range(cycles):
        lower = measurement_start_ns + round(cycle * cycle_secs * 1e9)
        upper = lower + round(cycle_secs * 1e9)
        cycle_unique = {
            identity for identity, row in unique.items() if lower <= int(row["send_timestamp_ns"]) < upper
        }
        cycle_rows.append(
            {
                "run_id": metadata["run_id"],
                "mode": mode,
                "dar": f"{dar:.2f}",
                "seed": metadata["seed"],
                "cycle_index": cycle,
                "published": published_by_cycle[cycle],
                "unique_delivered_by_drain": len(cycle_unique),
                "eventual_delivery_ratio": (
                    f"{len(cycle_unique) / published_by_cycle[cycle]:.9f}"
                    if published_by_cycle[cycle]
                    else ""
                ),
                "miss_rate": (
                    f"{1.0 - len(cycle_unique) / published_by_cycle[cycle]:.9f}"
                    if published_by_cycle[cycle]
                    else ""
                ),
            }
        )

    offered_rate = float(metadata.get("aggregate_rate", 0))
    timeseries = []
    cumulative_received = 0
    for second in range(int(warmup + cycles * cycle_secs + drain) + 1):
        cumulative_received += per_second_receipts[second]
        online = subscribers
        for subscriber_intervals in intervals.values():
            if any(start <= second < end for start, end, _cycle in subscriber_intervals):
                online -= 1
        primary_elapsed = min(max(second - warmup, 0), cycles * cycle_secs)
        estimated_sent = offered_rate * primary_elapsed
        timeseries.append(
            {
                "run_id": metadata["run_id"],
                "mode": mode,
                "dar": f"{dar:.2f}",
                "seed": metadata["seed"],
                "elapsed_s": second,
                "online_subscribers": online,
                "delivery_throughput": per_second_receipts[second],
                "estimated_backlog": max(0, round(estimated_sent - cumulative_received)),
            }
        )

    write_csv(run_dir / "run_summary.csv", list(summary), [summary])
    write_csv(run_dir / "cycle_summary.csv", list(cycle_rows[0]), cycle_rows)
    write_csv(run_dir / "dar_timeseries.csv", list(timeseries[0]), timeseries)
    availability_rows = [
        {
            "run_id": metadata["run_id"],
            "mode": mode,
            "requested_dar": f"{dar:.6f}",
            "subscriber_index": subscriber,
            "actual_dar": f"{actual:.6f}",
            "dar_error": f"{actual - dar:.6f}",
        }
        for subscriber, actual in enumerate(actual_dars)
    ]
    write_csv(
        run_dir / "subscriber_availability.csv",
        list(availability_rows[0]),
        availability_rows,
    )
    validation = {
        "valid": not reasons,
        "reasons": sorted(set(reasons)),
        "warnings": warnings,
        "measurement_start_ns": measurement_start_ns,
        "measurement_end_ns": measurement_end_ns,
        "drain_end_ns": drain_end_ns,
    }
    (run_dir / "validation.json").write_text(
        json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return summary, validation


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        summary, validation = analyze(args.run_dir)
    except Exception as error:
        validation = {"valid": False, "reasons": [f"analyzer_error:{error}"], "warnings": []}
        (args.run_dir / "validation.json").write_text(
            json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(error, file=sys.stderr)
        return 2
    (args.run_dir / "validation.json").write_text(
        json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, sort_keys=True))
    return 0 if validation["valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
