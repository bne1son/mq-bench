#!/usr/bin/env bash
set -euo pipefail

# Experiment 4: MQTT persistent-session recovery under intermittent availability.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODES="q0_clean q1_clean q1_persistent"
DAR_LIST="1.0 0.8 0.6 0.4 0.2"
SEEDS="104729 130363 155921"
HOST="127.0.0.1"
HOST_EXPLICIT=0
PORT=1883
START_BROKER=0
SSH_TARGET=""
REMOTE_DIR="~/mq-bench"
REMOTE_CONFIG_PATH=""
SUBSCRIBER_TARGET=""
SUBSCRIBER_DIR="~/hpcc/mq-bench"
PILOT=0
DRY_RUN=0
BINARY="${REPO_ROOT}/target/release/mq-bench"
RESULTS_ROOT=""
SUBSCRIBERS=1000
CYCLES=3
CYCLE_SECS=100
WARMUP_SECS=60
DRAIN_SECS=120
PUBLISHERS=10
TOPICS_PER_PUBLISHER=100
PAYLOAD=128
RATE_PER_TOPIC=2
ACTIVE_PIDS=()
BROKER_CONTAINER=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --modes "..."          Default: ${MODES}
  --dar-list "..."       Default: ${DAR_LIST}
  --seeds "..."          Default: ${SEEDS}
  --pilot                Run the integration test and full pilot cells first
  --host HOST            MQTT host (default: ${HOST})
  --port PORT            MQTT port (default: ${PORT})
  --start-broker         Start a clean, isolated Mosquitto container per run
  --ssh-target USER@HOST Manage the broker over SSH instead of locally
  --remote-dir PATH      Remote repo directory (default: ${REMOTE_DIR})
  --subscriber-target USER@HOST  Run the subscriber on a remote machine
  --subscriber-dir PATH          Remote mq-bench repo directory (default: ${SUBSCRIBER_DIR})
  --binary PATH          mq-bench binary (default: target/release/mq-bench)
  --results-root PATH    Output root (default: results/mqtt_message_recovery_TIMESTAMP)
  --dry-run              Generate schedules/manifest and print commands only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modes) shift; MODES="${1:?missing modes}" ;;
    --dar-list) shift; DAR_LIST="${1:?missing DAR list}" ;;
    --seeds) shift; SEEDS="${1:?missing seeds}" ;;
    --pilot) PILOT=1 ;;
    --host) shift; HOST="${1:?missing host}"; HOST_EXPLICIT=1 ;;
    --port) shift; PORT="${1:?missing port}" ;;
    --start-broker) START_BROKER=1 ;;
    --ssh-target) shift; SSH_TARGET="${1:?missing SSH target}" ;;
    --remote-dir) shift; REMOTE_DIR="${1:?missing remote directory}" ;;
    --binary) shift; BINARY="${1:?missing binary}" ;;
    --results-root) shift; RESULTS_ROOT="${1:?missing results root}" ;;
    --dry-run) DRY_RUN=1 ;;
    --subscriber-target) shift; SUBSCRIBER_TARGET="${1:?missing subscriber target}" ;;
    --subscriber-dir) shift; SUBSCRIBER_DIR="${1:?missing subscriber directory}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "${SSH_TARGET}" ]]; then
  [[ "${SSH_TARGET}" == *@* && "${SSH_TARGET}" != -* && "${SSH_TARGET#*@}" != "" ]] || {
    echo "--ssh-target must be USER@HOST" >&2
    exit 2
  }
  if [[ ${HOST_EXPLICIT} -eq 0 ]]; then HOST="${SSH_TARGET#*@}"; fi
fi

if [[ -z "${RESULTS_ROOT}" ]]; then
  RESULTS_ROOT="${REPO_ROOT}/results/mqtt_message_recovery_$(date -u +%Y%m%d_%H%M%S)"
elif [[ "${RESULTS_ROOT}" != /* ]]; then
  RESULTS_ROOT="${REPO_ROOT}/${RESULTS_ROOT}"
fi

RAW_DIR="${RESULTS_ROOT}/raw_data"
SCHEDULE_DIR="${RESULTS_ROOT}/schedules"
PLOT_DIR="${RESULTS_ROOT}/plots"
MANIFEST="${RESULTS_ROOT}/run_manifest.csv"
mkdir -p "${RAW_DIR}" "${SCHEDULE_DIR}" "${PLOT_DIR}"

cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
  if [[ -n "${BROKER_CONTAINER}" ]]; then
    stop_broker >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

ssh_command() {
  local remote_command quoted_command
  printf -v remote_command '%q ' "$@"
  printf -v quoted_command '%q' "${remote_command}"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_TARGET}" "bash -c ${quoted_command}"
}

subscriber_ssh_command() {
  local remote_command quoted_command
  printf -v remote_command '%q ' "$@"
  printf -v quoted_command '%q' "${remote_command}"
  ssh -o ConnectTimeout=10 "${SUBSCRIBER_TARGET}" "bash -c ${quoted_command}"
}

stop_broker() {
  if [[ -n "${SSH_TARGET}" ]]; then
    ssh_command docker stop "${BROKER_CONTAINER}"
  else
    docker stop "${BROKER_CONTAINER}"
  fi
}

broker_logs() {
  if [[ -n "${SSH_TARGET}" ]]; then
    ssh_command docker logs "${BROKER_CONTAINER}"
  else
    docker logs "${BROKER_CONTAINER}"
  fi
}

check_remote_broker() {
  local remote_config_sha local_config_sha
  ssh_command docker info --format '{{.ServerVersion}}' >/dev/null
  IFS=
}
command -v python3 >/dev/null
command -v sha256sum >/dev/null
if [[ ${DRY_RUN} -eq 0 && ! -x "${BINARY}" ]]; then
  echo "Binary is missing or not executable: ${BINARY}" >&2
  echo "Build it with: cargo build --release --no-default-features --features transport-mqtt" >&2
  exit 2
fi
if [[ -n "${SSH_TARGET}" && ${DRY_RUN} -eq 0 ]]; then command -v ssh >/dev/null; fi
if [[ -n "${SUBSCRIBER_TARGET}" ]]; then
  [[ "${SUBSCRIBER_TARGET}" == *@* && "${SUBSCRIBER_TARGET}" != -* && "${SUBSCRIBER_TARGET#*@}" != "" ]] || {
    echo "--subscriber-target must be USER@HOST" >&2
    exit 2
  }
fi
if [[ ${START_BROKER} -eq 1 ]]; then
  if [[ -n "${SSH_TARGET}" ]]; then
    if [[ ${DRY_RUN} -eq 0 ]]; then check_remote_broker; fi
  else
    command -v docker >/dev/null
    [[ "${HOST}" == "127.0.0.1" || "${HOST}" == "localhost" ]] || {
      echo "--start-broker requires a local --host, or --ssh-target USER@HOST" >&2
      exit 2
    }
  fi
fi

for mode in ${MODES}; do
  case "${mode}" in q0_clean|q1_clean|q1_persistent) ;; *)
    echo "Unknown mode: ${mode}" >&2; exit 2 ;;
  esac
done

generate_schedule() {
  local dar="$1" seed="$2"
  local stem="dar_${dar}_seed_${seed}"
  local output="${SCHEDULE_DIR}/${stem}.csv"
  if [[ ! -f "${output}" ]]; then
    python3 "${SCRIPT_DIR}/generate_mqtt_availability_schedule.py" --subscribers "${SUBSCRIBERS}" --cycles "${CYCLES}" --cycle-secs "${CYCLE_SECS}" --dar "${dar}" --seed "${seed}" --out "${output}" >/dev/null
  fi
  printf '%s\n' "${output}"
}

for seed in ${SEEDS}; do
  for dar in ${DAR_LIST}; do generate_schedule "${dar}" "${seed}" >/dev/null; done
done
if [[ ${PILOT} -eq 1 ]]; then
  for dar in 0.6 0.2; do generate_schedule "${dar}" 196613 >/dev/null; done
fi

MODES_ENV="${MODES}" DARS_ENV="${DAR_LIST}" SEEDS_ENV="${SEEDS}" PILOT_ENV="${PILOT}" python3 - "${MANIFEST}" <<'PY'
import csv, os, random, sys
out = sys.argv[1]
modes = os.environ["MODES_ENV"].split()
dars = os.environ["DARS_ENV"].split()
seeds = [int(x) for x in os.environ["SEEDS_ENV"].split()]
rows = []
order = 0
if os.environ["PILOT_ENV"] == "1":
    pilots = [(m, "0.6", 196613) for m in modes] + [("q1_persistent", "0.2", 196613)]
    for mode, dar, seed in pilots:
        rows.append([order, "pilot", mode, dar, seed, "planned", ""])
        order += 1
for seed in seeds:
    cells = [(mode, dar) for mode in modes for dar in dars]
    random.Random(seed).shuffle(cells)
    for mode, dar in cells:
        rows.append([order, "measured", mode, dar, seed, "planned", ""])
        order += 1
with open(out, "w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(["run_order", "run_kind", "mode", "dar", "seed", "status", "run_id"])
    writer.writerows(rows)
PY

update_manifest() {
  local order="$1" status="$2" run_id="$3"
  python3 - "${MANIFEST}" "${order}" "${status}" "${run_id}" <<'PY'
import csv, os, sys, tempfile
path, order, status, run_id = sys.argv[1:]
with open(path, newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
fields = list(rows[0]) if rows else ["run_order","run_kind","mode","dar","seed","status","run_id"]
for row in rows:
    if row["run_order"] == order:
        row["status"], row["run_id"] = status, run_id
fd, temp = tempfile.mkstemp(prefix=".manifest.", dir=os.path.dirname(path), text=True)
with os.fdopen(fd, "w", newline="", encoding="utf-8") as stream:
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader(); writer.writerows(rows)
os.replace(temp, path)
PY
}

wait_for_port() {
  python3 - "${HOST}" "${PORT}" <<'PY'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
for _ in range(120):
    try:
        with socket.create_connection((host, port), timeout=.5):
            raise SystemExit(0)
    except OSError:
        time.sleep(.5)
raise SystemExit("MQTT port did not become ready")
PY
}

start_clean_broker() {
  local art_dir="$1" run_id="$2"
  BROKER_CONTAINER="mqb-recovery-${run_id//[^a-zA-Z0-9_.-]/-}"
  if [[ -n "${SSH_TARGET}" ]]; then
    ssh_command docker run -d --rm --name "${BROKER_CONTAINER}" -p "${PORT}:1883" -v "${REMOTE_CONFIG_PATH}:/mosquitto/config/mosquitto.conf:ro" --tmpfs /mosquitto/data:rw eclipse-mosquitto:2 >"${art_dir}/broker.container_id"
  else
    docker run -d --rm --name "${BROKER_CONTAINER}" -p "${PORT}:1883" -v "${REPO_ROOT}/config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" --tmpfs /mosquitto/data:rw eclipse-mosquitto:2 >"${art_dir}/broker.container_id"
  fi
  wait_for_port
}

sample_local_broker() {
  local output="$1" container="$2" duration="$3"
  local end=$(( $(date +%s) + duration ))
  echo "timestamp,container,cpu_perc,mem_perc,mem_usage,net_rx_b,net_tx_b" >"${output}"
  while [[ $(date +%s) -lt ${end} ]]; do
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemPerc}},{{.MemUsage}},{{.NetIO}}' "${container}" 2>/dev/null |
      awk -v ts="$(date +%s)" -F, '{print ts "," $0 ",,"}' >>"${output}" || true
    sleep 1
  done
}

write_status() {
  local path="$1" status="$2" reason="$3"
  python3 - "${path}" "${status}" "${reason}" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"status": sys.argv[2], "reason": sys.argv[3]}, stream, indent=2)
    stream.write("\n")
PY
}

abort_current_run() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do kill "${pid}" 2>/dev/null || true; done
  for pid in "${ACTIVE_PIDS[@]:-}"; do wait "${pid}" 2>/dev/null || true; done
  ACTIVE_PIDS=()
  if [[ -n "${BROKER_CONTAINER}" ]]; then
    stop_broker >/dev/null 2>&1 || true
    BROKER_CONTAINER=""
  fi
}

run_one() {
  local order="$1" kind="$2" mode="$3" dar="$4" seed="$5"
  local run_id="mqtt_recovery_${kind}_o${order}_${mode}_dar${dar}_s${seed}"
  local art_dir="${RAW_DIR}/${run_id}"
  local schedule
  schedule="$(generate_schedule "${dar}" "${seed}")"
  mkdir -p "${art_dir}"
  cp "${schedule}" "${art_dir}/schedule.csv"
  cp "${schedule%.csv}.sha256" "${art_dir}/schedule.source.sha256"
  local schedule_sha
  schedule_sha="$(sha256sum "${art_dir}/schedule.csv" | awk '{print $1}')"
  printf '%s  schedule.csv\n' "${schedule_sha}" >"${art_dir}/schedule.sha256"
  local qos=1 clean_session=true
  case "${mode}" in
    q0_clean) qos=0; clean_session=true ;;
    q1_clean) qos=1; clean_session=true ;;
    q1_persistent) qos=1; clean_session=false ;;
  esac
  update_manifest "${order}" running "${run_id}"

  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "[dry-run] ${run_id}: mode=${mode} dar=${dar} seed=${seed}"
    update_manifest "${order}" planned "${run_id}"
    return 0
  fi

  if [[ ${START_BROKER} -eq 1 ]]; then
    start_clean_broker "${art_dir}" "${run_id}"
  else
    wait_for_port
  fi

  local duration=$((WARMUP_SECS + CYCLES * CYCLE_SECS + DRAIN_SECS))
  local publishing_duration=$((WARMUP_SECS + CYCLES * CYCLE_SECS))
  local stats_pid=""
  local stats_container="${BROKER_CONTAINER:-mosquitto}"
  if [[ -n "${SSH_TARGET}" ]]; then
    "${SCRIPT_DIR}/collect_remote_docker_stats.sh" "${SSH_TARGET}" "${art_dir}/docker_stats.csv" "$((duration + 5))" --extended --containers "${stats_container}" >"${art_dir}/docker_stats.log" 2>&1 &
    stats_pid=$!
    ACTIVE_PIDS+=("${stats_pid}")
  elif [[ "${HOST}" == "127.0.0.1" || "${HOST}" == "localhost" ]]; then
    sample_local_broker "${art_dir}/docker_stats.csv" "${stats_container}" "$((duration + 5))" &
    stats_pid=$!
    ACTIVE_PIDS+=("${stats_pid}")
  fi
  local topic_prefix="bench/recovery/${run_id}"
  local controller_launch_ns
  controller_launch_ns="$(date +%s%N)"
  local sub_pid
local remote_art_dir="${SUBSCRIBER_DIR}/results/remote_subscriber/${run_id}"

if [[ -n "${SUBSCRIBER_TARGET}" ]]; then
  # Prepare this run on the subscriber machine.
  subscriber_ssh_command mkdir -p "${remote_art_dir}"

  # Copy the availability schedule to the subscriber machine.
  scp "${art_dir}/schedule.csv" \
    "${SUBSCRIBER_TARGET}:${remote_art_dir}/schedule.csv"

  local sub_cmd=(
    "${SUBSCRIBER_DIR}/target/release/mq-bench"
    --run-id "${run_id}" --snapshot-interval 1 mt-sub
    --engine mqtt --connect "host=${HOST}" --connect "port=${PORT}"
    --connect "client_id=sub-${run_id}" --connect "qos=${qos}"
    --connect "clean_session=${clean_session}" --topic-prefix "${topic_prefix}"
    --tenants 10 --regions 10 --services 10 --shards 1
    --subscribers "${SUBSCRIBERS}" --mapping mdim --duration "${duration}"
    --availability-schedule "${remote_art_dir}/schedule.csv"
    --availability-start-delay "${WARMUP_SECS}" --final-drain-secs "${DRAIN_SECS}"
    --subscriber-events "${remote_art_dir}/subscriber_events.csv"
    --receive-trace "${remote_art_dir}/receive_trace.csv"
    --availability-ready "${remote_art_dir}/availability_ready"
    --csv "${remote_art_dir}/sub.csv" --enable-retry
  )

  printf 'REMOTE %q ' "${sub_cmd[@]}" >"${art_dir}/commands.txt"
  printf '\n' >>"${art_dir}/commands.txt"

  subscriber_ssh_command "${sub_cmd[@]}" >"${art_dir}/sub.log" 2>&1 &
  sub_pid=$!

else
  local sub_cmd=(
    "${BINARY}" --run-id "${run_id}" --snapshot-interval 1 mt-sub
    --engine mqtt --connect "host=${HOST}" --connect "port=${PORT}"
    --connect "client_id=sub-${run_id}" --connect "qos=${qos}"
    --connect "clean_session=${clean_session}" --topic-prefix "${topic_prefix}"
    --tenants 10 --regions 10 --services 10 --shards 1
    --subscribers "${SUBSCRIBERS}" --mapping mdim --duration "${duration}"
    --availability-schedule "${art_dir}/schedule.csv"
    --availability-start-delay "${WARMUP_SECS}" --final-drain-secs "${DRAIN_SECS}"
    --subscriber-events "${art_dir}/subscriber_events.csv"
    --receive-trace "${art_dir}/receive_trace.csv"
    --availability-ready "${art_dir}/availability_ready"
    --csv "${art_dir}/sub.csv" --enable-retry
  )

  printf '%q ' "${sub_cmd[@]}" >"${art_dir}/commands.txt"
  printf '\n' >>"${art_dir}/commands.txt"

  "${sub_cmd[@]}" >"${art_dir}/sub.log" 2>&1 &
  sub_pid=$!
fi

ACTIVE_PIDS+=("${sub_pid}")
  local setup_deadline=$(( $(date +%s) + 120 ))
local subscriber_start_ns=""

while [[ $(date +%s) -lt ${setup_deadline} ]]; do
  # The local process is either mt-sub itself or the SSH session running mt-sub.
  if ! kill -0 "${sub_pid}" 2>/dev/null; then
    write_status "${art_dir}/status.json" failed "subscriber exited before readiness barrier"
    update_manifest "${order}" failed "${run_id}"
    abort_current_run
    return 1
  fi

  if [[ -n "${SUBSCRIBER_TARGET}" ]]; then
    subscriber_start_ns="$(
      subscriber_ssh_command cat "${remote_art_dir}/availability_ready" 2>/dev/null || true
    )"

    if [[ -n "${subscriber_start_ns}" ]]; then
      subscriber_start_ns="$(printf '%s' "${subscriber_start_ns}" | tr -d '[:space:]')"
      break
    fi
  else
    if [[ -s "${art_dir}/availability_ready" ]]; then
      subscriber_start_ns="$(tr -d '[:space:]' <"${art_dir}/availability_ready")"
      break
    fi
  fi

  sleep 0.1
done

if [[ -z "${subscriber_start_ns}" ]]; then
  write_status "${art_dir}/status.json" failed "subscriber readiness barrier timed out"
  update_manifest "${order}" failed "${run_id}"
  abort_current_run
  return 1
fi
  local pub_pids=()
  local publisher
  for ((publisher=0; publisher<PUBLISHERS; publisher++)); do
    local pub_cmd=(
      "${BINARY}" --run-id "${run_id}-p${publisher}" --snapshot-interval 1 mt-pub
      --engine mqtt --connect "host=${HOST}" --connect "port=${PORT}"
      --connect "client_id=pub-${run_id}-${publisher}" --connect "qos=${qos}"
      --connect "clean_session=true" --topic-prefix "${topic_prefix}"
      --tenants 10 --regions 10 --services 10 --shards 1
      --publishers "${TOPICS_PER_PUBLISHER}"
      --topic-index-start "$((publisher * TOPICS_PER_PUBLISHER))" --mapping mdim
      --payload "${PAYLOAD}" --rate "${RATE_PER_TOPIC}"
      --duration "${publishing_duration}" --csv "${art_dir}/pub_${publisher}.csv"
    )
    printf '%q ' "${pub_cmd[@]}" >>"${art_dir}/commands.txt"; printf '\n' >>"${art_dir}/commands.txt"
    "${pub_cmd[@]}" >"${art_dir}/pub_${publisher}.log" 2>&1 &
    pub_pids+=("$!")
    ACTIVE_PIDS+=("$!")
  done

  SSH_TARGET_ENV="${SSH_TARGET}" REMOTE_DIR_ENV="${REMOTE_DIR}" python3 - "${art_dir}/metadata.json" <<PY
import hashlib, json, os, platform, subprocess
topic_ranges = [{"publisher": i, "start": i * ${TOPICS_PER_PUBLISHER}, "count": ${TOPICS_PER_PUBLISHER}} for i in range(${PUBLISHERS})]
metadata = {
  "format_version": 1, "run_id": "${run_id}", "run_order": ${order}, "run_kind": "${kind}",
  "mode": "${mode}", "dar": float("${dar}"), "seed": ${seed},
  "host": "${HOST}", "port": ${PORT}, "qos": ${qos}, "clean_session": "${clean_session}" == "true",
  "subscribers": ${SUBSCRIBERS}, "cycles": ${CYCLES}, "cycle_secs": ${CYCLE_SECS},
  "warmup_secs": ${WARMUP_SECS}, "final_drain_secs": ${DRAIN_SECS},
  "controller_launch_ns": ${controller_launch_ns}, "subscriber_start_ns": ${subscriber_start_ns},
  "publisher_count": ${PUBLISHERS},
  "topics_per_publisher": ${TOPICS_PER_PUBLISHER}, "topic_ranges": topic_ranges,
  "payload_bytes": ${PAYLOAD}, "rate_per_topic": ${RATE_PER_TOPIC},
  "aggregate_rate": ${PUBLISHERS} * ${TOPICS_PER_PUBLISHER} * ${RATE_PER_TOPIC},
  "schedule_sha256": "${schedule_sha}", "topic_prefix": "${topic_prefix}",
  "binary_sha256": hashlib.sha256(open("${BINARY}", "rb").read()).hexdigest(),
  "broker_config_sha256": hashlib.sha256(open("${REPO_ROOT}/config/mosquitto.conf", "rb").read()).hexdigest(),
  "broker_image": "eclipse-mosquitto:2",
  "broker_reset_by_orchestrator": bool(${START_BROKER}),
  "broker_management": "ssh" if os.environ["SSH_TARGET_ENV"] else "local" if ${START_BROKER} else "external",
  "ssh_target": os.environ["SSH_TARGET_ENV"],
  "remote_dir": os.environ["REMOTE_DIR_ENV"] if os.environ["SSH_TARGET_ENV"] else "",
  "actual_commands": open("${art_dir}/commands.txt", encoding="utf-8").read().splitlines(),
  "host_details": {"platform": platform.platform(), "node": platform.node()},
}
try: metadata["git_commit"] = subprocess.check_output(["git", "-C", "${REPO_ROOT}", "rev-parse", "HEAD"], text=True).strip()
except Exception: metadata["git_commit"] = ""
with open("${art_dir}/metadata.json", "w", encoding="utf-8") as stream:
    json.dump(metadata, stream, indent=2, sort_keys=True); stream.write("\n")
PY

  local early_failure=0
  local deadline=$(( $(date +%s) + WARMUP_SECS ))
  local initial_count=0
  while [[ $(date +%s) -lt ${deadline} ]]; do
    if ! kill -0 "${sub_pid}" 2>/dev/null; then
      write_status "${art_dir}/status.json" failed "subscriber exited during warm-up"
      early_failure=1
      break
    fi
    for pid in "${pub_pids[@]}"; do
      if ! kill -0 "${pid}" 2>/dev/null; then
        write_status "${art_dir}/status.json" failed "publisher exited during warm-up"
        early_failure=1
        break
      fi
    done
    [[ ${early_failure} -ne 0 ]] && break
    if [[ -n "${SUBSCRIBER_TARGET}" ]]; then
  initial_count="$(
    subscriber_ssh_command awk -F, \
      'NR>1 && $5=="initial_connect" && $8=="ok"{n++} END{print n+0}' \
      "${remote_art_dir}/subscriber_events.csv" 2>/dev/null || echo 0
  )"
else
  if [[ -f "${art_dir}/subscriber_events.csv" ]]; then
    initial_count="$(
      awk -F, 'NR>1 && $5=="initial_connect" && $8=="ok"{n++} END{print n+0}' \
        "${art_dir}/subscriber_events.csv"
    )"
  fi
fi

[[ "${initial_count}" -eq "${SUBSCRIBERS}" ]] && break
    sleep 1
  done
  if [[ "${initial_count}" -ne "${SUBSCRIBERS}" ]]; then
    write_status "${art_dir}/status.json" invalid "only ${initial_count}/${SUBSCRIBERS} subscribers confirmed during warm-up"
  fi

  local expected_publish_end=$(( ${subscriber_start_ns:0:10} + publishing_duration - 5 ))
  while [[ ${early_failure} -eq 0 && $(date +%s) -lt ${expected_publish_end} ]]; do
    if ! kill -0 "${sub_pid}" 2>/dev/null; then
      early_failure=1
      break
    fi
    for pid in "${pub_pids[@]}"; do
      if ! kill -0 "${pid}" 2>/dev/null; then early_failure=1; break 2; fi
    done
    sleep 1
  done
  if [[ ${early_failure} -ne 0 ]]; then
    for pid in "${pub_pids[@]}" "${sub_pid}"; do kill "${pid}" 2>/dev/null || true; done
  fi
  local pub_exit_codes=()
  local pid
  for pid in "${pub_pids[@]}"; do
    if wait "${pid}"; then pub_exit_codes+=(0); else pub_exit_codes+=("$?"); early_failure=1; fi
  done
local sub_exit_code=0
if wait "${sub_pid}"; then
  sub_exit_code=0
else
  sub_exit_code=$?
  early_failure=1
fi
  if [[ -n "${SUBSCRIBER_TARGET}" ]]; then
  scp \
    "${SUBSCRIBER_TARGET}:${remote_art_dir}/subscriber_events.csv" \
    "${SUBSCRIBER_TARGET}:${remote_art_dir}/receive_trace.csv" \
    "${SUBSCRIBER_TARGET}:${remote_art_dir}/sub.csv" \
    "${SUBSCRIBER_TARGET}:${remote_art_dir}/availability_ready" \
    "${art_dir}/"
fi
  if [[ -n "${stats_pid}" ]]; then kill "${stats_pid}" 2>/dev/null || true; wait "${stats_pid}" 2>/dev/null || true; fi
  ACTIVE_PIDS=()

  local pub_codes_csv
  pub_codes_csv="$(IFS=,; echo "${pub_exit_codes[*]}")"
  python3 - "${art_dir}/metadata.json" "${sub_exit_code}" "${pub_codes_csv}" "${early_failure}" <<'PY'
import json, sys
path, sub_code, pub_codes, early = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
data = json.load(open(path, encoding="utf-8"))
data["exit_codes"] = {"subscriber": sub_code}
data["exit_codes"].update({f"publisher_{i}": int(code) for i, code in enumerate(pub_codes.split(","))})
data["failure_flags"] = {"unexpected_early_exit": bool(early)}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2, sort_keys=True); stream.write("\n")
PY
  if [[ ${START_BROKER} -eq 1 ]]; then
    broker_logs >"${art_dir}/broker.log" 2>&1 || true
    if ! stop_broker >/dev/null; then
      echo "Could not stop broker ${BROKER_CONTAINER} on ${SSH_TARGET:-local Docker}; refusing to start the next run" >&2
      exit 1
    fi
    BROKER_CONTAINER=""
  fi
  if [[ ${early_failure} -ne 0 ]]; then
    write_status "${art_dir}/status.json" failed "one or more benchmark children failed"
    update_manifest "${order}" failed "${run_id}"
    return 1
  fi

  local analyze_rc=0
  python3 "${SCRIPT_DIR}/analyze_mqtt_message_recovery.py" --run-dir "${art_dir}" >"${art_dir}/analyzer.log" 2>&1 || analyze_rc=$?
  if [[ ${analyze_rc} -eq 0 && "${initial_count}" -eq "${SUBSCRIBERS}" ]]; then
    write_status "${art_dir}/status.json" complete ""
    update_manifest "${order}" complete "${run_id}"
  else
    write_status "${art_dir}/status.json" invalid "artifact validation failed"
    update_manifest "${order}" invalid "${run_id}"
  fi
}

if [[ ${PILOT} -eq 1 && ${DRY_RUN} -eq 0 ]]; then
  "${SCRIPT_DIR}/test_mqtt_message_recovery.sh" --integration
fi

while IFS=, read -r order kind mode dar seed _status _run_id; do
  run_one "${order}" "${kind}" "${mode}" "${dar}" "${seed}" || true
done < <(tail -n +2 "${MANIFEST}")

python3 - "${RAW_DIR}" "${RESULTS_ROOT}/summary.csv" "${RESULTS_ROOT}/cycle_summary.csv" <<'PY'
import csv, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name, output in [("run_summary.csv", pathlib.Path(sys.argv[2])), ("cycle_summary.csv", pathlib.Path(sys.argv[3]))]:
    rows = []
    for path in sorted(root.glob("*/" + name)):
        with path.open(newline="", encoding="utf-8") as stream: rows.extend(csv.DictReader(stream))
    if rows:
        if name == "run_summary.csv":
            keyed = {(r["mode"], r["dar"], r["seed"]): r for r in rows}
            for row in rows:
                row["prg_q1"] = ""
                row["prg_q0"] = ""
                if row["mode"] == "q1_persistent":
                    q1 = keyed.get(("q1_clean", row["dar"], row["seed"]))
                    q0 = keyed.get(("q0_clean", row["dar"], row["seed"]))
                    if q1 and q1.get("miss_rate") and row.get("miss_rate"):
                        row["prg_q1"] = f'{float(q1["miss_rate"]) - float(row["miss_rate"]):.9f}'
                    if q0 and q0.get("miss_rate") and row.get("miss_rate"):
                        row["prg_q0"] = f'{float(q0["miss_rate"]) - float(row["miss_rate"]):.9f}'
        with output.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader(); writer.writerows(rows)
PY

if [[ -f "${RESULTS_ROOT}/summary.csv" && ${DRY_RUN} -eq 0 ]]; then
  python3 "${SCRIPT_DIR}/plot_mqtt_message_recovery.py" --results-root "${RESULTS_ROOT}" --out-dir "${PLOT_DIR}"
fi
echo "Results: ${RESULTS_ROOT}"
