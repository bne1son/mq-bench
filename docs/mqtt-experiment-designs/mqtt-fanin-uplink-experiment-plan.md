# MQTT Fan-In Uplink Experiment Plan

## Short Idea

This experiment studies the opposite of fanout.

Instead of:

- one publisher to many subscribers

it asks about:

- many publishers to one shared subscriber

This matches an edge uplink pattern where many devices send data to one collector.

## Why This Experiment Is Useful

This is one of the most common MQTT deployment shapes:

- many sensors
- one local broker
- one collector, dashboard, or storage pipeline

So this experiment is very realistic.

It also gives a different view from the current fanout-heavy results.

## Research Question

How does MQTT behave when many publishers send to one shared topic or one shared collector under steady load?

## Main Hypothesis

We expect MQTT to do well in moderate fan-in workloads because they are close to normal telemetry aggregation.

As publisher count grows, we expect:

- broker CPU to rise steadily
- latency to remain acceptable at moderate load
- throughput to scale up to a practical limit

This can show a more natural MQTT-friendly workload than large fanout delivery storms.

## Main Comparison

The simplest comparison is MQTT brokers only:

- Mosquitto
- EMQX
- HiveMQ
- RabbitMQ MQTT
- Artemis MQTT

Optional second comparison:

- compare the best MQTT broker against NATS, Redis, Zenoh, and RabbitMQ AMQP

## Recommended Workload

Use many publishers and one subscriber.

### Suggested Load Levels

Publishers:

- `100`
- `500`
- `1000`
- `2000`

Payloads:

- `64 B`
- `256 B`

Rate per publisher:

- `1 msg/s`
- `2 msg/s`
- `5 msg/s`

Duration:

- `60-120 s`

This gives a clean scaling story without making the workload too artificial.

## What We Measure

Main metrics:

- total receive throughput
- p50 / p95 / p99 latency
- broker CPU
- broker memory
- message loss, if any

In simple words:

- how well does MQTT collect data from many senders into one place?

## Why This Is Good For The Paper

This experiment helps the paper because it adds a very realistic edge pattern:

- uplink convergence
- many devices sending to one sink

That is a better fit for MQTT than only testing large delivery multiplication.

It also creates a good contrast with your existing fanout results:

- fanout asks how brokers replicate messages to many receivers
- fan-in asks how brokers absorb many senders into one collector

## Why It Is Implementable In `mq-bench`

The repo already supports this direction:

- `scripts/orchestrate_fanin_under_steady_load.sh` already exists
- MQTT is already one of the supported transports there
- broker resource collection is already part of the workflow

So this is a direct experiment path.

## Suggested Command Path

Example:

```bash
scripts/orchestrate_fanin_under_steady_load.sh \
  --transports "mqtt" \
  --mqtt-brokers "mosquitto:127.0.0.1:1883 emqx:127.0.0.1:1884" \
  --publishers-list "100 500 1000 2000" \
  --rate-per-pub 2 \
  --payload 64 \
  --duration 120
```

This should already give a useful first result.

## Fairness Rules

Keep the same:

- publisher counts
- payload size
- rate per publisher
- duration
- broker host

Only change the broker or transport.

## Good Plots

The best plots are:

- throughput vs publisher count
- p99 latency vs publisher count
- broker CPU vs publisher count
- broker memory vs publisher count

These four plots should tell the story clearly.

## Expected Outcome

If the experiment works well:

- MQTT should show good performance at moderate uplink fan-in
- some MQTT brokers may look especially strong on small telemetry payloads
- this could give a more natural MQTT-positive result than extreme fanout cases

## Final Recommendation

Choose this experiment if you want:

- a simple and realistic workload
- an experiment that contrasts nicely with your current fanout work
- a very practical "many devices to one sink" story
