# MQTT Request-Reply Experiment Plan

## Short Idea

This experiment asks:

- can MQTT handle simple request-reply well enough for edge control and device query workloads?

Most of the current experiments are pub/sub. This one adds a different communication pattern.

## Why This Experiment Is Useful

Many IoT and edge systems do not only stream telemetry. They also send short commands and queries, such as:

- get current sensor value
- read device status
- request latest summary
- trigger a small action and wait for reply

So this experiment looks at MQTT as a lightweight request-reply transport.

## Research Question

How does MQTT request-reply performance change as request rate, concurrency, and reply size increase?

## Main Hypothesis

We expect MQTT request-reply to work well for:

- small request payloads
- small reply payloads
- moderate request rates
- modest concurrency

We also expect latency to rise as concurrency and reply size increase.

The point of the experiment is not to prove that MQTT is the best RPC system. The point is to show that it can be a practical control-plane choice in edge workloads.

## Main Comparison

The simplest main comparison is MQTT brokers only:

- Mosquitto
- EMQX
- HiveMQ
- RabbitMQ MQTT
- Artemis MQTT

Optional second comparison:

- MQTT vs NATS vs Redis vs Zenoh

That can be useful later because those systems also support request-reply in the repo.

## Recommended Workload

Use small query-style messages.

### Suggested Load Levels

Request rates:

- `100 qps`
- `500 qps`
- `1000 qps`

Concurrency:

- `8`
- `32`
- `64`

Reply sizes:

- `64 B`
- `256 B`
- `1024 B`

Suggested duration:

- `60 s`

This should be enough to show where MQTT request-reply is comfortable and where it starts to stretch.

## What We Measure

Main metrics:

- p50 / p95 / p99 latency
- timeout rate
- successful replies per second
- broker CPU
- broker memory

In simple words:

- how fast are requests,
- how many finish successfully,
- and how much broker resource is needed?

## Why This Is Good For The Paper

This experiment helps the paper because it shows that MQTT is not only a telemetry protocol.

It can support a second edge pattern:

- small control-plane interactions
- point queries
- command/response workflows

That makes the paper broader and more practical.

## Why It Is Implementable In `mq-bench`

The repo already supports request-reply:

- `req` and `qry` roles already exist
- MQTT request and queryable support already exist in `src/transport/mqtt.rs`
- `scripts/run_queries.sh` already exists as a starting point

So this is a real experiment path, not a speculative one.

## Suggested Command Path

A simple manual run could look like this:

```bash
./target/release/mq-bench qry --engine mqtt --connect host=127.0.0.1 --connect port=1883 \
  --serve-prefix bench/topic --reply-size 256 --proc-delay 0

./target/release/mq-bench req --engine mqtt --connect host=127.0.0.1 --connect port=1883 \
  --key-expr bench/topic --qps 500 --concurrency 32 --timeout 2000 --duration 60
```

For a more polished version, it would be good to add a small MQTT-specific request-reply orchestrator.

## Fairness Rules

Keep the same:

- request rate
- concurrency
- reply size
- duration
- timeout
- broker host

Only change the broker or transport.

## Good Plots

The best plots are:

- p99 latency vs request rate
- timeout rate vs request rate
- p99 latency vs concurrency
- broker CPU vs request rate
- broker memory vs request rate

## Expected Outcome

If the experiment works well:

- MQTT should handle moderate request-reply traffic well
- latency should rise with larger replies and higher concurrency
- some MQTT brokers may be good enough for control-plane use even if they are not the best high-QPS query systems

## Final Recommendation

Choose this experiment if you want:

- a non-pub/sub MQTT experiment
- a useful edge control-plane story
- a design that extends the paper beyond telemetry alone
