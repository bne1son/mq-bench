# MQTT message-recovery runner: simple guide

This guide explains `scripts/orchestrate_mqtt_message_recovery.sh`, the runner
for Experiment 4. Run the commands below from the repository root.

## What the experiment asks

Imagine 1,000 intermittently powered devices. Each device listens to its own
MQTT topic, goes offline for part of each 100-second cycle, then reconnects.
The experiment asks: **How many messages arrive eventually when MQTT keeps the
device's session, compared with a clean session that does not keep it?**

Device Availability Ratio (DAR) is the fraction of time a device is online.
For example, DAR 0.6 means 60 seconds online and 40 seconds offline in each
100-second cycle. Every device has its own outage time, so they do not all go
offline together.

The script compares three modes:

| Mode | Message QoS | Session after reconnection | Purpose |
|---|---:|---|---|
| `q0_clean` | 0 | New clean session | Best-effort control |
| `q1_clean` | 1 | New clean session | Main no-recovery comparison |
| `q1_persistent` | 1 | Previous session resumes | Recovery case |

The main result is **Persistence Recovery Gain (PRG)**: the miss rate of
`q1_clean` minus the miss rate of `q1_persistent`, using the same DAR and seed.
A positive value means persistence helped recover messages. The listed QoS is
used for both publishing and subscribing.

## What the script does, in order

1. **Checks the basics.** It needs Python 3 and `sha256sum`. A real run also
   needs an executable `target/release/mq-bench`. `--start-broker` additionally
   needs Docker and a local MQTT host.
2. **Creates a results folder.** By default this is
   `results/mqtt_message_recovery_<UTC timestamp>/`.
3. **Makes availability schedules.** One schedule is generated for each
   `(DAR, seed)` pair. A checksum accompanies it. The same schedule is reused
   across modes so comparisons are paired and reproducible.
4. **Writes the run manifest before running anything.** It lists each run's
   order, mode, DAR, seed, kind (`pilot` or `measured`), and status. The 15
   mode/DAR cells are shuffled within each seed block.
5. **If `--pilot` is set, runs short checks first.** The test script checks
   schedules and analysis, then starts three small MQTT tests (one per mode)
   using four subscribers and a 15-second run per mode.
6. **Runs each manifest row sequentially.** With `--start-broker`, it starts a
   fresh Mosquitto container for that row on port 1883. Broker persistence is
   in temporary container memory, so an earlier row's sessions cannot leak
   into the next row. Without this option, it connects to the broker you
   already have running; it does **not** clear that broker's persistence.
7. **Starts one subscriber controller.** It establishes all 1,000 MQTT
   subscriptions, waits for broker confirmation, and writes an
   `availability_ready` file. This file marks the experiment clock's start.
8. **Starts ten publisher processes.** Each handles 100 different topics;
   together they offer 2,000 messages per second at 128 bytes per message.
   They start after subscriber readiness and publish for 360 seconds.
9. **Simulates device availability.** All subscribers stay online for the
   60-second warm-up. For the next three 100-second cycles, each follows its
   own scheduled OFF/ON events. An OFF event force-closes the MQTT connection
   without sending a normal MQTT DISCONNECT. The device reconnects using the
   same client ID. Persistent-session reconnects must be confirmed by the
   broker's `session_present` flag.
10. **Drains and analyzes.** Publishers stop after the cycles. All devices are
    online for the final 120 seconds so queued messages can arrive. The
    analyzer checks the schedule, events, receipts, publisher counts, topic
    ranges, and exit codes. It counts each `(topic, sequence)` only once,
    excludes warm-up messages, and includes cycle messages received during
    the drain.
11. **Records results and cleans up.** A run is marked `complete`, `failed`,
    or `invalid`. Logs and traces are retained even for bad runs. The script
    stops its broker container, combines per-run summaries, and generates PNG
    and PDF plots when valid measured rows are available.

The runner also samples local Docker broker statistics about once per second.
Stopping the script triggers cleanup of the processes and container it started.

## How long does it take?

Each full run has **60 seconds warm-up + 300 seconds of cycles + 120 seconds
final drain = 480 seconds (8 minutes)**. Connection setup happens before the
readiness barrier and adds time outside those 480 seconds.

| Command type | Full runs | Scheduled run time, before setup/analysis |
|---|---:|---:|
| Default measured matrix | 3 modes × 5 DARs × 3 seeds = 45 | 6 hours |
| Default matrix with `--pilot` | 4 pilots + 45 measured = 49 | 6 hours 32 minutes |
| One mode, one DAR, one seed | 1 | 8 minutes |

The short integration tests, Docker startup or image download, subscriber
connection setup, analysis, and plotting add extra time. `--pilot` means
**pilots before the measured matrix**, not "pilots only." Pilot rows use seed
`196613` and are marked as pilot data, not paper measurements. See the plot
filtering note below before using time-series figures in a paper.

## How to use it

Build the release binary first:

```bash
cargo build --release --no-default-features --features transport-mqtt
```

Run the full matrix with a fresh Mosquitto container per row:

```bash
scripts/orchestrate_mqtt_message_recovery.sh --pilot --start-broker
```

This binds the broker to `127.0.0.1:1883`. Stop any existing service using
that port before running it; the script does not stop unrelated containers.
Docker may need to download `eclipse-mosquitto:2` on the first run.

Run the measured matrix without pilots:

```bash
scripts/orchestrate_mqtt_message_recovery.sh --start-broker
```

Try a single full run before committing to the matrix:

```bash
scripts/orchestrate_mqtt_message_recovery.sh \
  --modes "q1_persistent" --dar-list "0.6" --seeds "104729" \
  --start-broker
```

Preview the run list without starting a benchmark or broker:

```bash
scripts/orchestrate_mqtt_message_recovery.sh --dry-run
```

`--dry-run` still creates schedules, run directories, and a manifest. It
prints a description of each planned run; despite the help text, it does not
currently print the full publisher/subscriber commands.

Use a broker that is already running:

```bash
scripts/orchestrate_mqtt_message_recovery.sh --host 127.0.0.1 --port 1883
```

In this case the script checks that the port answers, but you are responsible
for broker setup and isolation. A fresh broker is preferable for persistence
comparisons.

Other options:

| Option | Meaning |
|---|---|
| `--modes "..."` | Space-separated subset of the three mode names |
| `--dar-list "..."` | Space-separated DAR values from `1.0 0.8 0.6 0.4 0.2` |
| `--seeds "..."` | Space-separated schedule seeds |
| `--host HOST`, `--port PORT` | MQTT connection address; `--start-broker` requires a local host |
| `--binary PATH` | Use a different built `mq-bench` executable |
| `--results-root PATH` | Choose the output directory |
| `--pilot` | Add short integration checks and four full pilot rows before the measured rows |
| `--start-broker` | Start and stop an isolated Mosquitto container per full row |
| `--dry-run` | Generate the run plan without running the benchmark |

When using `--pilot` with a reduced `--modes` list, be aware that the script
still adds its fixed `q1_persistent` DAR 0.2 pilot even if persistent mode was
not selected. If you want exactly the reduced measured cells, omit `--pilot`.

## Where to look afterward

The runner prints the results-root path at the end. The main files are:

| File | What it tells you |
|---|---|
| `run_manifest.csv` | Planned order and each row's current status |
| `schedules/` | Deterministic outage CSVs, checksums, and metadata |
| `raw_data/<run_id>/status.json` | Whether a row completed, failed, or was invalid |
| `raw_data/<run_id>/validation.json` | Detailed invalidity reasons when analysis ran |
| `raw_data/<run_id>/metadata.json` | Mode, DAR, seed, commands, timings, checksums, and exit codes |
| `raw_data/<run_id>/subscriber_events.csv` | Actual device OFF, reconnect, and drain events |
| `raw_data/<run_id>/receive_trace.csv` | Individual message receipts and send/receive times |
| `raw_data/<run_id>/pub_*.csv`, `sub.csv` | Publisher and subscriber one-second snapshots |
| `raw_data/<run_id>/*.log` | Subscriber, publisher, and analyzer logs; broker log when `--start-broker` is used |
| `raw_data/<run_id>/run_summary.csv` | That row's delivery, miss, duplicate, and recovery metrics |
| `raw_data/<run_id>/subscriber_availability.csv` | Achieved DAR for each subscriber |
| `summary.csv`, `cycle_summary.csv` | Combined summaries across rows; PRG columns are in `summary.csv` |
| `plots/README.md` | Gallery linking the generated PNG plots; PDFs are alongside them |

The miss rate is `1 - unique delivered cycle messages / cycle messages sent`.
`summary.csv` contains both pilots and measured rows; use `run_kind` and
`valid` to select paper data. The DAR-versus-metric plots filter out pilot and
invalid rows. **Currently the time-series plotter reads every per-run
`dar_timeseries.csv`, including pilots or invalid runs when those files exist.**
Check those time-series figures before using them as measured results.

**Important:** the script deliberately retains failed artifacts and moves on
to later manifest rows. Inspect `run_manifest.csv`, `status.json`, and
`validation.json` before trusting the combined summary. An invalid run is not
a valid zero-loss result.
