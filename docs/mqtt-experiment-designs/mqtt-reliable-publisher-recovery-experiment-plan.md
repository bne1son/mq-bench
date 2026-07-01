# MQTT Reliable Publisher Recovery Experiment Plan

## Short Idea

This experiment focuses on publisher-side failures.

The question is:

- if the publisher crashes and reconnects, can MQTT recover more cleanly when we use the reliable publisher mode?

This is different from the offline-subscriber experiment.

There, the subscriber disappears.
Here, the publisher fails and comes back.

## Why This Experiment Is Useful

Many real systems do not only lose subscribers. They also lose edge publishers:

- device reboot
- process crash
- short network break
- container restart

So this experiment looks at whether MQTT can reduce message gaps when the sender itself is unstable.

## Research Question

Under publisher crash and reconnect, does MQTT's reliable publisher mode reduce message gaps compared with the regular publisher?

## Main Hypothesis

We expect:

- regular publisher to be faster but more likely to show gaps after failures
- reliable publisher to reduce or remove gaps
- reliable publisher to pay a cost in latency or throughput

That is a strong and honest MQTT result: better continuity, but not for free.

## Main Comparison

The main comparison should be:

| Mode | Meaning |
|---|---|
| regular `pub` | faster, simpler send path |
| `rel-pub` | waits for broker ACK before confirming progress |

Run this comparison at:

- `QoS 1`
- `QoS 2`

That gives a clean 2 x 2 view.

## Recommended Workload

Suggested starting point:

| Parameter | Value |
|---|---:|
| Payload | `1024 B` |
| Rate | `100 msg/s` |
| Duration | `60 s` |
| Publisher failures | enabled |
| Subscriber failures | optional secondary case |

Recommended fault settings:

- `MTTF = 10 s`
- `MTTR = 2 s`
- `crash_count = 5`

This should create enough failure events to expose the difference between the two publisher modes.

## What We Measure

Main metrics:

- gap count
- duplicate count
- sent vs received
- p99 latency
- reconnect count
- throughput during recovery

In simple words:

- after failures, which publisher mode keeps the stream more complete?

## Why This Is Good For The Paper

This experiment is useful for the paper because it shows another MQTT-specific strength:

- stateful recovery on the sender side
- not just subscriber-side recovery

It also gives a nice pair with the offline-queue experiment:

- one experiment for unstable subscribers
- one experiment for unstable publishers

That makes the paper feel more complete.

## Why It Is Implementable In `mq-bench`

This experiment is already supported by the repo:

- `rel-pub` exists in the CLI
- `src/roles/reliable_publisher.rs` already implements the logic
- `scripts/test_reliable_publisher.sh` already exists

So this is a real option, not just a future idea.

## Suggested Command Path

For a quick pilot, use the existing script:

```bash
scripts/test_reliable_publisher.sh
```

That script already compares:

- regular publisher
- reliable publisher
- different QoS levels
- crash scenarios

## Fairness Rules

Keep the same:

- payload
- rate
- duration
- crash settings
- broker host
- subscriber behavior

Only change the publisher mode and QoS level.

## Good Plots

The best plots are:

- gap count by mode
- duplicates by mode
- p99 latency by mode
- received / sent ratio by mode

A simple summary table will also work well here.

## Expected Outcome

If the experiment works well:

- reliable publisher should reduce gaps strongly
- `QoS 2` should usually be the safest but most expensive mode
- regular publisher should remain faster but less clean under failure

This is one of the strongest extra ideas because it highlights a specific MQTT recovery feature that is already implemented in the repo.

## Final Recommendation

Choose this experiment if you want:

- a strong MQTT-specific recovery story
- something different from subscriber offline queueing
- a design that reuses existing repo support almost directly
