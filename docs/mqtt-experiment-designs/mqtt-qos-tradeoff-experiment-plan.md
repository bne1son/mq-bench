# MQTT QoS Tradeoff Experiment Plan

## Short Idea

This experiment asks a simple question:

- what do we gain, and what do we pay, when we move from MQTT `QoS 0` to `QoS 1` and `QoS 2`?

This is a very natural MQTT experiment because QoS is one of the main reasons people choose MQTT.

## Why This Experiment Is Useful

Many systems choose MQTT because they want a choice between:

- low overhead and best effort
- acknowledged delivery
- stronger delivery guarantees

So this experiment studies the tradeoff directly instead of treating all MQTT traffic the same.

## Research Question

How do MQTT QoS levels change latency, throughput, CPU, memory, message loss, and duplicates under the same workload?

## Main Hypothesis

We expect:

- `QoS 0` to have the lowest overhead
- `QoS 1` to improve delivery reliability with moderate cost
- `QoS 2` to have the highest cost in latency and throughput

The goal is not to make MQTT look best at every metric. The goal is to show that MQTT gives a useful reliability-performance tradeoff.

## Main Comparison

The core comparison is simple:

| Mode | Meaning |
|---|---|
| `QoS 0` | fastest, least reliable |
| `QoS 1` | acknowledged delivery |
| `QoS 2` | strongest delivery semantics |

This should be run first across MQTT brokers only:

- Mosquitto
- EMQX
- HiveMQ
- RabbitMQ MQTT
- Artemis MQTT

## Recommended Workload

Use a balanced workload that is strong enough to show a QoS penalty, but not so strong that all runs collapse into overload.

Suggested starting point:

| Parameter | Value |
|---|---:|
| Topic pairs | `100` |
| Payload | `256 B` and `1024 B` |
| Total rate | `500 msg/s` |
| Duration | `60 s` |
| Warmup | enabled |

This can be scaled later if needed.

## What We Measure

Main metrics:

- p50 / p95 / p99 latency
- publish throughput
- receive throughput
- broker CPU
- broker memory
- message loss
- duplicate count
- gap count

In simple words:

- how much extra reliability do we get,
- and how much extra cost do we pay?

## Why This Is Good For The Paper

This experiment is good for the paper because it explains one of MQTT's most important practical features.

It gives a clean message:

- MQTT is not only a protocol
- it also gives an application-level choice between lighter and stronger delivery modes

That is easy to explain and useful for readers who need to pick a QoS level in practice.

## Why It Is Implementable In `mq-bench`

This experiment is already well supported in the repo:

- `scripts/orchestrate_qos_comparison.sh` already exists
- QoS is already wired into the MQTT transport
- plotting support for QoS already exists

So this is one of the easiest extra experiments to add.

## Suggested Command Path

Example:

```bash
scripts/orchestrate_qos_comparison.sh \
  --qos-levels "0 1 2" \
  --total-rate 500 \
  --pairs 100 \
  --payload 1024
```

You can repeat with a smaller payload like `256 B`.

## Fairness Rules

Keep the same:

- topic count
- payload size
- total rate
- duration
- broker host

Only change the QoS level.

## Good Plots

The best plots are:

- p99 latency by broker and QoS
- throughput by broker and QoS
- loss by broker and QoS
- latency penalty of `QoS 1` and `QoS 2` relative to `QoS 0`

## Expected Outcome

If the experiment works well:

- `QoS 0` should be the lightest mode
- `QoS 1` should offer a good middle ground
- `QoS 2` should be the most expensive mode

This experiment is not as unique as the offline-session design, but it is a strong supporting MQTT experiment because it highlights a core MQTT feature that many readers care about.

## Final Recommendation

Choose this experiment if you want:

- a very easy experiment to run
- a clean MQTT-only result
- a practical paper story around reliability vs overhead
