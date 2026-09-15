# Plan: Make CPU and Memory Summaries More Representative

## Why We Need This

The current summary pipeline can understate broker resource use even when the raw capture is correct.

Example from `results/fanout_steady_load_20260701_223914/raw_data/summary.csv`:

- `avg_cpu_perc = 239.35`
- `max_cpu_perc = 372.60`

But the raw `docker_stats.csv` for the same run shows a long saturated region near `350%` to `372%` CPU. The gap is mostly caused by how we choose the aggregation window, not because Docker stats is obviously wrong.

Current behavior:

- CPU and memory are aggregated over a broad window derived from `sub_agg.csv`.
- The window uses fixed trimming (`--ignore-start-secs`, `--ignore-end-secs`).
- The summary reports simple averages and maxima inside that window.
- Remote collection uses `docker stats --no-stream`; local collection uses Docker stats JSON over the Docker socket.

This is good enough for rough comparison, but it is not the best representation of "real broker consumption under sustained load".

## Goals

- Make CPU numbers line up better with what we observe during the loaded part of a run.
- Make memory numbers reflect the broker's real footprint under load, not just a run-wide average diluted by ramp-up.
- Keep raw capture simple and cheap enough to run on every benchmark.
- Preserve backward compatibility for older plots and CSV readers while introducing better primary metrics.

## Non-Goals

- Replacing Docker-based collection with a full observability stack.
- Perfectly reproducing every host-level view from `htop`.
- Rewriting every benchmark script in one step.

## Main Problems In The Current Pipeline

### 1. The window is fixed, not load-aware

The current steady-state window is derived from the subscriber trace and then applied to Docker stats. This works poorly when:

- subscribers are still connecting after the window begins
- throughput is still ramping after the first nonzero deliveries
- memory is still growing toward its loaded footprint

Using `--ignore-start-secs 60 --ignore-end-secs 10` is already a better guardrail than `5/5`, but it is still a fixed approximation. Different transports and subscriber counts reach saturation at different times.

### 2. CPU is stored in a form that is easy to misread

`docker stats` reports CPU as percent of one core. `372%` means about `3.72` cores, not `372%` of the whole host.

We already derive core-count views in some plotting code, but the summary CSV still presents the raw percent as the main number.

### 3. Memory is summarized with averages that hide the loaded footprint

For steady-load fan-out runs, memory often rises over time and may stabilize late. A run-wide average is usually not the best answer to:

- "How much memory did the broker really need under load?"
- "What should I capacity-plan around?"

### 4. Local and remote collection are not identical

- Local collection uses Docker stats JSON and computes numeric fields directly.
- Remote collection parses the formatted `docker stats` CLI output.

This makes the schema less consistent and limits what memory details we can summarize later.

### 5. The aggregation logic is duplicated

Similar utilization columns appear in several orchestrators, which makes it easy for behavior to drift:

- `scripts/orchestrate_fanout_under_steady_load.sh`
- `scripts/orchestrate_fanin_under_steady_load.sh`
- `scripts/orchestrate_qos_comparison.sh`
- `scripts/orchestrate_latency_vs_payload.sh`
- `scripts/orchestrate_throughput_vs_pairs.sh`
- `scripts/orchestrate_fanout.sh`

## Proposed Metric Model

### CPU

Keep raw Docker CPU percent, but make the primary summarized metric "cores used".

Add or promote:

- `avg_cpu_cores_active`
- `p95_cpu_cores_active`
- `max_cpu_cores_active`
- `avg_cpu_pct_one_core_active` for backward compatibility
- `host_cpu_count`
- optional: `avg_cpu_pct_host_active = avg_cpu_cores_active / host_cpu_count * 100`

Why:

- "cores used" is much closer to what we mean operationally.
- It is easier to compare to `htop`.
- It makes `350%` immediately readable as `3.5` cores.

### Memory

Make bytes the primary memory metric, not percent.

Add or promote:

- `avg_mem_workingset_bytes_active`
- `p95_mem_workingset_bytes_active`
- `max_mem_workingset_bytes_active`
- `end_mem_workingset_bytes_active`
- `mem_growth_bytes_active`
- `avg_mem_pct_limit_active` only as a secondary metric

If available from Docker stats JSON, also capture:

- `mem_usage_bytes_raw`
- `mem_cache_bytes`
- `mem_rss_bytes`
- `mem_limit_bytes`

Why:

- bytes are easier to reason about than `% of limit`
- `% of limit` is misleading when the container limit is just the whole host memory
- `end` and `p95` are often more representative than a run-wide average

## Proposed Windowing Model

Replace "fixed trimmed interval only" with "fixed trimming plus active-load detection".

### Rule

The active utilization window should begin only after all of the following are true for a configurable number of consecutive samples:

- `active_connections` is at or above a threshold such as `99%` of expected subscribers
- interval delivery throughput is at or above a threshold such as `90%` of the run's plateau throughput
- optional: publisher send rate is within tolerance of the configured target

The active window should end before teardown or collapse, using both:

- the existing `ignore_end_secs` guardrail
- a drop detector for sustained throughput or connection loss

### Practical Defaults

- Keep `--ignore-start-secs` and `--ignore-end-secs` as minimum guardrails.
- Add new knobs for active-window detection:
  - `--util-active-min-consecutive`
  - `--util-active-conn-ratio`
  - `--util-active-throughput-ratio`

### Why This Helps

This preserves the user's intent in commands like:

```bash
--duration 120 --ignore-start-secs 60 --ignore-end-secs 10
```

but stops us from pretending that one fixed trim value is universally correct for every transport and subscriber count.

## Proposed Collector Changes

### 1. Unify local and remote raw schemas

Use the same raw field model for both local and remote collection.

Preferred direction:

- keep local collection on Docker stats JSON
- change remote collection to emit the same numeric fields, either by:
  - running the same JSON-based collector remotely over SSH, or
  - adding a small remote helper that fetches Docker stats JSON and prints the same CSV schema

This lets us compute the same memory variants everywhere.

### 2. Capture explicit memory components

For local JSON collection, extend the CSV to record enough raw memory fields to let us choose the right summary later.

At minimum:

- raw usage bytes
- reclaimable/cache bytes
- working-set bytes
- RSS bytes if present
- limit bytes

### 3. Record host context once per run

Capture run metadata such as:

- host CPU count
- optional memory total

This makes summary fields like "cores used" and "share of host" interpretable without guessing the machine size afterward.

## Proposed Aggregation Changes

### Phase 1: keep legacy columns, add better ones

Do not remove existing columns immediately.

Keep:

- `max_cpu_perc`
- `avg_cpu_perc`
- `max_mem_perc`
- `avg_mem_perc`
- `max_mem_used_bytes`
- `avg_mem_used_bytes`

Add new active-window columns and treat them as the preferred values in new plots and analysis.

### Phase 2: compute percentiles and end-state metrics

Move beyond avg/max only.

Recommended summary set:

- CPU: avg, p50, p95, max
- memory working set: avg, p50, p95, max, end
- memory RSS: avg, p95, end if available
- metadata: active window start, end, sample count

### Phase 3: promote the new metrics in plots

Update plotting code so the default charts use:

- CPU cores rather than raw CPU percent
- memory bytes/GB rather than memory percent
- active-window metrics rather than broad-window averages

## Implementation Shape

### Recommended Refactor

Move utilization summarization out of duplicated inline `awk` and into one shared implementation.

Preferred options:

- a shared shell helper if we keep the logic simple
- a shared Python summarizer if we want percentiles, plateau detection, and backfill support with less shell complexity

Python is the safer choice if we want:

- percentile calculations
- richer active-window logic
- easier backfills
- one implementation reused by all orchestrators

### Likely Files To Touch

- `scripts/lib.sh`
- `scripts/collect_remote_docker_stats.sh`
- `scripts/orchestrate_fanout_under_steady_load.sh`
- `scripts/orchestrate_fanin_under_steady_load.sh`
- `scripts/orchestrate_qos_comparison.sh`
- `scripts/orchestrate_latency_vs_payload.sh`
- `scripts/orchestrate_throughput_vs_pairs.sh`
- `scripts/orchestrate_fanout.sh`
- `scripts/backfill_utilization.py`
- `scripts/plot_results.py`
- `scripts/summarize_bursty_fanout.py`

## Validation Plan

### Before/After Checks

For a known run, compare:

- raw `docker_stats.csv`
- raw `sub_agg.csv`
- current summary values
- proposed active-window summary values

The new summary should better match the visibly saturated part of the run.

### Acceptance Criteria

- CPU summaries for loaded runs track the long plateau seen in raw Docker stats instead of being heavily diluted by early ramp samples.
- Memory summaries expose both typical loaded footprint and worst-case footprint.
- The same raw collector schema is produced for local and remote benchmarks.
- New columns can be backfilled from saved artifacts.
- Old consumers of `summary.csv` continue to work until we intentionally deprecate legacy fields.

## Rollout Plan

### Step 1

Implement the new raw schema and active-window summarizer for `orchestrate_fanout_under_steady_load.sh` only.

### Step 2

Validate on the 120-second steady-load runs that already use:

```bash
--ignore-start-secs 60 --ignore-end-secs 10
```

### Step 3

Backfill one or two existing result sets and compare plots and tables.

### Step 4

Roll the shared summarizer into the other orchestrators.

### Step 5

Switch default plots and analysis docs to the new metrics, while keeping the legacy columns around for compatibility.

## Recommendation

The highest-value path is:

1. keep the current collection approach
2. unify local and remote raw schemas
3. add an active-load window
4. promote CPU cores and memory bytes as the main summary metrics
5. centralize summarization in one shared implementation

This gives us a big representativeness improvement without needing to redesign the benchmark runner itself.
