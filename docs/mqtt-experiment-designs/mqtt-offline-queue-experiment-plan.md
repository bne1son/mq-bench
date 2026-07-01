# MQTT Offline-Queue Experiment Plan

## Short Version

This should be run as a concrete `3 x 2` blocked experiment:

- `3` MQTT session modes
- `2` workload levels
- `5` measured replicates per cell

The paper result should stay inside MQTT first and ask a narrow question:

- when subscribers disconnect cleanly for a short time, does persistent-session MQTT recover the missed data after reconnect?

## Primary Research Question

Under the same publish load, how much message recovery does MQTT gain from persistent sessions, and what recovery cost does it pay in catch-up time, latency, CPU, and memory?

## Hypotheses

`qos=1` with `clean_session=false` should:

- recover nearly all messages published during subscriber offline windows
- show substantially higher final delivery ratio than both control modes
- incur a visible catch-up phase after reconnect
- use more broker memory during offline buffering than non-persistent modes

## Concrete Design Matrix

### Factor 1: Session Mode

| Mode | `qos` | `clean_session` | Expected behavior |
|---|---:|---:|---|
| Control A | `0` | `true` | offline-window messages are lost |
| Control B | `1` | `true` | QoS helps only while connected; offline-window messages are still lost |
| Target | `1` | `false` | broker should queue offline-window messages and redeliver after reconnect |

Use the same subscriber `client_id` base on every reconnect in all three modes.
Only the `qos` and `clean_session` settings should change.

### Factor 2: Load Level

| Load | Tenants | Regions | Services | Shards | Total topics | Payload | Per-publisher rate | Total offered rate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Moderate | `2` | `4` | `5` | `5` | `200` | `128 B` | `2 msg/s` | `400 msg/s` |
| Stress | `5` | `4` | `5` | `5` | `500` | `128 B` | `5 msg/s` | `2500 msg/s` |

In both cases:

- `publishers=-1`
- `subscribers=-1`
- one publisher and one subscriber per topic
- `mapping=mdim`

## Fixed Infrastructure

Use these fixed settings for the main paper experiment:

- broker: `mosquitto` on `127.0.0.1:1883`
- config: `config/mosquitto.conf`
- persistence: enabled
- session expiration: `1d`
- snapshot interval: `1 s`
- publisher duration: `240 s`
- final drain period: `60 s`
- subscriber retry: enabled
- topic prefix: unique per run

Why Mosquitto first:

- the repo already mounts `config/mosquitto.conf`
- persistence is already enabled there
- queue limits are already high enough for this test
- the offline windows in this design are far shorter than the configured persistent-session expiration

## One Run Timeline

Define `t=0` as publisher start.

| Phase | Time | Subscriber state | Publisher state | Purpose |
|---|---|---|---|---|
| Pre-connect | `t=-5` to `0` | online | not started | allow subscriptions to establish |
| Baseline | `0-60 s` | online | sending | verify no backlog before disconnect |
| Offline 1 | `60-90 s` | offline | sending | create backlog window 1 |
| Recovery 1 | `90-150 s` | online | sending | observe catch-up while live traffic continues |
| Offline 2 | `150-180 s` | offline | sending | create backlog window 2 |
| Recovery 2 | `180-240 s` | online | sending | observe second catch-up |
| Final drain | `240-300 s` | online | stopped | allow queued messages to finish draining |

This gives two identical offline windows of `30 s` each.

Expected backlog generated per offline window:

- Moderate: `400 msg/s x 30 s = 12,000` messages
- Stress: `2500 msg/s x 30 s = 75,000` messages

## Experimental Unit And Replication

The unit of analysis is one full run:

- one broker reset
- one publisher process
- three subscriber segments using the same subscriber `client_id` base
- one docker-stats trace

Replication plan:

- `1` pilot run per cell for sanity checking, not used in the paper summary
- `5` measured replicates per cell
- total measured runs: `3 modes x 2 loads x 5 reps = 30`

Run-order plan:

- treat each replicate index as a block
- within each block, randomize the order of the six condition cells
- reset broker state before every measured run

## Broker Reset Requirement

This step is important.

Because Mosquitto persistence is enabled, durable sessions from previous runs would otherwise accumulate and contaminate memory results.

Before each replicate, start the broker from a clean persistent state.

Simple local approach:

```bash
docker compose down -v
docker compose up -d mosquitto
```

If that is too broad for your environment, use a disposable project name or a fresh `mosquitto_data` volume per run.

## Concrete Run Procedure

Each run should follow this exact sequence:

1. Reset Mosquitto persistent state.
2. Start a `docker stats` sampler for container `mosquitto` at `1 s` cadence.
3. Start subscriber segment 1 with the chosen MQTT mode.
4. Sleep `5 s` for subscription setup.
5. Start publisher.
6. Let subscriber segment 1 exit after `65 s` total runtime.
7. Keep publisher running; wait `30 s` with subscriber offline.
8. Start subscriber segment 2 with the same `client_id` base and same topic prefix; run it for `60 s`.
9. Wait `30 s` with subscriber offline again.
10. Start subscriber segment 3 with the same `client_id` base and same topic prefix; run it for `120 s`.
11. Wait for publisher and subscriber segment 3 to finish.
12. Stop the docker-stats sampler.
13. Stitch the three subscriber CSVs into one cumulative receive trace for analysis.

## Command Template

Use direct `mq-bench` invocations in the first implementation.
The future orchestrator script should just automate this exact sequence.

### Common Environment

```bash
RUN_ID="offlineq_$(date +%Y%m%d_%H%M%S)"
ART_DIR="artifacts/mqtt_offline_queue/${RUN_ID}"
TOPIC_PREFIX="bench/offlineq/${RUN_ID}"
PUB_CID="oqpub-${RUN_ID}"
SUB_CID="oqsub-${RUN_ID}"

mkdir -p "${ART_DIR}"
```

### Publisher Template

```bash
./target/release/mq-bench --snapshot-interval 1 mt-pub \
  --engine mqtt \
  --connect "host=127.0.0.1" \
  --connect "port=1883" \
  --connect "client_id=${PUB_CID}" \
  --connect "qos=${QOS}" \
  --connect "clean_session=${CLEAN_SESSION}" \
  --topic-prefix "${TOPIC_PREFIX}" \
  --tenants "${TENANTS}" --regions "${REGIONS}" --services "${SERVICES}" --shards "${SHARDS}" \
  --publishers -1 \
  --mapping mdim \
  --payload 128 \
  --rate "${RATE}" \
  --duration 240 \
  --csv "${ART_DIR}/pub.csv" \
  --enable-retry
```

### Subscriber Template

```bash
./target/release/mq-bench --snapshot-interval 1 mt-sub \
  --engine mqtt \
  --connect "host=127.0.0.1" \
  --connect "port=1883" \
  --connect "client_id=${SUB_CID}" \
  --connect "qos=${QOS}" \
  --connect "clean_session=${CLEAN_SESSION}" \
  --topic-prefix "${TOPIC_PREFIX}" \
  --tenants "${TENANTS}" --regions "${REGIONS}" --services "${SERVICES}" --shards "${SHARDS}" \
  --subscribers -1 \
  --mapping mdim \
  --duration "${SEGMENT_DURATION}" \
  --csv "${ART_DIR}/sub_seg${SEGMENT}.csv" \
  --enable-retry
```

### Segment Durations

Use these exact durations:

- segment 1: `65 s`
- gap after segment 1: `30 s`
- segment 2: `60 s`
- gap after segment 2: `30 s`
- segment 3: `120 s`

## Why The Reconnect Should Work In This Repo

This design matches the current implementation closely.

The MQTT transport already:

- accepts `qos`
- accepts `clean_session`
- accepts a base `client_id`
- derives stable per-topic subscriber client IDs when a base `client_id` is supplied

That means reusing the same subscriber base `client_id` across segments should cause the broker to associate each topic with the same durable session identity in the target mode.

## Artifact Layout

Each run should write:

```text
artifacts/mqtt_offline_queue/<run_id>/
  pub.csv
  pub.log
  sub_seg1.csv
  sub_seg1.log
  sub_seg2.csv
  sub_seg2.log
  sub_seg3.csv
  sub_seg3.log
  docker_stats.csv
  metadata.env
```

`metadata.env` should record at least:

- mode name
- `qos`
- `clean_session`
- load name
- dimensions
- rate
- payload
- broker name
- replicate index

## Primary Metrics

These should be the paper metrics.

### 1. Final Delivery Ratio

Definition:

`final_delivery_ratio = stitched_received_final / sent_final`

Where:

- `sent_final` is the final `sent_count` from `pub.csv`
- `stitched_received_final` is the sum of the final `received_count` values from subscriber segments 1, 2, and 3

This is the main outcome.

### 2. Backlog Drain Time Per Recovery Window

For each offline window `i`:

- let `t_off_i_start` be disconnect time
- let `t_off_i_end` be reconnect time
- let `queued_i = sent(t_off_i_end) - sent(t_off_i_start)`
- let `recv_base_i` be stitched cumulative receives at `t_off_i_start`
- define `drain_time_i` as the first time after reconnect where stitched cumulative receives reach `recv_base_i + queued_i`

This directly answers how long queued offline data takes to clear.

### 3. Recovery Throughput

Definition:

`recovery_throughput_i = queued_i / drain_time_i`

Report both windows and their mean per run.

### 4. Recovery Latency

Use subscriber snapshot fields:

- `interval_latency_ns_p99`
- `latency_ns_p99`

Primary latency summary:

- max `interval_latency_ns_p99` during the first `30 s` after each reconnect

### 5. Broker Memory Cost

From `docker_stats.csv`, report:

- peak memory used during offline windows
- peak memory used during recovery windows

### 6. Broker CPU Cost

From `docker_stats.csv`, report:

- mean CPU during the first `30 s` after reconnect
- max CPU during the same windows

## Expected Quantitative Pattern

Because the subscriber is offline for `60 s` total out of `240 s` of publishing, the non-persistent controls should lose about one quarter of the stream.

That gives a useful sanity target:

- Control A: final delivery ratio near `0.75`
- Control B: final delivery ratio near `0.75`
- Target: final delivery ratio near `1.00`

Small deviations are fine because reconnect and drain are not instantaneous, but if the target mode does not strongly separate from the two controls, something is wrong.

## Analysis Plan

For each of the six cells:

- compute the run-level metrics above
- summarize with median and interquartile range
- also report `95%` bootstrap confidence intervals for the median

Primary comparisons:

- Target vs Control A within each load
- Target vs Control B within each load

If you want a formal test, use a paired non-parametric comparison within each replicate block.

## Plots To Produce

Make these figures first:

- cumulative `sent` vs stitched cumulative `received` over time
- final delivery ratio by mode for each load
- backlog drain time by mode for each load
- subscriber `interval_latency_ns_p99` over time with reconnect markers
- broker memory over time with offline windows shaded
- broker CPU over time with reconnect markers

The most important figure is the cumulative `sent` vs stitched cumulative `received` plot.

Expected shape:

- the curves separate while the subscriber is offline
- only the persistent-session target closes the gap after reconnect

## Instrumentation Caveat

There is one important limitation in the current implementation.

When we use three separate subscriber processes for graceful stop and restart:

- `received_count` can be stitched across segments cleanly
- latency snapshots can be analyzed per segment cleanly
- broker CPU and memory can be analyzed cleanly
- `duplicate_count` and `gap_count` are not exact across segment boundaries, because each new `mt-sub` process creates fresh sequence trackers

So for the paper-quality version, make final-message recovery the primary endpoint.

If you also want exact duplicate and gap accounting across graceful restarts, add one small instrumentation improvement before the final sweep:

- either preserve sequence-tracker state across graceful reconnects in one long-running subscriber process
- or export enough per-segment sequence metadata to reconstruct cross-segment head loss explicitly

## Implementation Recommendation

Create two helper scripts after the pilot works:

- `scripts/orchestrate_mqtt_offline_queue.sh`
- `scripts/summarize_mqtt_offline_queue.py`

Responsibilities of the orchestrator:

- broker reset
- docker-stats collection
- publisher launch
- three subscriber segments with identical subscriber `client_id`
- artifact naming
- run metadata capture

Responsibilities of the summarizer:

- stitch subscriber segments into one cumulative receive trace
- compute delivery ratio, drain time, recovery throughput, and latency summaries
- merge broker docker-stats summaries
- emit one `summary.csv` row per run

## Optional Secondary Extension

After the main Mosquitto result is stable, run a smaller appendix sweep on the target mode only across:

- `mosquitto:1883`
- `emqx:1884`
- `hivemq:1885`
- `rabbitmq:1886`
- `artemis:1887`

Use only the Moderate load for that appendix check.
That keeps the main paper story focused while still showing portability.

## Final Recommendation

This is the right first MQTT-specific experiment for the paper because it now has:

- a fixed design matrix
- exact run timing
- concrete commands
- explicit replication and randomization
- a realistic analysis plan
- an honest note about the one instrumentation gap that still matters for graceful restart accounting
