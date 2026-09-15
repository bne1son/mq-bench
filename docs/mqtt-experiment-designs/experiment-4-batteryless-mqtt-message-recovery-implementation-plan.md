# Experiment 4: MQTT Message Recovery Under Intermittent Connectivity

## Implementation Plan

## 1. Objective

Implement Experiment 4 from slides 34–46 of
`docs/Plan/MQ_Bench_Journal_Extension_final.pptx` as a reproducible MQ-Bench
experiment.

The research question is:

> As the Device Availability Ratio (DAR) decreases, how many messages can MQTT
> persistent sessions recover after intermittently powered subscribers reconnect?

The experiment varies subscriber availability from always online to mostly
offline. It compares clean MQTT sessions with persistent sessions while 1,000
independently scheduled subscribers repeatedly disconnect and reconnect.

The primary outcome is Persistence Recovery Gain (PRG):

```text
PRG = MissRate_no_recovery - MissRate_persistent
```

## 2. Slide Discrepancy and Working Decision

Slide 34 gives an overview topology of 20 publishers and 2,000 subscribers.
Slides 40 and 41 both give this detailed configuration:

- 10 publishers.
- 1,000 subscribers and unique topics.
- 100 topics per publisher.
- 2 messages/second/topic, or 2,000 messages/second aggregate.

This plan treats the internally consistent values on slides 40–41 as
authoritative. Change the constants before implementation if the intended scale
is actually 20 publishers and 2,000 subscribers.

## 3. Experiment Model

### 3.1 Device Availability Ratio

For each subscriber:

```text
DAR = T_ON / (T_ON + T_OFF)
```

Use a 100-second cycle:

| DAR | ON per cycle | OFF per cycle | Random OFF-start offset |
|---:|---:|---:|---:|
| 1.00 | 100 s | 0 s | No outage |
| 0.80 | 80 s | 20 s | Uniform `U(5, 75)` s |
| 0.60 | 60 s | 40 s | Uniform `U(5, 55)` s |
| 0.40 | 40 s | 60 s | Uniform `U(5, 35)` s |
| 0.20 | 20 s | 80 s | Uniform `U(5, 15)` s |

For non-100% DAR, every subscriber has one contiguous OFF interval in each
cycle:

```text
off_start = cycle_start + Uniform(5, 95 - T_OFF)
off_end   = off_start + T_OFF
```

This gives every subscriber at least five online seconds at the beginning and
end of a cycle while preserving its exact ON/OFF totals. Generate offsets with
millisecond precision. Each `(subscriber, cycle)` draw is independent, but the
complete schedule is deterministic for a fixed seed.

### 3.2 Asynchronous outages

Do not power all subscribers off together. Each subscriber receives its own
random OFF start in every cycle. This models independently harvesting devices.

The aggregate online population should remain near `DAR × 1,000` away from
cycle boundaries. The broker therefore handles live delivery, offline queueing,
reconnections, and backlog recovery concurrently.

### 3.3 MQTT modes

| Mode ID | Publish QoS | Subscribe QoS | Subscriber clean session | Role |
|---|---:|---:|---:|---|
| `q0_clean` | 0 | 0 | `true` | Best-effort control |
| `q1_clean` | 1 | 1 | `true` | No-recovery control |
| `q1_persistent` | 1 | 1 | `false` | Persistent-session target |

Use the same subscriber client ID before and after every power loss. Publishers
remain online and use `clean_session=true` in all modes.

Use `q1_clean` as the primary no-recovery comparator because it holds QoS
constant and isolates session persistence:

```text
PRG_q1(DAR, seed) =
    MissRate_q1_clean(DAR, seed) - MissRate_q1_persistent(DAR, seed)
```

Also report a secondary comparison against `q0_clean`.

## 4. Fixed Topology and Traffic

```text
10 stable publisher processes
          |
          | 100 topics each
          v
      MQTT broker
          |
          | one unique topic per subscriber
          v
1,000 intermittently available subscribers
```

| Parameter | Value |
|---|---:|
| Publishers | 10 stable processes |
| Subscribers | 1,000 logical devices |
| Topics | 1,000 unique topics |
| Topics per publisher | 100 non-overlapping topics |
| Subscriptions per device | 1 exact topic |
| Payload | 128 B |
| Rate per topic | 2 msg/s |
| Rate per publisher | 200 msg/s |
| Aggregate offered rate | 2,000 msg/s |
| Traffic | Constant rate |
| Retained flag | `false` |
| Publisher availability | Always online until publishing stops |
| Primary broker | Mosquitto at `127.0.0.1:1883` |
| Snapshot interval | 1 s |

Launch 10 `mt-pub` processes, each owning a distinct contiguous range of 100
global topic indices.

## 5. Run Timeline

One complete run lasts 480 seconds:

| Phase | Run time | Length | Publishers | Subscribers |
|---|---:|---:|---|---|
| Warm-up | `0–60 s` | 60 s | Publishing | All online |
| Cycle 1 | `60–160 s` | 100 s | Publishing | Scheduled availability |
| Cycle 2 | `160–260 s` | 100 s | Publishing | Scheduled availability |
| Cycle 3 | `260–360 s` | 100 s | Publishing | Scheduled availability |
| Final drain | `360–480 s` | 120 s | Stopped | All online |

Use the start of cycle 1 as measurement time zero in DAR plots. Exclude warm-up
traffic from the primary miss-rate denominator. Allow cycle messages delivered
during the final drain to count as eventually delivered.

At `t=360 s`, stop publishers, cancel any remaining outage timers, force every
subscriber online, and prohibit further OFF transitions.

## 6. Design Matrix and Repetition

Run:

```text
3 modes × 5 DAR levels × 3 fixed seeds = 45 measured runs
```

Recommended seeds:

```text
104729, 130363, 155921
```

A seed generates the complete `1,000 subscribers × 3 cycles` schedule for one
DAR. Reuse that exact schedule for all three modes, creating a paired comparison.

Keep three runs at `DAR=1.00` even though they contain no outages so the matrix
remains balanced. Randomize the 15 `(mode, DAR)` cells inside each seed block
and save the run order before execution.

Before the measured matrix, run:

- A short integration test for all three modes.
- A full `DAR=0.60` pilot for all three modes with a separate seed.
- A full `DAR=0.20, q1_persistent` pilot to verify queue and drain capacity.

Pilots are not paper data.

## 7. Implementation Architecture

Use one long-running `mt-sub` controller containing 1,000 independently
scheduled subscriber tasks. Each task represents one device and owns one MQTT
connection and exact-topic subscription.

At an OFF event, the task drops its MQTT connection without sending DISCONNECT.
At ON, it constructs a fresh MQTT client with the same client ID. The outer
process remains alive only to schedule devices and record observations; no
client protocol state should carry into the reconstructed device.

This architecture supports independent outage times. Killing one process
containing all subscribers would incorrectly synchronize every outage.

## 8. Required Repository Changes

### 8.1 Deterministic schedule generator

Create `scripts/generate_mqtt_availability_schedule.py`.

CLI:

```text
--subscribers 1000
--cycles 3
--cycle-secs 100
--dar 1.0|0.8|0.6|0.4|0.2
--seed N
--out PATH
```

Output:

```text
subscriber_index,cycle_index,cycle_start_s,off_start_s,off_end_s,off_duration_s
```

Requirements:

- Times are relative to cycle 1 start.
- Use a documented stable PRNG/sampling algorithm.
- Sort by OFF start, then subscriber index.
- For DAR 1.00, emit metadata and a header with no outage rows.
- Validate one outage per subscriber/cycle, bounds, duration, and ON/OFF totals.
- Write a SHA-256 checksum.
- Generate each `(DAR, seed)` schedule once and reuse it across modes.

### 8.2 Deterministic availability in `mt-sub`

Modify:

- `src/main.rs`
- `src/roles/multi_topic.rs`

Add:

```text
--availability-schedule PATH
--availability-start-delay 60
--final-drain-secs 120
--subscriber-events PATH
--receive-trace PATH
--availability-ready PATH
```

Behavior:

1. Establish all subscriptions at startup and write `--availability-ready`
   only after every MQTT SUBACK. The experiment clock starts at this barrier,
   so connection setup does not consume the 60-second warm-up.
2. Start publishers from that barrier and keep all devices online during warm-up.
3. At OFF, invoke `force_disconnect()` and drop that device's transport.
4. Never send MQTT DISCONNECT for an energy failure.
5. At ON, recreate the transport/subscription with the same derived client ID.
6. Repeat independently for all devices and cycles.
7. At drain start, cancel outages and reconnect every offline device.
8. Stop after the 120-second drain and flush observations.

Do not reuse stochastic `--mttf/--mttr`; exponential failures do not implement
the fixed-DAR model. Refactor shared lifecycle helpers from the existing
per-topic crash branch if useful.

Write actual events as:

```text
timestamp_ns,elapsed_s,subscriber_index,cycle_index,event,client_id,session_present,status
```

Events include `initial_connect`, `power_off`, `reconnect_start`,
`reconnect_complete`, `forced_online_for_drain`, and `final_disconnect`.
Actual events, not requested schedule times, are authoritative for achieved DAR.

### 8.3 Stable identity and session-resume evidence

Modify `src/transport/mqtt.rs`:

- Preserve stable per-topic client IDs from a supplied base ID.
- Surface CONNACK `session_present` to the controller.
- Distinguish TCP/MQTT connection from confirmed session resumption.
- Ensure `force_disconnect()` closes the real subscription connection without
  sending DISCONNECT.
- Construct a new rumqttc client/event loop after every ON transition.

Expected behavior:

- Initial connection: `session_present=false`.
- Clean-session reconnect: `session_present=false`.
- Persistent reconnect: `session_present=true`.

An unexpected flag invalidates the run rather than becoming ordinary loss.

### 8.4 Partition topics across 10 publishers

Modify `src/main.rs` and `src/roles/multi_topic.rs`.

Add an `mt-pub` option:

```text
--topic-index-start N
```

Publisher process `p` uses:

```text
topic_index_start = p × 100
topic_count       = 100
```

Apply the global index before `mdim` mapping. Reject out-of-range partitions.
Unit-test that all 10 ranges are disjoint and their union is exactly `0..999`.

Each publisher writes a separate CSV/log and runs for 360 seconds.

### 8.5 Duplicate-safe receive tracing

When `--receive-trace` is enabled, the existing multi-topic stats worker writes
buffered rows:

```text
receive_timestamp_ns,subscriber_index,topic_index,sequence,send_timestamp_ns,latency_ns
```

Requirements:

- Use `(topic_index, sequence)` as run-wide message identity.
- Parse the existing 24-byte header without changing the wire format.
- Never write from the MQTT callback.
- Flush periodically and at shutdown.
- Trace failure or bounded-channel overflow fails the run.
- Keep tracing off by default for backward compatibility.

QoS 1 can redeliver. Delivery and miss rate count unique identities; duplicate
ratio is separate.

At 2,000 receipts/s, CSV should be practical. Compare a pilot with tracing on
and off. If throughput or CPU differs by more than 2%, use a buffered binary
trace with the same logical fields.

### 8.6 Orchestrator

Create `scripts/orchestrate_mqtt_message_recovery.sh`.

Minimum CLI:

```text
--modes "q0_clean q1_clean q1_persistent"
--dar-list "1.0 0.8 0.6 0.4 0.2"
--seeds "104729 130363 155921"
--pilot
--host HOST
--port PORT
--start-broker
--binary PATH
--results-root PATH
--dry-run
```

Responsibilities:

- Verify prerequisites and paths.
- Generate and validate schedules.
- Save the randomized manifest before execution.
- Start each run with clean Mosquitto persistence.
- Use unique run/topic/client identifiers.
- Start 1-second broker resource sampling before connections.
- Start the subscriber and confirm all 1,000 clients during warm-up.
- Start 10 publishers with disjoint ranges.
- Use an explicit barrier for cycle 1 start.
- Stop publishers at cycle 3 end.
- Keep subscribers alive through the drain.
- Capture child exits and terminate on unexpected exit.
- Analyze and mark each run `complete`, `failed`, or `invalid`.
- Retain failed/invalid artifacts and reasons.
- Clean up through an EXIT trap.

### 8.7 Analyzer

Create `scripts/analyze_mqtt_message_recovery.py`.

It must:

1. Validate metadata, checksums, schedules, events, partitions, and exits.
2. Merge 10 publisher snapshot files.
3. Deduplicate receipts by `(topic_index, sequence)`.
4. Select messages published during the 300-second cycle interval.
5. Exclude warm-up messages.
6. Include cycle messages arriving during final drain.
7. Compare send time with that device's actual OFF/ON events.
8. Compute all metrics below.
9. Emit explicit invalidity reasons instead of zero-filling missing data.

Outputs:

```text
run_summary.csv
cycle_summary.csv
dar_timeseries.csv
validation.json
subscriber_availability.csv
```

### 8.8 Plotter

Create `scripts/plot_mqtt_message_recovery.py`.

Produce PNG and PDF:

- `miss_rate_vs_dar` for all modes.
- `persistence_recovery_gain_vs_dar`.
- `eventual_delivery_ratio_vs_dar`.
- `online_subscribers_vs_time`.
- `delivery_throughput_vs_time`.
- `backlog_vs_time`.
- `recovery_latency_vs_dar`.
- `duplicate_ratio_vs_dar`.
- Secondary `broker_cpu_vs_dar` and `broker_memory_vs_dar`.
- A generated `README.md` gallery.

Plot DAR from 0.20 to 1.00. Show all three seed values, not only an aggregate.

### 8.9 Tests

Create:

- `scripts/test_mqtt_message_recovery.sh`
- Synthetic analyzer fixtures under `tests/fixtures/mqtt_message_recovery/`.

Test:

- Fixed-seed schedule determinism.
- Exactly three outages per non-100% subscriber.
- Schedule bounds and DAR totals.
- Disjoint publisher ranges covering all 1,000 topics.
- Clean versus persistent session flags.
- Hard disconnect without MQTT DISCONNECT.
- No warm-up or drain outage.
- Duplicate handling across reconnects.
- Warm-up exclusion from Miss Rate.
- Drain-period recovery inclusion.
- Invalidity on missing events, overflow, client failure, or incomplete drain.

Use a few subscribers and short 5–10 second cycles for integration testing.
For those shortened cycles only, scale the five-second boundary to half of the
available ON time; the 100-second measured schedules retain the specified
five-second boundary exactly.

## 9. Suggested Commands

### Subscriber

```bash
./target/release/mq-bench --snapshot-interval 1 mt-sub \
  --engine mqtt \
  --connect "host=${HOST}" \
  --connect "port=${PORT}" \
  --connect "client_id=${SUB_CID}" \
  --connect "qos=${QOS}" \
  --connect "clean_session=${CLEAN_SESSION}" \
  --topic-prefix "${TOPIC_PREFIX}" \
  --tenants 10 --regions 10 --services 10 --shards 1 \
  --subscribers 1000 --mapping mdim \
  --duration 480 \
  --availability-schedule "${SCHEDULE_CSV}" \
  --availability-start-delay 60 \
  --final-drain-secs 120 \
  --subscriber-events "${ART_DIR}/subscriber_events.csv" \
  --receive-trace "${ART_DIR}/receive_trace.csv" \
  --csv "${ART_DIR}/sub.csv" \
  --enable-retry
```

The exact dimension tuple may differ if it still multiplies to 1,000 and maps
global indices deterministically. Freeze and record it for the study.

### Publisher process `p`

```bash
./target/release/mq-bench --snapshot-interval 1 mt-pub \
  --engine mqtt \
  --connect "host=${HOST}" \
  --connect "port=${PORT}" \
  --connect "client_id=${PUB_CID_BASE}-${p}" \
  --connect "qos=${QOS}" \
  --connect "clean_session=true" \
  --topic-prefix "${TOPIC_PREFIX}" \
  --tenants 10 --regions 10 --services 10 --shards 1 \
  --publishers 100 --topic-index-start "$((p * 100))" --mapping mdim \
  --payload 128 --rate 2 --duration 360 \
  --csv "${ART_DIR}/pub_${p}.csv"
```

Smoke-test that `--rate` remains per logical topic before the matrix.

## 10. Artifact Layout

```text
results/mqtt_message_recovery_<timestamp>/
  run_manifest.csv
  schedules/
    dar_<dar>_seed_<seed>.csv
    dar_<dar>_seed_<seed>.sha256
  raw_data/
    <run_id>/
      metadata.json
      status.json
      schedule.csv
      schedule.sha256
      subscriber_events.csv
      receive_trace.csv
      sub.csv
      sub.log
      pub_0.csv ... pub_9.csv
      pub_0.log ... pub_9.log
      docker_stats.csv
      broker.log
      run_summary.csv
      cycle_summary.csv
      dar_timeseries.csv
      validation.json
  summary.csv
  cycle_summary.csv
  plots/
    README.md
    *.png
    *.pdf
```

Metadata must capture mode, DAR, seed, schedule checksum, run order, MQTT
settings, actual commands, topic ranges, phase boundaries, Git/binary checksum,
broker image/config checksum, host details, timestamps, and all exit codes.

## 11. Metric Definitions

The primary cohort contains unique messages published during the three cycles.
Evaluate eventual delivery after the 120-second drain.

### 11.1 Eventual delivery and miss rate

```text
EventualDeliveryRatio =
    unique primary-cohort messages received by drain end
    / unique primary-cohort messages published

MissRate = 1 - EventualDeliveryRatio
```

Use the aggregate publisher `sent_count` delta across the cycles as denominator
and deduplicated receipts as numerator. Record send errors and invalidate
material send failure.

### 11.2 Persistence Recovery Gain

```text
PRG_q1(DAR, seed) =
    MissRate_q1_clean(DAR, seed)
    - MissRate_q1_persistent(DAR, seed)
```

Also calculate `PRG_q0` using the QoS 0 clean control. Positive PRG means
persistence eventually delivered messages the clean session missed.

### 11.3 Offline recovery

Compare receipt send time with the device's actual events:

```text
OfflineRecoveryLatency = first_receive_time - actual_reconnect_time
```

Report median, p95, and p99 by DAR, plus the fraction recovered in the same
cycle, a later cycle, and final drain.

### 11.4 Availability fidelity

```text
ActualDAR = actual online time during cycles / 300 seconds
```

Report requested versus actual DAR per subscriber and run.

### 11.5 Secondary metrics

- Delivery throughput and estimated backlog over time.
- Duplicate ratio.
- Reconnect and session-resumption success.
- Broker CPU/memory by phase.
- Online/offline subscriber counts.

## 12. Expected Results

The expected qualitative pattern is:

- `q0_clean` and `q1_clean` Miss Rate increase as DAR decreases.
- `q1_clean` Miss Rate is approximately `1 - DAR`.
- `q1_persistent` Miss Rate stays near zero if queues/drain are sufficient.
- PRG is near zero at DAR 1.00 and grows as DAR decreases.
- Recovery latency and backlog grow at lower DAR.

Primary-cohort volume is approximately:

```text
2,000 msg/s × 300 s = 600,000 messages
```

| DAR | Offline fraction | Approximate offline-origin messages |
|---:|---:|---:|
| 1.00 | 0.00 | 0 |
| 0.80 | 0.20 | 120,000 |
| 0.60 | 0.40 | 240,000 |
| 0.40 | 0.60 | 360,000 |
| 0.20 | 0.80 | 480,000 |

## 13. Validation Gates

Invalidate and retain a run if:

- Fewer than 1,000 subscribers are confirmed by warm-up end.
- Publisher ranges overlap, omit topics, or exceed bounds.
- A publisher/broker exits before publishing ends.
- The subscriber controller exits before drain end.
- A scheduled event is missing or excessively late.
- Median actual DAR differs from requested DAR by over 1 percentage point.
- Trace overflow/write failure or malformed payload occurs.
- Send error exceeds 0.1% or stable offered rate differs by over 5%.
- Persistent reconnect lacks expected session state.
- Clean reconnect unexpectedly resumes a session.
- Material delivery continues at drain end.
- Timestamps are non-monotonic or produce negative latency.
- Schedule/config checksums differ from the manifest.

Do not overwrite invalid runs. Append replacement attempts to the manifest.

## 14. Analysis and Reporting

The experimental unit is a complete `seed × mode × DAR` run. One-second samples
inside it are not independent replicates.

For each DAR/mode:

- Show all three seed values.
- Report mean and range or median and range, clearly stating `n=3`.
- Use paired seed-level differences for PRG.
- Avoid strong significance claims from only three schedules.
- Report invalid and replacement runs.

Primary paper figures:

1. Miss Rate versus DAR for all modes.
2. PRG versus DAR.
3. Recovery latency versus DAR.
4. A representative online-population, throughput, and backlog timeline.

CPU and memory are secondary in the updated experiment.

## 15. Implementation Order

### Phase A — Scheduler and lifecycle

- [ ] Implement and test schedule generation.
- [ ] Add schedule parsing to `mt-sub`.
- [ ] Implement independent subscriber OFF/ON transitions.
- [ ] Verify hard disconnect and fresh-client reconstruction.
- [ ] Capture actual events and session flags.

### Phase B — Topology and observation

- [ ] Add publisher topic-range partitioning.
- [ ] Prove exact coverage of 1,000 topics.
- [ ] Add duplicate-safe receive tracing.
- [ ] Add warm-up and final-drain barriers.
- [ ] Preserve backward compatibility.

### Phase C — Workflow and analysis

- [ ] Implement the 480-second orchestrator.
- [ ] Add clean broker state, metadata, checksums, stats, and traps.
- [ ] Implement validation and metric analysis.
- [ ] Implement DAR, Miss Rate, PRG, latency, and timeline plots.

### Phase D — Verification

- [ ] Run unit/synthetic tests.
- [ ] Run short three-mode integration tests.
- [ ] Run full pilots.
- [ ] Verify 120 seconds drains DAR 0.20 backlog.
- [ ] Freeze binary, config, image digest, and seeds.

### Phase E — Measured matrix

- [ ] Archive the randomized 45-run manifest.
- [ ] Execute three seed blocks.
- [ ] Validate each run immediately.
- [ ] Retain originals and run replacements for invalid cells.
- [ ] Generate figures and archive artifacts.

## 16. Risks and Mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Wrong 20/2,000 versus 10/1,000 topology | Slides and implementation disagree | Resolve before coding |
| Synchronized outages | Unrealistic population behavior | Per-subscriber schedule matrix |
| New client ID after ON | Persistent backlog disappears | Stable IDs plus CONNACK checks |
| Graceful DISCONNECT | Incorrect power-loss model | Force disconnect and test it |
| QoS 1 duplicates | Biased Miss Rate/PRG | Deduplicate topic and sequence |
| Warm-up included | DAR effect is diluted | Cycle-only primary cohort |
| Scheduled and actual DAR differ | Wrong independent variable | Derive actual DAR from events |
| Publisher ranges overlap | Uneven or missing traffic | Validate exact range union |
| Broker queue limit reached | False protocol failure | Check limits/logs in DAR 0.20 pilot |
| Drain too short | Recovered messages look lost | Verify plateau before freezing design |
| Three seeds overinterpreted | Weak claims | Show all points and paired effects |
