# MQTT Lightweight Telemetry Experiment Plan

## Short Idea

This experiment asks a simple question:

- when messages are tiny and sent at a low rate, which broker gives good latency with the lowest CPU and memory cost?

This is a better fit for MQTT than a heavy throughput contest.

## Why This Experiment Is Better

MQTT is often chosen for:

- small sensor updates
- many long-lived clients
- low bandwidth use
- steady reporting over time

So instead of pushing only high-load traffic, this experiment looks at:

- small messages
- many clients
- low publish rate
- resource efficiency

That gives a more balanced picture of MQTT.

## Research Question

For realistic telemetry traffic, how efficient is MQTT in CPU, memory, and latency as client count grows?

## Main Hypothesis

MQTT brokers, especially lightweight ones, should be competitive when:

- payloads are very small
- rates are low
- clients stay connected for a long time

MQTT may not win the highest-throughput race, but it may look very good in efficiency per client and efficiency per delivered message.

## Main Comparison

The primary comparison should be MQTT brokers only.

Suggested brokers:

- Mosquitto
- EMQX
- HiveMQ
- RabbitMQ MQTT
- Artemis MQTT

Optional second figure:

- compare the best MQTT broker against NATS, Redis, Zenoh, and RabbitMQ AMQP

That keeps the main story simple and fair.

## Recommended Workload

Use small payloads and long enough duration to smooth noise.

### Load Levels

Run two message sizes:

- `32 B`
- `64 B`

Run two send rates:

- `1 msg/s` per publisher
- `2 msg/s` per publisher

Run several subscriber counts:

- `500`
- `1000`
- `2000`
- `4000`

Keep the current fanout rule:

- `1 publisher per 100 subscribers`

Suggested duration:

- `120 s`

This is better than a short run because tiny-message telemetry can be noisy over very short windows.

## What We Measure

Main metrics:

- p50 / p95 / p99 latency
- throughput
- broker CPU
- broker memory

Important normalized metrics:

- CPU per 1000 deliveries
- memory per 1000 active clients
- CPU per active client

These normalized metrics make the experiment much stronger.

Without them, we only learn who uses more total resources. With them, we learn who is more efficient.

## Why This Is Good For The Paper

This experiment strengthens the paper because it adds a resource-efficiency angle.

It answers:

- not "who is fastest at maximum load?"
- but "who is efficient for realistic telemetry?"

That is highly relevant for:

- IoT gateways
- edge servers
- industrial telemetry
- environmental monitoring

It also pairs well with your current results:

- current experiments show high-load behavior
- this one shows low-rate efficiency behavior

## Why It Is Implementable In `mq-bench`

This experiment already fits the current repo:

- `scripts/orchestrate_fanout_under_steady_load.sh` supports subscriber scaling
- payload is configurable
- publish rate is configurable
- broker CPU and memory are already collected

So this is the easiest of the three experiments to run.

## Suggested Command Path

Example:

```bash
scripts/orchestrate_fanout_under_steady_load.sh \
  --transports "mqtt" \
  --mqtt-brokers "mosquitto:127.0.0.1:1883 emqx:127.0.0.1:1884 hivemq:127.0.0.1:1885" \
  --subs-list "500 1000 2000 4000" \
  --rate-per-pub 2 \
  --payload 64 \
  --duration 120 \
  --snapshot 1
```

Repeat for `payload=32` and `rate-per-pub=1`.

## Fairness Rules

Use the same:

- subscriber counts
- publisher rule
- payload size
- rate
- duration
- broker host

If you compare MQTT against non-MQTT later, keep the workload exactly the same.

## Good Plots

The best plots are:

- p99 latency vs subscriber count
- broker CPU vs subscriber count
- broker memory vs subscriber count
- CPU per 1000 deliveries
- memory per 1000 active clients

The last two plots are the most valuable because they show efficiency directly.

## Expected Outcome

If MQTT is a strong fit here, we would expect:

- low and stable latency for tiny messages
- moderate CPU growth as clients scale
- reasonable memory growth per active client
- a strong efficiency story for always-on telemetry

## Limitations

This experiment is very practical, but it is not the strongest MQTT-only proof point.

Why:

- some non-MQTT brokers may also perform well on tiny messages
- the result may show MQTT is competitive rather than clearly dominant

So this experiment is best used as:

- the easiest experiment to run
- a good complement to your high-load results
- a strong efficiency-focused addition

## Final Recommendation

Choose this experiment if you want:

- the simplest implementation
- no reconnect logic
- a clear efficiency story
- a realistic small-message telemetry workload
