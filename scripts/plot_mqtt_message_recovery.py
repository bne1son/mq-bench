#!/usr/bin/env python3
"""Plot validated MQTT message-recovery experiment results."""

from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


COLORS = {
    "q0_clean": "#6c757d",
    "q1_clean": "#d95f02",
    "q1_persistent": "#1b9e77",
}
LABELS = {
    "q0_clean": "QoS 0, clean",
    "q1_clean": "QoS 1, clean",
    "q1_persistent": "QoS 1, persistent",
}


def read_csv(path: Path):
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def numeric(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def finish(fig, out_dir: Path, stem: str):
    fig.tight_layout()
    for suffix in ("png", "pdf"):
        fig.savefig(out_dir / f"{stem}.{suffix}", dpi=180, bbox_inches="tight")
    plt.close(fig)


def metric_vs_dar(rows, metric, ylabel, stem, out_dir, percentage=False):
    fig, ax = plt.subplots(figsize=(7.2, 4.5))
    for mode in LABELS:
        points = defaultdict(list)
        for row in rows:
            if row["mode"] == mode:
                value = numeric(row.get(metric))
                if value is not None:
                    points[float(row["dar"])].append(value * (100 if percentage else 1))
        if not points:
            continue
        for dar, values in points.items():
            ax.scatter([dar] * len(values), values, color=COLORS[mode], alpha=.55, s=24)
        xs = sorted(points)
        means = [sum(points[x]) / len(points[x]) for x in xs]
        ax.plot(xs, means, marker="o", color=COLORS[mode], label=LABELS[mode])
    ax.set_xlim(.18, 1.02)
    ax.set_xticks([.2, .4, .6, .8, 1.0])
    ax.set_xlabel("Device Availability Ratio (DAR)")
    ax.set_ylabel(ylabel)
    ax.grid(alpha=.25)
    if ax.get_legend_handles_labels()[0]:
        ax.legend()
    finish(fig, out_dir, stem)


def plot_prg(rows, out_dir):
    keyed = {(row["mode"], row["dar"], row["seed"]): row for row in rows}
    fig, ax = plt.subplots(figsize=(7.2, 4.5))
    for comparator, color, label in [
        ("q1_clean", "#7570b3", "PRG vs QoS 1 clean"),
        ("q0_clean", "#e7298a", "PRG vs QoS 0 clean"),
    ]:
        points = defaultdict(list)
        for (_mode, dar, seed), persistent in keyed.items():
            if _mode != "q1_persistent":
                continue
            control = keyed.get((comparator, dar, seed))
            if control:
                points[float(dar)].append(
                    100 * (float(control["miss_rate"]) - float(persistent["miss_rate"]))
                )
        for dar, values in points.items():
            ax.scatter([dar] * len(values), values, color=color, alpha=.55)
        xs = sorted(points)
        ax.plot(xs, [sum(points[x]) / len(points[x]) for x in xs], marker="o", color=color, label=label)
    ax.axhline(0, color="black", linewidth=.8)
    ax.set_xlim(.18, 1.02)
    ax.set_xticks([.2, .4, .6, .8, 1.0])
    ax.set_xlabel("Device Availability Ratio (DAR)")
    ax.set_ylabel("Persistence Recovery Gain (percentage points)")
    ax.grid(alpha=.25)
    if ax.get_legend_handles_labels()[0]:
        ax.legend()
    finish(fig, out_dir, "persistence_recovery_gain_vs_dar")


def plot_timeseries(results_root: Path, metric: str, ylabel: str, stem: str, out_dir: Path):
    grouped = defaultdict(lambda: defaultdict(list))
    for path in sorted((results_root / "raw_data").glob("*/dar_timeseries.csv")):
        for row in read_csv(path):
            value = numeric(row.get(metric))
            if value is not None:
                grouped[(row["mode"], float(row["dar"]))][int(float(row["elapsed_s"]))].append(value)
    fig, ax = plt.subplots(figsize=(8, 4.7))
    for (mode, dar), seconds in sorted(grouped.items()):
        xs = sorted(seconds)
        ys = [sum(seconds[x]) / len(seconds[x]) for x in xs]
        ax.plot(xs, ys, color=COLORS[mode], alpha=.35 + .55 * dar, linewidth=1,
                label=f"{LABELS[mode]}, DAR={dar:.1f}")
    ax.axvline(60, color="black", linestyle="--", linewidth=.8)
    ax.axvline(360, color="black", linestyle="--", linewidth=.8)
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel(ylabel)
    ax.grid(alpha=.2)
    if grouped:
        ax.legend(fontsize=7, ncol=3)
    finish(fig, out_dir, stem)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path)
    args = parser.parse_args()
    out_dir = args.out_dir or args.results_root / "plots"
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = [
        row for row in read_csv(args.results_root / "summary.csv")
        if row.get("valid", "").lower() == "true" and row.get("run_kind", "measured") != "pilot"
    ]
    if not rows:
        raise SystemExit("no valid measured rows to plot")

    metric_vs_dar(rows, "miss_rate", "Miss rate (%)", "miss_rate_vs_dar", out_dir, True)
    plot_prg(rows, out_dir)
    metric_vs_dar(rows, "eventual_delivery_ratio", "Eventual delivery ratio (%)",
                  "eventual_delivery_ratio_vs_dar", out_dir, True)
    metric_vs_dar(rows, "recovery_latency_p95_ms", "Offline recovery latency p95 (ms)",
                  "recovery_latency_vs_dar", out_dir)
    metric_vs_dar(rows, "duplicate_ratio", "Duplicate ratio (%)",
                  "duplicate_ratio_vs_dar", out_dir, True)
    metric_vs_dar(rows, "broker_cpu_mean_pct", "Broker CPU (%)",
                  "broker_cpu_vs_dar", out_dir)
    metric_vs_dar(rows, "broker_memory_mean_pct", "Broker memory (%)",
                  "broker_memory_vs_dar", out_dir)
    plot_timeseries(args.results_root, "online_subscribers", "Online subscribers",
                    "online_subscribers_vs_time", out_dir)
    plot_timeseries(args.results_root, "delivery_throughput", "Deliveries/s",
                    "delivery_throughput_vs_time", out_dir)
    plot_timeseries(args.results_root, "estimated_backlog", "Estimated backlog (messages)",
                    "backlog_vs_time", out_dir)

    stems = [
        "miss_rate_vs_dar", "persistence_recovery_gain_vs_dar",
        "eventual_delivery_ratio_vs_dar", "online_subscribers_vs_time",
        "delivery_throughput_vs_time", "backlog_vs_time",
        "recovery_latency_vs_dar", "duplicate_ratio_vs_dar",
        "broker_cpu_vs_dar", "broker_memory_vs_dar",
    ]
    gallery = ["# MQTT Message Recovery Plots", ""]
    for stem in stems:
        gallery.extend([f"## {stem.replace('_', ' ').title()}", "", f"![{stem}]({stem}.png)", ""])
    (out_dir / "README.md").write_text("\n".join(gallery), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
