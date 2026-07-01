# MQTT Experiment Design Options

This folder contains different MQTT-focused experiment ideas for `mq-bench`.

Current options:

- `mqtt-offline-queue-experiment-plan.md`
  - strongest MQTT-specific story
  - focuses on subscriber disconnect and recovery
- `mqtt-reliable-publisher-recovery-experiment-plan.md`
  - strong recovery-focused experiment
  - focuses on publisher crash and reconnect
- `mqtt-qos-tradeoff-experiment-plan.md`
  - easy extra experiment to run
  - focuses on QoS 0 vs 1 vs 2
- `mqtt-wildcard-aggregation-experiment-plan.md`
  - easy to explain
  - focuses on wildcard collector vs exact-topic subscriptions
- `mqtt-lightweight-telemetry-experiment-plan.md`
  - easy steady-state experiment
  - focuses on small-message efficiency
- `mqtt-request-reply-experiment-plan.md`
  - expands beyond pub/sub
  - focuses on edge command/query behavior
- `mqtt-fanin-uplink-experiment-plan.md`
  - very practical workload
  - focuses on many publishers into one collector

Suggested priority:

1. `mqtt-offline-queue-experiment-plan.md`
2. `mqtt-reliable-publisher-recovery-experiment-plan.md`
3. `mqtt-qos-tradeoff-experiment-plan.md`
4. `mqtt-fanin-uplink-experiment-plan.md`
5. `mqtt-wildcard-aggregation-experiment-plan.md`
6. `mqtt-lightweight-telemetry-experiment-plan.md`
7. `mqtt-request-reply-experiment-plan.md`
