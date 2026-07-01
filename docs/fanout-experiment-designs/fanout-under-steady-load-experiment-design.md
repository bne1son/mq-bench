# Fan-Out Under Steady Load Experiment Design

## Short Version

This experiment measures how well each broker sustains one-to-many replication under a controlled, steady publish workload as subscriber fan-out increases. The orchestrator now supports both dynamically scaled and fixed publisher counts.

The implemented design is a subscriber-sweep experiment:

- vary subscriber count `S`
- choose publisher mode: dynamic or fixed
- dynamic mode uses `P = max(MIN_PUBS, ceil(S / SUBS_PER_PUB))`
- fixed mode uses `P = FIXED_PUBS`
- hold per-publisher rate constant at `RATE_PER_PUB`
- compare delivered throughput, latency, loss, CPU, memory, and network usage across transports

In the default configuration:

- subscriber sweep: `500, 1000, 2000, 3000, 4000, 5000, 6000, 7000`
- publisher mode: `dynamic`
- dynamic scaling rule: `1 publisher per 100 subscribers`
- fixed publisher count default: `1`
- per-publisher rate: `10 msg/s`
- payload: `1024 B`
- steady-state duration: `30 s`

## Primary Research Question

How efficiently can a broker replicate the same message stream to many subscribers when publisher count increases slowly relative to subscriber count?

More concretely:

- how much delivery throughput is sustained as fan-out grows?
- how much latency and loss appear at larger subscriber counts?
- what broker resource cost is paid in CPU, memory, and network traffic?
- how do these tradeoffs differ across transports and broker implementations?

## Topology

The experiment uses a shared-topic fan-out topology:

- `P` publishers publish to the same topic
- `S` subscribers subscribe to that same topic
- every published message is intended to be delivered to every subscriber

That means offered publish load and offered delivery load are different quantities:

- publish target: `P x RATE_PER_PUB`
- delivery target: `P x RATE_PER_PUB x S`

The throughput plots in this experiment are about delivered subscriber throughput, so the relevant target is the delivery target.

## Experimental Factors

### Factor 1: Transport / Broker

The default sweep covers these transports:

- `zenoh`
- `redis`
- `nats`
- `rabbitmq`
- `mqtt`

For MQTT, the script can fan out across multiple broker implementations by name/host/port tuple. The default broker list is:

- `mosquitto:127.0.0.1:1883`
- `emqx:127.0.0.1:1884`
- `hivemq:127.0.0.1:1885`
- `rabbitmq:127.0.0.1:1886`
- `artemis:127.0.0.1:1887`

There is also AMQP support in the orchestrator, although the default transport list does not include it.

### Factor 2: Subscriber Count

Subscriber count is the main scaling axis.

Default dynamic-mode levels:

| Subscribers | Publishers | Publish target | Delivery target |
|---|---:|---:|---:|
| `500` | `5` | `50 msg/s` | `25,000 msg/s` |
| `1000` | `10` | `100 msg/s` | `100,000 msg/s` |
| `2000` | `20` | `200 msg/s` | `400,000 msg/s` |
| `3000` | `30` | `300 msg/s` | `900,000 msg/s` |
| `4000` | `40` | `400 msg/s` | `1,600,000 msg/s` |
| `5000` | `50` | `500 msg/s` | `2,500,000 msg/s` |
| `6000` | `60` | `600 msg/s` | `3,600,000 msg/s` |
| `7000` | `70` | `700 msg/s` | `4,900,000 msg/s` |

These values come directly from the default orchestrator parameters:

- `PUB_MODE=dynamic`
- `SUBS_PER_PUB=100`
- `MIN_PUBS=1`
- `RATE_PER_PUB=10`

If fixed mode is selected, publisher count is instead held constant at `FIXED_PUBS` for every subscriber level.

### Fixed Parameters

Unless overridden on the command line, the design fixes the following:

- payload: `1024 B`
- benchmark duration: `30 s`
- snapshot interval: `1 s`
- warmup: disabled by default
- steady-state trimming: ignore first `5 s` and last `5 s`
- interval between runs: `65 s`

## Load Model

For each subscriber level `S`, publisher count is computed as:

- dynamic mode: `P = max(MIN_PUBS, ceil(S / SUBS_PER_PUB))`
- fixed mode: `P = FIXED_PUBS`

Then:

- total publish rate = `P x RATE_PER_PUB`
- total delivery demand = `P x RATE_PER_PUB x S`

Dynamic mode intentionally does not keep publish rate constant while scaling subscribers. Instead, it lets publisher count rise slowly with fan-out so the workload remains realistic for a system where subscriber population and producer population grow together, but at different rates. Fixed mode is available when you want to isolate fan-out more cleanly by holding publisher count constant.

## Run Structure

Each run executes one `(transport, broker, subscribers)` condition.

### One Run Timeline

1. Resolve publisher count from subscriber count.
2. Derive total publish target and total delivery target.
3. Optionally restart the target broker when sequential mode is enabled.
4. Optionally run a short warmup workload.
5. Start broker resource monitoring.
6. Execute `scripts/run_fanout.sh` with the chosen engine and connection settings.
7. Collect publisher and subscriber CSV traces plus docker stats.
8. Derive steady-state metrics from the run artifacts.
9. Append one summarized row to `summary.csv`.

### Steady-State Window

Summary metrics are not computed over the full 30-second wall clock interval.
The script trims both edges of the run:

- ignore the first `5 s`
- ignore the last `5 s`

The intent is to reduce startup and shutdown transients and report the middle of the run as the representative steady state.

## Measurement Strategy

### Primary Outcome

The main reported outcome is subscriber delivery throughput, recorded in the summary as `sub_tps`.

This is computed from the subscriber aggregate CSV over the steady-state window as:

- `sub_tps = (received_count_end - received_count_start) / steady_state_duration`

### Secondary Outcomes

The orchestrator also summarizes:

- `pub_tps`: achieved publisher throughput in steady state
- `p50_ms`, `p95_ms`, `p99_ms`: mean latency percentiles across steady-state rows
- `sent`, `recv`, `errors`: steady-state deltas from the subscriber trace
- `loss_pct`: `(sent - recv) / sent x 100`

### Resource Outcomes

When docker stats are available, the script also records:

- `max_cpu_perc`, `avg_cpu_perc`
- `max_mem_perc`, `avg_mem_perc`
- `max_mem_used_bytes`, `avg_mem_used_bytes`
- `max_net_rx_bps`, `avg_net_rx_bps`
- `max_net_tx_bps`, `avg_net_tx_bps`

For local runs, container monitoring is attached automatically when the transport maps cleanly to a known container. For remote runs, the orchestrator starts a remote stats collector over SSH.

## Execution Modes

### Local Parallel-Lifecycle Mode

By default, the orchestrator assumes services are already available or can be started once. It then runs the sweep without restarting the broker between every condition.

This mode is faster but may carry state or thermal effects forward between runs.

### Sequential Restart Mode

With `--sequential`, the orchestrator restarts the relevant broker service between conditions.

This mode is slower but gives stronger isolation between runs. It is the cleaner design when comparing broker implementations and subscriber levels.

### Remote Mode

The script supports remote broker execution using:

- `--host`
- `--ssh-target`
- `--remote-dir`

In remote mode, connection endpoints are rewritten toward the target host and broker monitoring can be collected remotely.

## Artifacts And Outputs

Each run writes detailed artifacts under:

- `artifacts/<run_id>/fanout_singlesite/`

The orchestration summary is written under:

- `results/fanout_steady_load_<timestamp>/raw_data/summary.csv`

Plots are generated under:

- `results/fanout_steady_load_<timestamp>/plots/`
- `results/fanout_steady_load_<timestamp>/plots/latex/`

The plotting pipeline produces throughput, latency, CPU, memory, and network summaries, with a reduced plot set automatically selected for fan-out steady-load summaries.

## Example Invocation

Default experiment:

```bash
scripts/orchestrate_fanout_under_steady_load.sh
```

Example custom sweep:

```bash
scripts/orchestrate_fanout_under_steady_load.sh \
  --subs-list "1000 2000 4000 8000" \
  --rate-per-pub 20 \
  --payload 1024 \
  --transports "zenoh redis nats rabbitmq mqtt"
```

Example fixed-publisher sweep:

```bash
scripts/orchestrate_fanout_under_steady_load.sh \
  --pub-mode fixed \
  --fixed-pubs 1 \
  --subs-list "1000 2000 4000 8000"
```

Example higher-isolation run:

```bash
scripts/orchestrate_fanout_under_steady_load.sh \
  --sequential \
  --start-services \
  --interval-sec 65
```

## Design Strengths

This design has a few useful properties:

- it exercises true fan-out rather than one-to-one topic traffic
- it reports both achieved delivery and delivery shortfall
- it separates publish load from delivery demand explicitly
- it can compare protocol families and multiple broker implementations with one driver
- it includes resource measurements alongside throughput and latency

## Threats To Validity

A few caveats matter when interpreting the results.

### Publisher Count Is Not Held Constant

As subscriber count grows, publisher count also grows. That means the experiment changes both fan-out size and total offered publish load at the same time.

Interpretation:

- the design answers a practical scaling question
- it does not isolate pure subscriber fan-out cost at fixed publish rate

### Short Run Duration

The default run duration is only `30 s`, with a `20 s` effective steady-state window after trimming.

Interpretation:

- this is good for fast broad sweeps
- it may miss slower broker stabilization effects, backlog behavior, or long-tail memory growth

### Replication Is Not Built In

The orchestrator performs a sweep, but it does not natively enforce repeated measured replicates or randomized run order.

Interpretation:

- the current script is suitable for exploratory benchmarking
- paper-grade results should add blocked replicates and randomized condition order

### Shared Host Effects

When multiple brokers are run on the same host, cross-container resource contention can affect results.

Interpretation:

- sequential broker restarts help
- dedicated-host or isolated-host runs would improve internal validity

## Recommended Paper-Grade Extension

If this experiment is intended for a paper-quality comparison, the next design step should be:

- run `3-5` measured replicates per condition
- randomize condition order within each replicate block
- prefer `--sequential` execution
- record host hardware and kernel details
- keep one results directory per replicate block
- report both achieved throughput and achieved/target delivery ratio

## Source Of Truth In Repo

This design note is based on the current implementation in:

- `scripts/orchestrate_fanout_under_steady_load.sh`
- `scripts/run_fanout.sh`
- `scripts/plot_results.py`

If the script defaults change, this document should be updated to match them.
