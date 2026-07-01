# MQTT Wildcard Aggregation Experiment Plan

## Short Idea

This experiment tests a very common MQTT pattern:

- many devices publish to many topic paths
- one collector uses a wildcard to receive everything

To make the experiment stronger, the main comparison should be:

- `1 wildcard collector`
- versus
- `many exact-topic subscriptions`

on the same topic tree.

That makes the experiment much clearer than just "many topics + one subscriber."

## Why This Experiment Is Better

MQTT is widely used with structured topic trees such as:

- `plant1/line1/temp/s1`
- `plant1/line1/temp/s2`
- `plant2/line3/power/s4`

One important practical question is:

- is it efficient to collect all this data with one wildcard subscription?

That is more focused and more useful than a generic multi-topic benchmark.

## Research Question

As topic count grows, how well does MQTT support wildcard-based data collection compared with opening one exact subscription per topic?

## Main Hypothesis

A wildcard collector should provide:

- simpler collection logic
- lower subscription-management overhead
- acceptable latency and throughput at moderate topic counts

Even if it does not always beat every alternative on raw throughput, it may be the cleaner and more efficient operational model.

## Main Comparison

The main figure should stay inside MQTT first.

| Mode | Collector style | Recommended script |
|---|---|---|
| Method A | `1` wildcard subscriber | `scripts/run_multi_topic_fanout.sh` |
| Method B | one exact subscription per topic | `scripts/run_multi_topic_perkey.sh` |

This is stronger than cross-broker comparison because it isolates the collection strategy itself.

Optional cross-broker comparison can come later.

## Recommended Workload

Use a topic tree that looks like a real telemetry layout.

### Topic Counts

Run:

- `100` topics
- `500` topics
- `1000` topics
- `2000` topics

Example dimension choices:

- `10 x 2 x 5 x 1 = 100`
- `10 x 2 x 5 x 5 = 500`
- `10 x 2 x 5 x 10 = 1000`
- `10 x 4 x 5 x 10 = 2000`

### Message Settings

| Parameter | Value |
|---|---:|
| Payload | `128 B` |
| Rate | `2 msg/s` per topic |
| Duration | `60-90 s` |
| Broker | start with `mosquitto` |

This keeps the workload realistic and avoids turning the experiment into a pure overload test.

## What We Measure

Main metrics:

- subscriber throughput
- p50 / p95 / p99 latency
- broker CPU
- broker memory
- message loss, if any

Useful derived view:

- how performance changes as topic count grows

In simple words:

- does wildcard collection stay efficient as the topic tree gets bigger?

## Why This Is Good For The Paper

This experiment is useful because it adds a different kind of MQTT value:

- not persistent sessions
- not just small-message efficiency
- but structured topic-tree collection

This is very easy to explain in a presentation:

"Many sensors publish to many topic paths. One collector uses a wildcard and gathers everything."

That is a real MQTT use case, especially in:

- factories
- buildings
- environmental monitoring
- edge observability systems

## Why It Is Implementable In `mq-bench`

This experiment maps well to the repo:

- `mt-pub` already generates many topics
- `run_multi_topic_fanout.sh` already uses one wildcard subscriber
- `run_multi_topic_perkey.sh` already exercises per-topic subscription style

So the experiment can be run today with little or no Rust work.

## Suggested Command Paths

### Wildcard Collector

```bash
ENGINE=mqtt \
MQTT_HOST=127.0.0.1 \
MQTT_PORT=1883 \
TENANTS=10 \
REGIONS=2 \
SERVICES=5 \
SHARDS=10 \
PUBLISHERS=1000 \
PAYLOAD=128 \
RATE=2 \
DURATION=60 \
scripts/run_multi_topic_fanout.sh
```

### Exact-Topic Subscriptions

```bash
ENGINE=mqtt \
MQTT_HOST=127.0.0.1 \
MQTT_PORT=1883 \
TENANTS=10 \
REGIONS=2 \
SERVICES=5 \
SHARDS=10 \
SUBSCRIBERS=1000 \
PUBLISHERS=1000 \
PAYLOAD=128 \
RATE=2 \
DURATION=60 \
scripts/run_multi_topic_perkey.sh
```

## Fairness Rules

Keep these the same between both methods:

- topic count
- payload size
- publish rate
- run duration
- broker host
- topic prefix

The only thing that should change is the collection method.

## Good Plots

The best plots are:

- p99 latency vs topic count
- broker CPU vs topic count
- broker memory vs topic count
- throughput vs topic count

These plots clearly show whether wildcard collection stays practical at scale.

## Expected Outcome

If the experiment goes well:

- wildcard collection should stay simple and stable at moderate topic counts
- latency should remain acceptable for telemetry-sized messages
- broker CPU and memory should grow more smoothly than a per-topic exact-subscription design

## Limitations

This experiment is good, but not as strong as the offline-session experiment.

Why:

- wildcard routing is not unique to MQTT
- other systems can also support topic-pattern collection

So this experiment is best used as:

- a strong secondary MQTT experiment
- an easy-to-present IoT story
- a practical design comparison inside MQTT

## Final Recommendation

Choose this experiment if you want:

- a simple story
- no disconnect or crash logic
- a clear MQTT topic-tree use case
- a good "collector design" comparison
