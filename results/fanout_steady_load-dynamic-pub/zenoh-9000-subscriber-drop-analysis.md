# Why `zenoh` Drops at `9000` Subscribers in `fanout_steady_load`

## Short Answer

The `9000`-subscriber `zenoh` point looks like a backlog and queueing collapse, not a hard crash and not a simple "CPU or RAM ran out" event.

The run:

- reaches all `9000` active subscribers,
- shows no reconnect storm, crash, duplicate, or gap signal in the subscriber aggregate,
- starts near its normal peak throughput,
- then falls into a low-throughput, very-high-latency regime for much of the run.

That pattern is most consistent with an overloaded dispatch or buffering path in the broker or network stack, where the system keeps running but stops keeping up.

## Main Evidence

### 1. The run does not fail to connect

From [summary.csv](/home/cc/projects/mq-bench/results/fanout_steady_load/raw_data/summary.csv:11), the problematic run is:

- `zenoh`
- `payload=1024`
- `subs=9000`
- `rate=900`
- `delivery_rate=8,100,000`

From the raw subscriber aggregate in [sub_agg.csv](/home/cc/projects/mq-bench/artifacts/fanout_steady_20260630_194453_zenoh_p1024_s9000_u90_r10/fanout_singlesite/sub_agg.csv), the connection count ramps all the way up:

- around second `70`, `connections=9000` and `active_connections=9000`
- max observed connections and active connections are both `9000`

So this is not a partial-subscription or incomplete-start problem.

### 2. Throughput starts healthy, then decays badly

The same `sub_agg.csv` shows:

- early peak interval throughput: about `1.295M msg/s`
- median nonzero interval throughput over the run: about `372k msg/s`
- end-of-run interval throughput: about `218k msg/s`

This is the important shape:

- the run does not start broken,
- it briefly reaches its best region,
- then it degrades and spends most of the run below that peak.

By contrast:

- the `8000`-subscriber run has median nonzero interval throughput of about `1.228M msg/s`
- the `10000`-subscriber run has median nonzero interval throughput of about `717k msg/s`

So `9000` is the worst instability point among the three nearby `zenoh` runs.

### 3. Latency explodes while messages are still arriving

In the `9000` run, interval P99 latency rises from under `2 s` early in the steady window to roughly `68 s` later in the run.

Examples from [sub_agg.csv](/home/cc/projects/mq-bench/artifacts/fanout_steady_20260630_194453_zenoh_p1024_s9000_u90_r10/fanout_singlesite/sub_agg.csv):

- early high-throughput interval: about `1.295M msg/s`, interval P99 about `1.66 s`
- around index `90`: about `546k msg/s`, interval P99 about `25.7 s`
- around index `100`: about `97k msg/s`, interval P99 about `37.7 s`
- later intervals: interval P99 remains around `67-68 s`

That is a textbook backlog signal:

- the system is still delivering messages,
- but it is increasingly late,
- so effective throughput across the fixed benchmark window collapses.

### 4. No gaps, duplicates, or explicit errors appear

The final subscriber counters in the `9000` run show:

- `duplicate_count=0`
- `gap_count=0`

The subscriber log [sub.log](/home/cc/projects/mq-bench/artifacts/fanout_steady_20260630_194453_zenoh_p1024_s9000_u90_r10/fanout_singlesite/sub.log) does not show obvious:

- `WARN`
- `ERROR`
- `panic`
- repeated connect failures

So the failure mode is not "messages were visibly dropped by the subscriber logic" and not "the process crashed".

### 5. CPU and memory are not fully exhausted, but that does not rule out saturation

The host-level summary row reports for the `9000` run:

- `avg_cpu_perc = 204.55`
- `max_cpu_perc = 391.76`
- `avg_mem_perc = 11.72`
- `max_mem_perc = 27.51`

That means total machine CPU and memory were not exhausted.

But the raw router stats in [docker_stats.csv](/home/cc/projects/mq-bench/artifacts/fanout_steady_20260630_194453_zenoh_p1024_s9000_u90_r10/fanout_singlesite/docker_stats.csv) show a more nuanced picture:

- memory rises from a few hundred MiB into roughly `1.0-2.1 GiB` territory,
- network TX keeps increasing,
- router CPU becomes high and uneven rather than cleanly pinned.

This supports a narrower bottleneck such as:

- broker internal queue growth,
- fan-out dispatch inefficiency,
- socket or kernel buffer backpressure,
- container or VM networking overhead,
- a hot path that stops scaling smoothly once offered load crosses a threshold.

## Why `9000` Is Worse Than `8000`

The `9000` point is not just "1000 more subscribers".

It also increases offered load:

- `8000` subscribers at `800 msg/s` target `6.4M` deliveries/s
- `9000` subscribers at `900 msg/s` target `8.1M` deliveries/s

So the step from `8000` to `9000` increases both:

- fan-out width,
- and source rate

That makes it plausible that `9000` crosses a nonlinear queueing threshold:

- `8000` stays in a mostly sustainable regime,
- `9000` enters runaway backlog,
- `10000` is still overloaded, but behaves differently enough that it is not simply monotonic collapse.

## Is This a Raw Network Limit?

Probably not by itself.

The repo's host-to-host bandwidth note in [baremetal-vm-network-bandwidth.md](/home/cc/projects/mq-bench/docs/baremetal-vm-network-bandwidth.md:24) reports:

- baremetal -> VM: about `18.1 Gbit/s`
- VM -> baremetal: about `23.5 Gbit/s`

The same note explicitly says available capacity is well above `10 Gbit/s` and can approach the `25GbE` link rate in the VM -> baremetal direction ([baremetal-vm-network-bandwidth.md](/home/cc/projects/mq-bench/docs/baremetal-vm-network-bandwidth.md:68)).

For the `9000` `zenoh` point:

- average TX in the summary is about `3.32 Gbit/s`
- max TX in the summary is about `11.52 Gbit/s`

Those values are below the measured host-to-host ceiling.

So the evidence does not support "the physical link simply saturated and stayed pinned". A better reading is:

- some combination of broker, container, VM, and network-stack overhead became unstable before the physical link hit its practical peak.

## Best Interpretation

The most defensible conclusion is:

> The `zenoh` `9000`-subscriber drop is a backlog-dominated overload event. The run reaches full connection count and initially delivers at a high rate, but then latency grows into the tens of seconds, effective interval throughput collapses, and the system spends much of the run draining queued work rather than sustaining the offered fan-out rate.

This is not well described as:

- a crash,
- a missing-subscriber issue,
- a simple CPU exhaustion event,
- or a clean physical-NIC saturation event.

It is better described as:

- queue growth,
- broker or dispatch-path backpressure,
- and loss of steady-state efficiency once the workload crosses a scaling knee.

## Practical Follow-Up

If we want to pin the root cause down more tightly, the next useful checks are:

1. Capture per-process CPU breakdown, not only container totals.
2. Measure socket and queue backlog on the VM during the `8k`, `9k`, and `10k` runs.
3. Repeat `8k`, `9k`, and `10k` several times to see whether `9k` is a stable knee or a noisy instability zone.
4. Run the same sweep with a fixed publisher rate while varying only subscriber count.
5. Run container-local bandwidth tests to separate broker-path overhead from raw host-to-host capacity.

## One-Sentence Summary

The `9000`-subscriber `zenoh` point fails because it crosses into a high-backlog regime where latency explodes and useful throughput decays, even though total host CPU and RAM are not fully consumed.
