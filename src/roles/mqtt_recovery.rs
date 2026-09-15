//! Deterministic MQTT subscriber availability controller for Experiment 4.

use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

use crate::metrics::sequence::SequenceTracker;
use crate::metrics::stats::Stats;
use crate::payload::parse_header;
use crate::roles::multi_topic::{MultiTopicSubConfig, map_index};
use crate::time_sync::now_unix_ns_estimate;
use crate::transport::{
    ConnectOptions, Engine, Subscription, SubscriptionConnectionInfo, Transport, TransportBuilder,
};

#[derive(Clone, Debug, Deserialize)]
struct ScheduleRow {
    subscriber_index: u64,
    cycle_index: u32,
    cycle_start_s: f64,
    off_start_s: f64,
    off_end_s: f64,
    off_duration_s: f64,
}

#[derive(Serialize)]
struct SubscriberEvent {
    timestamp_ns: u64,
    elapsed_s: String,
    subscriber_index: u64,
    cycle_index: i64,
    event: &'static str,
    client_id: String,
    session_present: String,
    status: String,
}

struct Receipt {
    receive_ns: u64,
    topic_index: u32,
    header: [u8; 24],
}

type Client = (
    Box<dyn Subscription>,
    Box<dyn Transport>,
    SubscriptionConnectionInfo,
);

fn load_schedule(path: &str, subscribers: u64) -> Result<Vec<Vec<ScheduleRow>>> {
    let mut reader = csv::Reader::from_path(path)
        .with_context(|| format!("open availability schedule {path}"))?;
    let mut by_subscriber: Vec<Vec<ScheduleRow>> = (0..subscribers).map(|_| Vec::new()).collect();
    for decoded in reader.deserialize() {
        let row: ScheduleRow = decoded.context("parse availability schedule row")?;
        ensure!(
            row.subscriber_index < subscribers,
            "schedule subscriber {} is outside 0..{}",
            row.subscriber_index,
            subscribers
        );
        ensure!(
            row.off_start_s.is_finite()
                && row.off_end_s.is_finite()
                && row.off_duration_s.is_finite()
                && row.off_start_s >= row.cycle_start_s
                && row.off_end_s > row.off_start_s
                && (row.off_end_s - row.off_start_s - row.off_duration_s).abs() <= 0.001,
            "invalid outage bounds for subscriber {} cycle {}",
            row.subscriber_index,
            row.cycle_index
        );
        let target = &mut by_subscriber[row.subscriber_index as usize];
        ensure!(
            !target.iter().any(|old| old.cycle_index == row.cycle_index),
            "duplicate outage for subscriber {} cycle {}",
            row.subscriber_index,
            row.cycle_index
        );
        target.push(row);
    }
    for rows in &mut by_subscriber {
        rows.sort_by(|a, b| a.off_start_s.total_cmp(&b.off_start_s));
    }
    let nonempty: Vec<_> = by_subscriber
        .iter()
        .filter(|rows| !rows.is_empty())
        .collect();
    if !nonempty.is_empty() {
        let cycles = nonempty[0].len();
        ensure!(
            by_subscriber.iter().all(|rows| rows.len() == cycles),
            "non-100% DAR schedules require the same outage count for every subscriber"
        );
        for (subscriber, rows) in by_subscriber.iter().enumerate() {
            for (expected_cycle, row) in rows.iter().enumerate() {
                ensure!(
                    row.cycle_index as usize == expected_cycle,
                    "subscriber {subscriber} has a missing or non-contiguous cycle"
                );
            }
        }
    }
    Ok(by_subscriber)
}

fn make_key(config: &MultiTopicSubConfig, index: u64) -> String {
    let (t, r, s, k) = map_index(
        index,
        config.tenants,
        config.regions,
        config.services,
        config.shards,
        config.mapping,
    );
    format!("{}/t{t}/r{r}/svc{s}/k{k}", config.topic_prefix)
}

async fn connect_one(
    engine: Engine,
    connect: ConnectOptions,
    key: &str,
    topic_index: u32,
    receipts: flume::Sender<Receipt>,
    failed: Arc<AtomicBool>,
    stats: Arc<Stats>,
) -> Result<Client> {
    stats.record_connection_attempt();
    let transport = TransportBuilder::connect_with_retry(engine, connect)
        .await
        .map_err(|error| anyhow!("transport connection for {key}: {error}"))?;
    let failed_cb = failed.clone();
    let stats_cb = stats.clone();
    let subscription = transport
        .subscribe(
            key,
            Box::new(move |message| {
                let bytes = message.payload.as_cow();
                if bytes.len() < 24 {
                    failed_cb.store(true, Ordering::Relaxed);
                    stats_cb.error_count.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                let mut header = [0u8; 24];
                header.copy_from_slice(&bytes[..24]);
                if receipts
                    .try_send(Receipt {
                        receive_ns: now_unix_ns_estimate(),
                        topic_index,
                        header,
                    })
                    .is_err()
                {
                    failed_cb.store(true, Ordering::Relaxed);
                    stats_cb.error_count.fetch_add(1, Ordering::Relaxed);
                }
            }),
        )
        .await
        .map_err(|error| anyhow!("subscribe {key}: {error}"))?;
    let info = subscription
        .connection_info()
        .ok_or_else(|| anyhow!("MQTT subscription did not expose CONNACK information"))?;
    stats.increment_connections();
    stats.increment_active_connections();
    Ok((subscription, transport, info))
}

async fn emit(
    sender: &flume::Sender<SubscriberEvent>,
    process_start_ns: u64,
    _start: Instant,
    subscriber: u64,
    cycle: i64,
    event: &'static str,
    info: Option<&SubscriptionConnectionInfo>,
    status: impl Into<String>,
) -> Result<()> {
    let timestamp_ns = if matches!(event, "initial_connect" | "reconnect_complete") {
        info.map(|value| value.connected_at_ns)
            .unwrap_or_else(now_unix_ns_estimate)
    } else {
        now_unix_ns_estimate()
    };
    let elapsed_s = (timestamp_ns as i128 - process_start_ns as i128) as f64 / 1e9;
    sender
        .send_async(SubscriberEvent {
            timestamp_ns,
            elapsed_s: format!("{elapsed_s:.6}"),
            subscriber_index: subscriber,
            cycle_index: cycle,
            event,
            client_id: info
                .map(|value| value.client_id.clone())
                .unwrap_or_default(),
            session_present: info
                .map(|value| value.session_present.to_string())
                .unwrap_or_default(),
            status: status.into(),
        })
        .await
        .map_err(|_| anyhow!("subscriber event writer stopped"))
}

async fn sleep_until(start: tokio::time::Instant, seconds: f64) {
    tokio::time::sleep_until(start + Duration::from_secs_f64(seconds.max(0.0))).await;
}

pub async fn run_scheduled_subscribers(
    config: MultiTopicSubConfig,
    stats: Arc<Stats>,
) -> Result<()> {
    ensure!(
        matches!(config.engine, Engine::Mqtt),
        "--availability-schedule requires MQTT"
    );
    ensure!(
        !config.share_transport,
        "--availability-schedule requires per-subscriber transports"
    );
    ensure!(
        !config.crash_config.is_enabled(),
        "--availability-schedule cannot be combined with --mttf/--mttr crash injection"
    );
    let event_path = config
        .subscriber_events
        .as_deref()
        .context("--subscriber-events is required with --availability-schedule")?;
    let trace_path = config
        .receive_trace
        .as_deref()
        .context("--receive-trace is required with --availability-schedule")?;
    ensure!(
        config.duration_secs > config.final_drain_secs + config.availability_start_delay,
        "duration must include warm-up, measurement cycles, and final drain"
    );
    let total_keys = (config.tenants as u64)
        .saturating_mul(config.regions as u64)
        .saturating_mul(config.services as u64)
        .saturating_mul(config.shards as u64);
    let subscribers = if config.subscribers < 0 {
        total_keys
    } else {
        config.subscribers as u64
    };
    ensure!(
        subscribers <= total_keys,
        "subscriber count exceeds topic dimensions"
    );
    let schedule = load_schedule(
        config.availability_schedule.as_deref().unwrap(),
        subscribers,
    )?;
    let measurement_secs =
        config.duration_secs - config.final_drain_secs - config.availability_start_delay;
    for rows in &schedule {
        for row in rows {
            ensure!(
                row.off_end_s <= measurement_secs as f64,
                "outage ends after the final drain begins"
            );
        }
    }

    for path in [event_path, trace_path] {
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create output directory {}", parent.display()))?;
        }
    }

    let failed = Arc::new(AtomicBool::new(false));
    let (receipt_tx, receipt_rx) = flume::bounded::<Receipt>(1_000_000);
    let trace_path_owned = trace_path.to_string();
    let stats_worker = stats.clone();
    let failed_worker = failed.clone();
    let receipt_worker = tokio::spawn(async move {
        let mut writer = csv::WriterBuilder::new()
            .buffer_capacity(1024 * 1024)
            .from_path(&trace_path_owned)
            .with_context(|| format!("create receive trace {trace_path_owned}"))?;
        writer.write_record([
            "receive_timestamp_ns",
            "subscriber_index",
            "topic_index",
            "sequence",
            "send_timestamp_ns",
            "latency_ns",
        ])?;
        let mut trackers: Vec<SequenceTracker> =
            (0..subscribers).map(|_| SequenceTracker::new()).collect();
        let mut batch = Vec::with_capacity(4096);
        let mut rows_since_flush = 0usize;
        loop {
            let first = match receipt_rx.recv_async().await {
                Ok(value) => value,
                Err(_) => break,
            };
            batch.clear();
            batch.push(first);
            while batch.len() < 4096 {
                match receipt_rx.try_recv() {
                    Ok(value) => batch.push(value),
                    Err(_) => break,
                }
            }
            let mut latencies = Vec::with_capacity(batch.len());
            for receipt in batch.drain(..) {
                let header = match parse_header(&receipt.header) {
                    Ok(value) => value,
                    Err(_) => {
                        failed_worker.store(true, Ordering::Relaxed);
                        continue;
                    }
                };
                let latency = receipt.receive_ns.saturating_sub(header.timestamp_ns);
                trackers[receipt.topic_index as usize].record(header.seq);
                writer.serialize((
                    receipt.receive_ns,
                    receipt.topic_index,
                    receipt.topic_index,
                    header.seq,
                    header.timestamp_ns,
                    latency,
                ))?;
                rows_since_flush += 1;
                latencies.push(latency);
            }
            stats_worker.record_received_batch(&latencies).await;
            if rows_since_flush >= 8192 {
                writer.flush()?;
                rows_since_flush = 0;
            }
        }
        let duplicates = trackers.iter().map(SequenceTracker::duplicate_count).sum();
        let gaps = trackers.iter().map(SequenceTracker::gap_count).sum();
        let head_loss = trackers.iter().map(SequenceTracker::head_loss).sum();
        stats_worker.set_duplicates(duplicates);
        stats_worker.set_gaps(gaps);
        stats_worker.set_head_loss(head_loss);
        writer.flush()?;
        Ok::<(), anyhow::Error>(())
    });

    let (event_tx, event_rx) = flume::bounded::<SubscriberEvent>(50_000);
    let event_path_owned = event_path.to_string();
    let event_worker = tokio::spawn(async move {
        let mut writer = csv::WriterBuilder::new()
            .buffer_capacity(256 * 1024)
            .from_path(&event_path_owned)
            .with_context(|| format!("create subscriber events {event_path_owned}"))?;
        while let Ok(event) = event_rx.recv_async().await {
            writer.serialize(event)?;
            writer.flush()?;
        }
        Ok::<(), anyhow::Error>(())
    });

    let wall_start = Instant::now();
    let (ready_tx, ready_rx) = flume::bounded::<()>(subscribers as usize);
    let (start_tx, start_rx) =
        tokio::sync::watch::channel::<Option<(tokio::time::Instant, u64)>>(None);
    let clean_session = config
        .connect
        .params
        .get("clean_session")
        .map(|value| value != "false" && value != "0")
        .unwrap_or(true);
    let ramp_delay = if config.ramp_up_secs > 0.0 && subscribers > 1 {
        config.ramp_up_secs / (subscribers - 1) as f64
    } else {
        0.0
    };
    let mut tasks = tokio::task::JoinSet::new();
    for (subscriber, outages) in schedule.into_iter().enumerate() {
        let engine = config.engine.clone();
        let connect = config.connect.clone();
        let key = make_key(&config, subscriber as u64);
        let receipts = receipt_tx.clone();
        let events = event_tx.clone();
        let failed_task = failed.clone();
        let stats_task = stats.clone();
        let ready = ready_tx.clone();
        let mut experiment_start = start_rx.clone();
        let initial_delay = ramp_delay * subscriber as f64;
        let warmup = config.availability_start_delay as f64;
        let drain_start = (config.duration_secs - config.final_drain_secs) as f64;
        let run_end = config.duration_secs as f64;
        tasks.spawn(async move {
            if initial_delay > 0.0 {
                tokio::time::sleep(Duration::from_secs_f64(initial_delay)).await;
            }
            let mut client = connect_one(
                engine.clone(),
                connect.clone(),
                &key,
                subscriber as u32,
                receipts.clone(),
                failed_task.clone(),
                stats_task.clone(),
            )
            .await?;
            ready
                .send_async(())
                .await
                .map_err(|_| anyhow!("availability barrier closed"))?;
            drop(ready);
            loop {
                if let Some(value) = *experiment_start.borrow() {
                    let _ = value;
                    break;
                }
                experiment_start
                    .changed()
                    .await
                    .map_err(|_| anyhow!("availability barrier closed"))?;
            }
            let (async_start, process_start_ns) = experiment_start
                .borrow()
                .as_ref()
                .copied()
                .ok_or_else(|| anyhow!("availability barrier missing start time"))?;
            let initial_ok = !client.2.session_present;
            emit(
                &events,
                process_start_ns,
                wall_start,
                subscriber as u64,
                -1,
                "initial_connect",
                Some(&client.2),
                if initial_ok {
                    "ok"
                } else {
                    "unexpected_session_present"
                },
            )
            .await?;
            ensure!(
                initial_ok,
                "initial connection unexpectedly resumed a session"
            );

            for outage in outages {
                sleep_until(async_start, warmup + outage.off_start_s).await;
                ensure!(
                    client.0.connection_failure().is_none(),
                    "subscriber connection failed while scheduled online: {:?}",
                    client.0.connection_failure()
                );
                client.0.force_disconnect().await?;
                client.1.force_disconnect().await?;
                stats_task.decrement_active_connections();
                stats_task.decrement_connections();
                emit(
                    &events,
                    process_start_ns,
                    wall_start,
                    subscriber as u64,
                    outage.cycle_index as i64,
                    "power_off",
                    Some(&client.2),
                    "ok",
                )
                .await?;
                let previous_info = client.2.clone();
                drop(client);

                sleep_until(async_start, warmup + outage.off_end_s).await;
                emit(
                    &events,
                    process_start_ns,
                    wall_start,
                    subscriber as u64,
                    outage.cycle_index as i64,
                    "reconnect_start",
                    Some(&previous_info),
                    "ok",
                )
                .await?;
                client = connect_one(
                    engine.clone(),
                    connect.clone(),
                    &key,
                    subscriber as u32,
                    receipts.clone(),
                    failed_task.clone(),
                    stats_task.clone(),
                )
                .await?;
                let expected_session = !clean_session;
                let session_ok = client.2.session_present == expected_session;
                let stable_id = client.2.client_id == previous_info.client_id;
                emit(
                    &events,
                    process_start_ns,
                    wall_start,
                    subscriber as u64,
                    outage.cycle_index as i64,
                    "reconnect_complete",
                    Some(&client.2),
                    if session_ok && stable_id {
                        "ok"
                    } else if !stable_id {
                        "changed_client_id"
                    } else {
                        "unexpected_session_present"
                    },
                )
                .await?;
                ensure!(
                    stable_id,
                    "subscriber client ID changed across a power cycle"
                );
                ensure!(
                    session_ok,
                    "CONNACK session_present={} but expected {}",
                    client.2.session_present,
                    expected_session
                );
                stats_task.record_reconnect();
            }

            sleep_until(async_start, drain_start).await;
            ensure!(
                client.0.connection_failure().is_none(),
                "subscriber connection failed before final drain: {:?}",
                client.0.connection_failure()
            );
            emit(
                &events,
                process_start_ns,
                wall_start,
                subscriber as u64,
                -1,
                "forced_online_for_drain",
                Some(&client.2),
                "already_online",
            )
            .await?;
            sleep_until(async_start, run_end).await;
            ensure!(
                client.0.connection_failure().is_none(),
                "subscriber connection failed during final drain: {:?}",
                client.0.connection_failure()
            );
            client.0.shutdown().await?;
            client.1.shutdown().await?;
            stats_task.decrement_active_connections();
            stats_task.decrement_connections();
            emit(
                &events,
                process_start_ns,
                wall_start,
                subscriber as u64,
                -1,
                "final_disconnect",
                Some(&client.2),
                "ok",
            )
            .await?;
            Ok::<(), anyhow::Error>(())
        });
    }
    drop(ready_tx);
    for _ in 0..subscribers {
        ready_rx
            .recv_async()
            .await
            .map_err(|_| anyhow!("subscriber failed before the availability barrier"))?;
    }
    let async_start = tokio::time::Instant::now();
    let process_start_ns = now_unix_ns_estimate();
    if let Some(path) = config.availability_ready.as_deref() {
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, format!("{process_start_ns}\n"))
            .with_context(|| format!("write availability-ready file {path}"))?;
    }
    start_tx
        .send(Some((async_start, process_start_ns)))
        .map_err(|_| anyhow!("no subscribers remained at the availability barrier"))?;
    drop(receipt_tx);
    drop(event_tx);

    let mut task_error = None;
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                task_error = Some(error);
                tasks.abort_all();
                break;
            }
            Err(error) => {
                task_error = Some(anyhow!("subscriber task panicked: {error}"));
                tasks.abort_all();
                break;
            }
        }
    }
    while tasks.join_next().await.is_some() {}
    if let Some(error) = task_error {
        receipt_worker
            .await
            .context("receive trace worker panicked")??;
        event_worker
            .await
            .context("subscriber event worker panicked")??;
        return Err(error);
    }
    receipt_worker
        .await
        .context("receive trace worker panicked")??;
    event_worker
        .await
        .context("subscriber event worker panicked")??;
    ensure!(
        !failed.load(Ordering::Relaxed),
        "receive trace overflow or malformed MQTT payload"
    );
    Ok(())
}
