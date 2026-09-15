#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="${REPO_ROOT}/tests/fixtures/mqtt_message_recovery/valid_q1_clean"
TMP_DIR="$(mktemp -d)"
INTEGRATION=0
[[ "${1:-}" == "--integration" ]] && INTEGRATION=1
BROKER_CONTAINER=""
cleanup() {
  [[ -n "${BROKER_CONTAINER}" ]] && docker stop "${BROKER_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" --subscribers 8 --cycles 3 --cycle-secs 10 --dar 0.6 --seed 104729 --out "${TMP_DIR}/a.csv" >/dev/null
python3 "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" --subscribers 8 --cycles 3 --cycle-secs 10 --dar 0.6 --seed 104729 --out "${TMP_DIR}/b.csv" >/dev/null
cmp "${TMP_DIR}/a.csv" "${TMP_DIR}/b.csv"
python3 - "${TMP_DIR}/a.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
assert len(rows) == 24
assert {(int(r["subscriber_index"]), int(r["cycle_index"])) for r in rows} == {
    (subscriber, cycle) for subscriber in range(8) for cycle in range(3)
}
for row in rows:
    start, end = float(row["off_start_s"]), float(row["off_end_s"])
    cycle = int(row["cycle_index"])
    assert cycle * 10 + 3 <= start <= cycle * 10 + 3
    assert abs(end - start - 4) < 1e-9
PY

python3 "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" --subscribers 8 --cycles 3 --cycle-secs 10 --dar 1.0 --seed 104729 --out "${TMP_DIR}/always.csv" >/dev/null
[[ "$(wc -l < "${TMP_DIR}/always.csv")" -eq 1 ]] || fail "DAR 1.0 emitted outage rows"

cp -R "${FIXTURE}" "${TMP_DIR}/valid"
python3 "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" --run-dir "${TMP_DIR}/valid" >/dev/null
python3 - "${TMP_DIR}/valid/run_summary.csv" <<'PY'
import csv, sys
row = next(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
assert row["published_primary"] == "20"
assert row["unique_delivered_primary"] == "12"
assert abs(float(row["miss_rate"]) - .4) < 1e-9
PY

# Duplicate delivery is counted separately, not as an extra unique delivery.
cp -R "${FIXTURE}" "${TMP_DIR}/duplicate"
sed -n '2p' "${TMP_DIR}/duplicate/receive_trace.csv" >>"${TMP_DIR}/duplicate/receive_trace.csv"
python3 "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" --run-dir "${TMP_DIR}/duplicate" >/dev/null
python3 - "${TMP_DIR}/duplicate/run_summary.csv" <<'PY'
import csv, sys
row = next(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
assert row["unique_delivered_primary"] == "12"
assert row["duplicates"] == "1"
PY

# Warm-up messages are excluded, while a primary message received in drain counts.
cp -R "${FIXTURE}" "${TMP_DIR}/drain"
python3 - "${TMP_DIR}/drain" <<'PY'
import csv, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
meta = json.loads((root / "metadata.json").read_text())
meta["mode"] = "q1_persistent"
(root / "metadata.json").write_text(json.dumps(meta))
events = list(csv.DictReader((root / "subscriber_events.csv").open()))
for row in events:
    if row["event"] == "reconnect_complete":
        row["session_present"] = "true"
with (root / "subscriber_events.csv").open("w", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(events[0])); writer.writeheader(); writer.writerows(events)
with (root / "receive_trace.csv").open("a") as stream:
    stream.write("1001010000000,0,0,99,1001000000000,10000000\n")
    stream.write("1013010000000,0,0,3,1005000000000,8000000000\n")
PY
python3 "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" --run-dir "${TMP_DIR}/drain" >/dev/null
python3 - "${TMP_DIR}/drain/run_summary.csv" <<'PY'
import csv, sys
row = next(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
assert row["unique_delivered_primary"] == "13"
assert row["recovered_final_drain"] == "1"
PY

# Missing drain evidence, child failure, and trace overflow are invalid.
for case_name in missing_drain client_failure trace_overflow; do cp -R "${FIXTURE}" "${TMP_DIR}/${case_name}"; done
sed -i '/forced_online_for_drain/d' "${TMP_DIR}/missing_drain/subscriber_events.csv"
python3 - "${TMP_DIR}/client_failure/metadata.json" "${TMP_DIR}/trace_overflow/metadata.json" <<'PY'
import json, sys
first = json.load(open(sys.argv[1])); first["exit_codes"]["subscriber"] = 1
open(sys.argv[1], "w").write(json.dumps(first))
second = json.load(open(sys.argv[2])); second["failure_flags"] = {"trace_overflow": True}
open(sys.argv[2], "w").write(json.dumps(second))
PY
for case_name in missing_drain client_failure trace_overflow; do
  if python3 "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" --run-dir "${TMP_DIR}/${case_name}" >/dev/null 2>&1; then
    fail "${case_name} fixture was accepted"
  fi
done

# The MQTT crash path must abort the poller and never call MQTT DISCONNECT.
python3 - "${REPO_ROOT}/src/transport/mqtt.rs" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
body = text.split("impl Subscription for MqttSubscription", 1)[1].split("struct MqttQueryRegistration", 1)[0]
assert "self.handle.abort()" in body
assert ".disconnect(" not in body
PY

cargo test --manifest-path "${REPO_ROOT}/Cargo.toml" --no-default-features --features transport-mqtt recovery_partition_tests
bash -n "${SCRIPT_DIR}/orchestrate_mqtt_message_recovery.sh"
python3 -m py_compile "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" "${SCRIPT_DIR}/plot_mqtt_message_recovery.py"

if [[ ${INTEGRATION} -eq 1 ]]; then
  command -v docker >/dev/null || fail "docker is required for --integration"
  cargo build --manifest-path "${REPO_ROOT}/Cargo.toml" --no-default-features --features transport-mqtt
  TEST_BINARY="${REPO_ROOT}/target/debug/mq-bench"
  TEST_PORT="${MQTT_RECOVERY_TEST_PORT:-28883}"
  for mode in q0_clean q1_clean q1_persistent; do
    mode_dir="${TMP_DIR}/live_${mode}"
    mkdir -p "${mode_dir}"
    BROKER_CONTAINER="mqb-recovery-test-${mode}-$$"
    docker run -d --rm --name "${BROKER_CONTAINER}" -p "127.0.0.1:${TEST_PORT}:1883" -v "${REPO_ROOT}/config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" --tmpfs /mosquitto/data:rw eclipse-mosquitto:2 >/dev/null
    python3 - 127.0.0.1 "${TEST_PORT}" <<'PY'
import socket, sys, time
for _ in range(100):
    try:
        socket.create_connection((sys.argv[1], int(sys.argv[2])), .2).close()
        raise SystemExit(0)
    except OSError: time.sleep(.1)
raise SystemExit("test broker did not start")
PY
    python3 "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" --subscribers 4 --cycles 1 --cycle-secs 10 --dar 0.6 --seed 17 --out "${mode_dir}/schedule.csv" >/dev/null
    qos=1; clean=true
    [[ "${mode}" == q0_clean ]] && qos=0
    [[ "${mode}" == q1_persistent ]] && clean=false
    "${TEST_BINARY}" --snapshot-interval 1 mt-sub --engine mqtt --connect host=127.0.0.1 --connect "port=${TEST_PORT}" --connect "client_id=${mode}" --connect "qos=${qos}" --connect "clean_session=${clean}" --topic-prefix "bench/live/${mode}" --tenants 4 --regions 1 --services 1 --shards 1 --subscribers 4 --mapping mdim --duration 15 --availability-schedule "${mode_dir}/schedule.csv" --availability-start-delay 2 --final-drain-secs 3 --subscriber-events "${mode_dir}/events.csv" --receive-trace "${mode_dir}/trace.csv" --availability-ready "${mode_dir}/ready" --csv "${mode_dir}/sub.csv" >"${mode_dir}/sub.log" 2>&1 &
    sub_pid=$!
    for _ in {1..100}; do [[ -s "${mode_dir}/ready" ]] && break; kill -0 "${sub_pid}" 2>/dev/null || fail "live ${mode} subscriber setup failed"; sleep .1; done
    [[ -s "${mode_dir}/ready" ]] || fail "live ${mode} readiness barrier timed out"
    "${TEST_BINARY}" --snapshot-interval 1 mt-pub --engine mqtt --connect host=127.0.0.1 --connect "port=${TEST_PORT}" --connect "client_id=pub-${mode}" --connect "qos=${qos}" --connect clean_session=true --topic-prefix "bench/live/${mode}" --tenants 4 --regions 1 --services 1 --shards 1 --publishers 4 --topic-index-start 0 --mapping mdim --payload 128 --rate 2 --duration 12 --csv "${mode_dir}/pub.csv" >"${mode_dir}/pub.log" 2>&1 &
    pub_pid=$!
    wait "${pub_pid}" || fail "live ${mode} publisher failed"
    wait "${sub_pid}" || fail "live ${mode} subscriber failed"
    expected=false
    [[ "${mode}" == q1_persistent ]] && expected=true
    awk -F, -v expected="${expected}" 'NR>1 && $5=="reconnect_complete"{n++; if($7!=expected || $8!="ok") bad++} END{exit !(n==4 && bad==0)}' "${mode_dir}/events.csv" || fail "live ${mode} CONNACK validation failed"
    docker stop "${BROKER_CONTAINER}" >/dev/null
    BROKER_CONTAINER=""
  done
fi
echo "MQTT message recovery tests passed"
