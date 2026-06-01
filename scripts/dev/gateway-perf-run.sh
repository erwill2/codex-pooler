#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

RUN_ROOT="tmp/gateway-perf"
BOOTSTRAP_DIR="$RUN_ROOT/bootstrap"
PERF_ENV_PATH="$BOOTSTRAP_DIR/perf.env"
PROFILE_MANIFEST="$BOOTSTRAP_DIR/profile-manifest.json"
APP_PORT=4000
FAKE_UPSTREAM_PORT=4058
APP_BASE_URL="http://127.0.0.1:${APP_PORT}"
FAKE_UPSTREAM_BASE_URL="http://127.0.0.1:${FAKE_UPSTREAM_PORT}"
POSTGRES_PORT="${POSTGRES_PORT:-5433}"
DURATION_SCALE="1"
REQUESTED_SCENARIO=""
RUN_ID=""
RUN_ID_PROVIDED=false
EXTERNAL_APP=false
DRY_RUN=false
APP_PID=""
FAKE_UPSTREAM_PID=""
RUN_DIR=""
COMMANDS_FILE=""
SCENARIO_RESULTS_FILE=""
SANITIZER_RC=""
BUDGET_TARGET_QPR="20"
BUDGET_TARGET_ACTIVE=false
SELECTED_PATH_FILE=".omo/evidence/gateway-hot-path-selected-path.json"

MEASURED_SCENARIOS=(
  baseline-1c
  backend-short-10c
  v1-short-10c
  short-25c
  long-10c
  large-chunk-5c
  disconnect-10c
  ws-short-10c
  ws-long-10c
  ws-disconnect-10c
  mixed-soak-20m
)

usage() {
  cat <<'EOF'
Usage: scripts/dev/gateway-perf-run.sh [options]

Runs the local gateway performance lifecycle against fake localhost upstreams:
Postgres setup, perf seed/bootstrap, guard check, fake upstream, optional app
startup, warm-up, measured scenarios, cool-down, sanitizer, and top-level summary.

Options:
  --scenario NAME          Run warm-up, exactly one measured scenario, then cool-down.
                           Defaults to the full plan order.
  --duration-scale FLOAT   Multiply measured and cool-down durations only. Default: 1.
  --run-id ID              Use an explicit tmp/gateway-perf/<ID> directory. Must not exist.
  --budget-target-qpr NUM  Mark the run failed with exit 20 when probe QPR is >= NUM.
                            Default target value is 20 for probe reporting; this option activates the runner gate.
  --external-app           Do not start Phoenix; verify http://127.0.0.1:4000/healthz instead.
  --dry-run                Write orchestration, scenario, driver, and summary artifacts without
                           starting Postgres, Phoenix, fake upstreams, or sending traffic.
  --help                   Show this help.

Required for real runs:
  Docker Compose, mix dependencies, Node.js, and local Postgres access.

Real-run behavior:
  - starts db with docker compose -f docker-compose.dev.yml up -d db
  - runs mix ecto.create, mix ecto.migrate, and mix dev.seed perf
  - sources tmp/gateway-perf/bootstrap/perf.env without printing secrets
  - runs scripts/dev/gateway-perf-guard.sh --check before traffic
  - starts fake upstream on 127.0.0.1:4058
  - starts Phoenix on 127.0.0.1:4000 unless --external-app is passed

Scenarios:
  baseline-1c, backend-short-10c, v1-short-10c, short-25c, long-10c,
  large-chunk-5c, disconnect-10c, ws-short-10c, ws-long-10c,
  ws-disconnect-10c, mixed-soak-20m

  mixed-soak-20m is one logical measured scenario that runs both drivers:
  HTTP mixed short-ok concurrency 10 plus websocket mixed short-ok concurrency 10.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log_info() {
  printf '[gateway-perf-run] %s\n' "$*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --scenario)
        [[ $# -ge 2 ]] || fail "--scenario requires a value"
        REQUESTED_SCENARIO="$2"
        shift
        ;;
      --duration-scale)
        [[ $# -ge 2 ]] || fail "--duration-scale requires a value"
        DURATION_SCALE="$2"
        shift
        ;;
      --run-id)
        [[ $# -ge 2 ]] || fail "--run-id requires a value"
        RUN_ID="$2"
        RUN_ID_PROVIDED=true
        shift
        ;;
      --budget-target-qpr)
        [[ $# -ge 2 ]] || fail "--budget-target-qpr requires a value"
        BUDGET_TARGET_QPR="$2"
        BUDGET_TARGET_ACTIVE=true
        shift
        ;;
      --external-app)
        EXTERNAL_APP=true
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      *)
        fail "unknown argument '$1'"
        ;;
    esac
    shift
  done

  validate_duration_scale
  validate_budget_target
  validate_requested_scenario

  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi

  if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "--run-id may contain only letters, numbers, dot, underscore, and dash"
  fi

  RUN_DIR="$RUN_ROOT/$RUN_ID"
  COMMANDS_FILE="$RUN_DIR/commands.txt"
  SCENARIO_RESULTS_FILE="$RUN_DIR/scenario-results.jsonl"

  if [[ -e "$RUN_DIR" ]]; then
    if [[ "$RUN_ID_PROVIDED" == "true" ]]; then
      fail "run directory already exists: $RUN_DIR"
    fi

    fail "generated run directory already exists: $RUN_DIR"
  fi
}

validate_duration_scale() {
  python3 - "$DURATION_SCALE" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit("duration scale must be numeric")

if not math.isfinite(value) or value <= 0:
    raise SystemExit("duration scale must be greater than zero")
PY
}

validate_budget_target() {
  python3 - "$BUDGET_TARGET_QPR" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit("budget target qpr must be numeric")

if not math.isfinite(value) or value <= 0:
    raise SystemExit("budget target qpr must be greater than zero")
PY
}

validate_requested_scenario() {
  if [[ -z "$REQUESTED_SCENARIO" ]]; then
    return 0
  fi

  local scenario
  for scenario in "${MEASURED_SCENARIOS[@]}"; do
    if [[ "$scenario" == "$REQUESTED_SCENARIO" ]]; then
      return 0
    fi
  done

  fail "unsupported --scenario '$REQUESTED_SCENARIO'"
}

prepare_run_dir() {
  mkdir -p "$RUN_DIR/driver" "$RUN_DIR/logs" "$RUN_DIR/pids" "$RUN_DIR/probe" "$RUN_DIR/scenarios"
  : > "$COMMANDS_FILE"
  : > "$SCENARIO_RESULTS_FILE"
  write_plan_metadata
}

quote_command() {
  local arg quoted output
  output=""
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [[ -z "$output" ]]; then
      output="$quoted"
    else
      output="$output $quoted"
    fi
  done
  printf '%s\n' "$output"
}

record_command() {
  quote_command "$@" >> "$COMMANDS_FILE"
}

record_comment() {
  printf '# %s\n' "$*" >> "$COMMANDS_FILE"
}

redact_artifact_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0

  python3 - "$path" <<'PY_REDACT'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = [
    (re.compile(r"dev-perf-metrics-[A-Za-z0-9_-]+"), "dev-perf-metrics-[REDACTED]"),
    (re.compile(r"(?i)(bearer\\s+)[A-Za-z0-9._~+/=:-]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(authorization[\\s:=]+)[^\\s\\r\\n]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(cookie[\\s:=]+)[^\\r\\n]+"), r"\1[REDACTED]"),
]
for pattern, repl in patterns:
    text = pattern.sub(repl, text)
path.write_text(text, encoding="utf-8")
PY_REDACT
}

run_logged() {
  local log_file="$1"
  shift
  record_command "$@"
  "$@" > "$log_file" 2>&1
  redact_artifact_file "$log_file"
}
write_plan_metadata() {
  python3 - "$RUN_ID" "$REQUESTED_SCENARIO" "$DURATION_SCALE" "$DRY_RUN" "$EXTERNAL_APP" "$BUDGET_TARGET_QPR" "$BUDGET_TARGET_ACTIVE" "$RUN_DIR/scenario.json" <<'PY'
import json
import sys
from pathlib import Path

run_id, requested, scale, dry_run, external_app, budget_target, budget_active, output = sys.argv[1:9]
measured = [
    "baseline-1c",
    "backend-short-10c",
    "v1-short-10c",
    "short-25c",
    "long-10c",
    "large-chunk-5c",
    "disconnect-10c",
    "ws-short-10c",
    "ws-long-10c",
    "ws-disconnect-10c",
    "mixed-soak-20m",
]
selected = [requested] if requested else measured
plan = [
    {"name": "warmup-default", "phase": "warmup", "driver_scenario": "warmup-default"},
    *[{"name": name, "phase": "measured", "driver_scenario": name} for name in selected],
    {"name": "cooldown-default", "phase": "cooldown", "driver_scenario": "warmup-default"},
]
Path(output).write_text(json.dumps({
    "run_id": run_id,
    "mode": "dry-run" if dry_run == "true" else "real",
    "external_app": external_app == "true",
    "duration_scale": float(scale),
    "budget_target_qpr": float(budget_target),
    "budget_gate_active": budget_active == "true",
    "scenario_filter": requested or None,
    "plan": plan,
}, indent=2) + "\n")
PY
}

selected_measured_scenarios() {
  if [[ -n "$REQUESTED_SCENARIO" ]]; then
    printf '%s\n' "$REQUESTED_SCENARIO"
    return 0
  fi

  local scenario
  for scenario in "${MEASURED_SCENARIOS[@]}"; do
    printf '%s\n' "$scenario"
  done
}

scenario_driver() {
  case "$1" in
    mixed-soak-20m) printf 'http+ws\n' ;;
    ws-*) printf 'ws\n' ;;
    *) printf 'http\n' ;;
  esac
}

scenario_default_duration() {
  case "$1" in
    warmup-default|cooldown-default|baseline-1c) printf '60\n' ;;
    backend-short-10c|v1-short-10c|short-25c|disconnect-10c|ws-short-10c|ws-disconnect-10c) printf '120\n' ;;
    long-10c|large-chunk-5c|ws-long-10c) printf '300\n' ;;
    mixed-soak-20m) printf '1200\n' ;;
    *) fail "missing duration for scenario '$1'" ;;
  esac
}

scenario_default_concurrency() {
  case "$1" in
    warmup-default|cooldown-default|baseline-1c) printf '1\n' ;;
    large-chunk-5c) printf '5\n' ;;
    short-25c) printf '25\n' ;;
    mixed-soak-20m) printf '20\n' ;;
    *) printf '10\n' ;;
  esac
}

scenario_driver_name() {
  case "$1" in
    cooldown-default) printf 'warmup-default\n' ;;
    mixed-soak-20m) printf 'mixed-soak-20m\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

scaled_duration() {
  local duration="$1"
  local phase="$2"

  if [[ "$phase" == "warmup" ]]; then
    printf '%s\n' "$duration"
    return 0
  fi

  python3 - "$duration" "$DURATION_SCALE" <<'PY'
import math
import sys

duration = int(sys.argv[1])
scale = float(sys.argv[2])
print(max(1, math.ceil(duration * scale)))
PY
}

write_scenario_metadata() {
  local name="$1"
  local phase="$2"
  local driver="$3"
  local driver_scenario="$4"
  local duration_seconds="$5"
  local concurrency="$6"
  local dir="$RUN_DIR/scenarios/$name"

  mkdir -p "$dir"
  python3 - "$RUN_ID" "$name" "$phase" "$driver" "$driver_scenario" "$duration_seconds" "$concurrency" "$DURATION_SCALE" "$dir/scenario.json" <<'PY'
import json
import sys
from pathlib import Path

run_id, name, phase, driver, driver_scenario, duration, concurrency, scale, output = sys.argv[1:10]
metadata = {
    "run_id": run_id,
    "name": name,
    "phase": phase,
    "driver": driver,
    "driver_scenario": driver_scenario,
    "duration_seconds": int(duration),
    "concurrency": int(concurrency),
    "duration_scale": float(scale),
}
if name == "mixed-soak-20m":
    metadata["components"] = [
        {
            "driver": "http",
            "driver_scenario": "mixed-short-10c",
            "route_family": "mixed",
            "route_mix": {"backend": 0.5, "v1": 0.5},
            "profile": "short-ok",
            "concurrency": 10,
            "expected_outcome": "successful_http",
        },
        {
            "driver": "ws",
            "driver_scenario": "ws-short-10c",
            "route_family": "mixed",
            "route_mix": {"backend": 0.5, "v1": 0.5},
            "profile": "short-ok",
            "concurrency": 10,
            "expected_outcome": "clean_websocket",
        },
    ]
Path(output).write_text(json.dumps(metadata, indent=2) + "\n")
PY
}

record_scenario_result() {
  local name="$1"
  local phase="$2"
  local driver="$3"
  local driver_scenario="$4"
  local duration_seconds="$5"
  local concurrency="$6"
  local rc="$7"
  local summary_path="$8"
  local log_path="$9"

  python3 - "$SCENARIO_RESULTS_FILE" "$name" "$phase" "$driver" "$driver_scenario" "$duration_seconds" "$concurrency" "$rc" "$summary_path" "$log_path" <<'PY'
import json
import sys
from pathlib import Path

path, name, phase, driver, driver_scenario, duration, concurrency, rc, summary, log_path = sys.argv[1:11]
exit_code = int(rc)
entry = {
    "name": name,
    "phase": phase,
    "driver": driver,
    "driver_scenario": driver_scenario,
    "duration_seconds": int(duration),
    "concurrency": int(concurrency),
    "exit_code": exit_code,
    "status": "succeeded" if exit_code == 0 else "failed",
    "summary_path": summary,
    "log_path": log_path,
}
with Path(path).open("a") as handle:
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
PY
}


record_combined_scenario_result() {
  local name="$1"
  local phase="$2"
  local duration_seconds="$3"
  local concurrency="$4"
  local http_rc="$5"
  local ws_rc="$6"
  local summary_path="$7"
  local http_summary_path="$8"
  local ws_summary_path="$9"
  local http_log_path="${10}"
  local ws_log_path="${11}"

  python3 - "$SCENARIO_RESULTS_FILE" "$name" "$phase" "$duration_seconds" "$concurrency" "$http_rc" "$ws_rc" "$summary_path" "$http_summary_path" "$ws_summary_path" "$http_log_path" "$ws_log_path" <<'PY'
import json
import sys
from pathlib import Path

(
    results_path,
    name,
    phase,
    duration,
    concurrency,
    http_rc,
    ws_rc,
    summary_path,
    http_summary,
    ws_summary,
    http_log,
    ws_log,
) = sys.argv[1:13]
http_exit = int(http_rc)
ws_exit = int(ws_rc)
exit_code = 0 if http_exit == 0 and ws_exit == 0 else 20
components = [
    {
        "driver": "http",
        "driver_scenario": "mixed-short-10c",
        "route_family": "mixed",
        "route_mix": {"backend": 0.5, "v1": 0.5},
        "profile": "short-ok",
        "concurrency": 10,
        "exit_code": http_exit,
        "status": "succeeded" if http_exit == 0 else "failed",
        "summary_path": http_summary,
        "log_path": http_log,
    },
    {
        "driver": "ws",
        "driver_scenario": "ws-short-10c",
        "route_family": "mixed",
        "route_mix": {"backend": 0.5, "v1": 0.5},
        "profile": "short-ok",
        "concurrency": 10,
        "exit_code": ws_exit,
        "status": "succeeded" if ws_exit == 0 else "failed",
        "summary_path": ws_summary,
        "log_path": ws_log,
    },
]
entry = {
    "name": name,
    "phase": phase,
    "driver": "http+ws",
    "driver_scenario": "mixed-soak-20m",
    "duration_seconds": int(duration),
    "concurrency": int(concurrency),
    "exit_code": exit_code,
    "status": "succeeded" if exit_code == 0 else "failed",
    "summary_path": summary_path,
    "components": components,
}
Path(summary_path).write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n")
with Path(results_path).open("a") as handle:
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
PY
}

write_dry_run_bootstrap() {
  mkdir -p "$BOOTSTRAP_DIR"
  chmod 700 "$BOOTSTRAP_DIR"

  cat > "$PROFILE_MANIFEST" <<'JSON'
[
  {"name":"short-ok","first_event_delay_ms":50,"inter_event_delay_ms":25,"event_count":20,"chunk_bytes":512,"http_status":200,"failure_phase":"before_none","close_mode":"clean_close","expected_outcome":"success","allowed_statuses":[200]},
  {"name":"long-ok","first_event_delay_ms":100,"inter_event_delay_ms":1000,"event_count":300,"chunk_bytes":512,"http_status":200,"failure_phase":"before_none","close_mode":"clean_close","expected_outcome":"success","allowed_statuses":[200]},
  {"name":"large-chunk","first_event_delay_ms":50,"inter_event_delay_ms":100,"event_count":50,"chunk_bytes":65536,"http_status":200,"failure_phase":"before_none","close_mode":"clean_close","expected_outcome":"success","allowed_statuses":[200]},
  {"name":"slow-first-event","first_event_delay_ms":15000,"inter_event_delay_ms":25,"event_count":20,"chunk_bytes":512,"http_status":200,"failure_phase":"before_none","close_mode":"clean_close","expected_outcome":"timeout_or_classified_failure","allowed_statuses":[504,502]},
  {"name":"disconnect-midstream","first_event_delay_ms":50,"inter_event_delay_ms":25,"event_count":20,"chunk_bytes":512,"http_status":200,"failure_phase":"after_event_5","close_mode":"client_disconnect","expected_outcome":"classified_disconnect","allowed_statuses":[499,502]},
  {"name":"partial-failure","first_event_delay_ms":50,"inter_event_delay_ms":25,"event_count":20,"chunk_bytes":512,"http_status":200,"failure_phase":"after_event_5","close_mode":"upstream_error","expected_outcome":"classified_failure","allowed_statuses":[502]},
  {"name":"timeout","first_event_delay_ms":999999,"inter_event_delay_ms":25,"event_count":20,"chunk_bytes":512,"http_status":200,"failure_phase":"before_first_event","close_mode":"timeout","expected_outcome":"timeout","allowed_statuses":[504]},
  {"name":"quota-429","first_event_delay_ms":0,"inter_event_delay_ms":0,"event_count":0,"chunk_bytes":0,"http_status":429,"failure_phase":"before_stream","close_mode":"http_error","expected_outcome":"rate_limited","allowed_statuses":[429]}
]
JSON

  cat > "$BOOTSTRAP_DIR/seed-summary.json" <<'JSON'
{
  "pool_slug": "dev-perf-pool",
  "mode": "dry-run",
  "upstream_count": 0,
  "metrics_token_present": false
}
JSON

  cat > "$PERF_ENV_PATH" <<'EOF'
CODEX_POOLER_PERF_API_KEY=dry-run
CODEX_POOLER_PERF_POOL_SLUG=dev-perf-pool
CODEX_POOLER_PERF_METRICS_TOKEN=dry-run
CODEX_POOLER_PERF_ALLOW_HOSTS=
EOF
  chmod 600 "$PERF_ENV_PATH"
  export CODEX_POOLER_PERF_API_KEY=dry-run
}

source_perf_env() {
  if [[ ! -f "$PERF_ENV_PATH" ]]; then
    fail "perf env not found at $PERF_ENV_PATH; run mix dev.seed perf first"
  fi

  set -a
  source "$PERF_ENV_PATH"
  set +a
}

source_dev_secret_env() {
  if [[ ! -f .env ]]; then
    return 0
  fi

  if grep -qE '^(CODEX_POOLER_UPSTREAM_SECRET_KEY|CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION|CODEX_POOLER_TOTP_ENCRYPTION_KEY|CODEX_POOLER_TOTP_KEY_VERSION)=' .env; then
    set -a
    source <(grep -E '^(CODEX_POOLER_UPSTREAM_SECRET_KEY|CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION|CODEX_POOLER_TOTP_ENCRYPTION_KEY|CODEX_POOLER_TOTP_KEY_VERSION)=' .env)
    set +a
  fi
}

real_bootstrap() {
  source_dev_secret_env
  run_logged "$RUN_DIR/logs/docker-db.log" docker compose -f docker-compose.dev.yml up -d db
  run_logged "$RUN_DIR/logs/ecto-create.log" env POSTGRES_PORT="$POSTGRES_PORT" mix ecto.create --quiet
  run_logged "$RUN_DIR/logs/ecto-migrate.log" env POSTGRES_PORT="$POSTGRES_PORT" mix ecto.migrate
  run_logged "$RUN_DIR/logs/perf-seed.log" env POSTGRES_PORT="$POSTGRES_PORT" mix dev.seed perf
  source_perf_env
  run_logged "$RUN_DIR/logs/perf-guard.log" scripts/dev/gateway-perf-guard.sh --check
}

wait_for_health() {
  local url="$1"
  local label="$2"
  local log_file="$3"
  local attempt

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log_info "$label health ok"
      return 0
    fi
    sleep 1
  done

  printf '%s did not become healthy at %s\n' "$label" "$url" >&2
  if [[ -f "$log_file" ]]; then
    printf 'see log: %s\n' "$log_file" >&2
  fi
  exit 1
}

ensure_port_free() {
  local port="$1"
  local listener
  listener="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"

  if [[ -n "$listener" ]]; then
    fail "port $port is already in use; stop that process or pass --external-app for an already-running Phoenix app"
  fi
}

stop_existing_dev_pid() {
  if [[ ! -f tmp/dev-server.pid ]]; then
    return 0
  fi

  local pid
  pid="$(cat tmp/dev-server.pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    log_info "stopping existing tmp/dev-server.pid process $pid"
    kill "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
  rm -f tmp/dev-server.pid
}

wait_for_pid_exit() {
  local pid="$1"
  local attempt

  for attempt in 1 2 3 4 5; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
}

start_fake_upstream() {
  local log_file="$RUN_DIR/logs/fake-upstream.log"
  record_command mix run scripts/dev/gateway-perf-fake-upstream.exs --run-id "$RUN_ID" --host 127.0.0.1 --port "$FAKE_UPSTREAM_PORT" --profile-manifest "$PROFILE_MANIFEST" --profiles all
  mix run scripts/dev/gateway-perf-fake-upstream.exs --run-id "$RUN_ID" --host 127.0.0.1 --port "$FAKE_UPSTREAM_PORT" --profile-manifest "$PROFILE_MANIFEST" --profiles all > "$log_file" 2>&1 &
  FAKE_UPSTREAM_PID=$!
  printf '%s\n' "$FAKE_UPSTREAM_PID" > "$RUN_DIR/pids/fake-upstream.pid"
  wait_for_health "$FAKE_UPSTREAM_BASE_URL/healthz" "fake upstream" "$log_file"
  redact_artifact_file "$log_file"
}

start_or_verify_app() {
  local log_file="$RUN_DIR/logs/app.log"

  if [[ "$EXTERNAL_APP" == "true" ]]; then
    record_comment "external app mode: skipped Phoenix startup; verifying $APP_BASE_URL/healthz"
    wait_for_health "$APP_BASE_URL/healthz" "external app" "$log_file"
    return 0
  fi

  stop_existing_dev_pid
  ensure_port_free "$APP_PORT"
  source_dev_secret_env

  record_command env PHX_SERVER=true PORT="$APP_PORT" POSTGRES_PORT="$POSTGRES_PORT" CODEX_POOLER_PERF_PROBE=1 CODEX_POOLER_PERF_RUN_ID="$RUN_ID" CODEX_POOLER_PERF_BUDGET_TARGET_QPR="$BUDGET_TARGET_QPR" mix phx.server
  env PHX_SERVER=true PORT="$APP_PORT" POSTGRES_PORT="$POSTGRES_PORT" CODEX_POOLER_PERF_PROBE=1 CODEX_POOLER_PERF_RUN_ID="$RUN_ID" CODEX_POOLER_PERF_BUDGET_TARGET_QPR="$BUDGET_TARGET_QPR" mix phx.server > "$log_file" 2>&1 &
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$RUN_DIR/pids/app.pid"
  printf '%s\n' "$APP_PID" > tmp/dev-server.pid
  wait_for_health "$APP_BASE_URL/healthz" "Phoenix app" "$log_file"
  redact_artifact_file "$log_file"
}

stop_process() {
  local pid="$1"
  local label="$2"

  if [[ -z "$pid" ]]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    log_info "stopping $label pid $pid"
    kill "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid"
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local rc=$?
  stop_process "$APP_PID" "Phoenix app"
  if [[ -n "$APP_PID" ]] && [[ -f tmp/dev-server.pid ]] && [[ "$(cat tmp/dev-server.pid)" == "$APP_PID" ]]; then
    rm -f tmp/dev-server.pid
  fi
  stop_process "$FAKE_UPSTREAM_PID" "fake upstream"
  exit "$rc"
}

run_http_scenario() {
  local name="$1"
  local phase="$2"
  local driver_scenario="$3"
  local duration_seconds="$4"
  local concurrency="$5"
  local log_file="$RUN_DIR/logs/${name}.log"
  local scenario_driver_dir="$RUN_DIR/driver/$name"
  local rc

  mkdir -p "$scenario_driver_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    record_command node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" --dry-run
    set +e
    node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" --dry-run > "$log_file" 2>&1
    rc=$?
    set -e
  else
    record_command node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase"
    set +e
    node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" > "$log_file" 2>&1
    rc=$?
    set -e
  fi

  if [[ -f "$RUN_DIR/driver/http-summary.json" ]]; then
    cp "$RUN_DIR/driver/http-summary.json" "$scenario_driver_dir/http-summary.json"
  fi

  record_scenario_result "$name" "$phase" http "$driver_scenario" "$duration_seconds" "$concurrency" "$rc" "$scenario_driver_dir/http-summary.json" "$log_file"
}

run_ws_scenario() {
  local name="$1"
  local phase="$2"
  local driver_scenario="$3"
  local duration_seconds="$4"
  local concurrency="$5"
  local log_file="$RUN_DIR/logs/${name}.log"
  local scenario_driver_dir="$RUN_DIR/driver/$name"
  local rc

  mkdir -p "$scenario_driver_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    record_command mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" --dry-run
    set +e
    mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" --dry-run > "$scenario_driver_dir/ws-summary.json" 2> "$log_file"
    rc=$?
    set -e
  else
    record_command mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase"
    set +e
    mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario "$driver_scenario" --duration-seconds "$duration_seconds" --concurrency "$concurrency" --phase "$phase" > "$log_file" 2>&1
    rc=$?
    set -e

    if [[ -f "$RUN_DIR/driver/ws-summary.json" ]]; then
      cp "$RUN_DIR/driver/ws-summary.json" "$scenario_driver_dir/ws-summary.json"
    fi
  fi

  record_scenario_result "$name" "$phase" ws "$driver_scenario" "$duration_seconds" "$concurrency" "$rc" "$scenario_driver_dir/ws-summary.json" "$log_file"
}


run_mixed_soak_scenario() {
  local name="$1"
  local phase="$2"
  local duration_seconds="$3"
  local concurrency="$4"
  local scenario_driver_dir="$RUN_DIR/driver/$name"
  local http_dir="$scenario_driver_dir/http"
  local ws_dir="$scenario_driver_dir/ws"
  local http_log_file="$RUN_DIR/logs/${name}-http.log"
  local ws_log_file="$RUN_DIR/logs/${name}-ws.log"
  local http_summary_path="$http_dir/http-summary.json"
  local ws_summary_path="$ws_dir/ws-summary.json"
  local combined_summary_path="$scenario_driver_dir/summary.json"
  local http_rc ws_rc

  mkdir -p "$http_dir" "$ws_dir"
  log_info "running $phase scenario $name via mixed-short-10c + ws-short-10c duration=${duration_seconds}s concurrency=10+10"

  if [[ "$DRY_RUN" == "true" ]]; then
    record_command node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario mixed-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" --dry-run
    set +e
    node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario mixed-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" --dry-run > "$http_log_file" 2>&1
    http_rc=$?
    set -e
  else
    record_command node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario mixed-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase"
    set +e
    node scripts/dev/gateway-perf-http.mjs --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario mixed-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" > "$http_log_file" 2>&1
    http_rc=$?
    set -e
  fi

  if [[ -f "$RUN_DIR/driver/http-summary.json" ]]; then
    cp "$RUN_DIR/driver/http-summary.json" "$http_summary_path"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    record_command mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario ws-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" --dry-run
    set +e
    mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario ws-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" --dry-run > "$ws_summary_path" 2> "$ws_log_file"
    ws_rc=$?
    set -e
  else
    record_command mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario ws-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase"
    set +e
    mix run scripts/dev/gateway-perf-ws.exs -- --run-id "$RUN_ID" --base-url "$APP_BASE_URL" --api-key-env CODEX_POOLER_PERF_API_KEY --profile-manifest "$PROFILE_MANIFEST" --scenario ws-short-10c --duration-seconds "$duration_seconds" --concurrency 10 --phase "$phase" > "$ws_log_file" 2>&1
    ws_rc=$?
    set -e

    if [[ -f "$RUN_DIR/driver/ws-summary.json" ]]; then
      cp "$RUN_DIR/driver/ws-summary.json" "$ws_summary_path"
    fi
  fi

  record_combined_scenario_result "$name" "$phase" "$duration_seconds" "$concurrency" "$http_rc" "$ws_rc" "$combined_summary_path" "$http_summary_path" "$ws_summary_path" "$http_log_file" "$ws_log_file"
}

run_scenario() {
  local name="$1"
  local phase="$2"
  local driver_scenario duration_default duration_seconds concurrency driver

  driver_scenario="$(scenario_driver_name "$name")"
  duration_default="$(scenario_default_duration "$name")"
  duration_seconds="$(scaled_duration "$duration_default" "$phase")"
  concurrency="$(scenario_default_concurrency "$name")"
  driver="$(scenario_driver "$driver_scenario")"

  write_scenario_metadata "$name" "$phase" "$driver" "$driver_scenario" "$duration_seconds" "$concurrency"
  if [[ "$driver" != "http+ws" ]]; then
    log_info "running $phase scenario $name via $driver_scenario duration=${duration_seconds}s concurrency=$concurrency"
  fi

  case "$driver" in
    http) run_http_scenario "$name" "$phase" "$driver_scenario" "$duration_seconds" "$concurrency" ;;
    ws) run_ws_scenario "$name" "$phase" "$driver_scenario" "$duration_seconds" "$concurrency" ;;
    http+ws) run_mixed_soak_scenario "$name" "$phase" "$duration_seconds" "$concurrency" ;;
    *) fail "unsupported driver '$driver'" ;;
  esac
}

run_plan() {
  local scenario
  run_scenario warmup-default warmup

  while IFS= read -r scenario; do
    [[ -n "$scenario" ]] || continue
    run_scenario "$scenario" measured
  done < <(selected_measured_scenarios)

  run_scenario cooldown-default cooldown
}

run_sanitizer() {
  local log_file="$RUN_DIR/logs/sanitize.log"

  record_command scripts/dev/gateway-perf-sanitize.sh "$RUN_DIR"
  set +e
  scripts/dev/gateway-perf-sanitize.sh "$RUN_DIR" > "$log_file" 2>&1
  SANITIZER_RC=$?
  set -e
}

write_summary() {
  python3 - "$RUN_ID" "$RUN_DIR" "$SCENARIO_RESULTS_FILE" "${SANITIZER_RC:-}" "$DRY_RUN" "$EXTERNAL_APP" "$DURATION_SCALE" "$BUDGET_TARGET_QPR" "$BUDGET_TARGET_ACTIVE" <<'PY'
import json
import sys
from pathlib import Path

run_id, run_dir, results_path, sanitizer_rc, dry_run, external_app, duration_scale, budget_target, budget_active = sys.argv[1:10]
run_path = Path(run_dir)
results_file = Path(results_path)
scenarios = []
if results_file.exists():
    for line in results_file.read_text().splitlines():
        if line.strip():
            scenarios.append(json.loads(line))

failed = [scenario for scenario in scenarios if scenario.get("status") != "succeeded"]
san_rc = None if sanitizer_rc == "" else int(sanitizer_rc)
query_summary_path = run_path / "probe" / "query-summary.json"
query_summary = None
if query_summary_path.is_file():
    query_summary = json.loads(query_summary_path.read_text())
budget_status = query_summary.get("budget_status") if isinstance(query_summary, dict) else None
budget_gate_active = budget_active == "true"
budget_failed = bool(budget_gate_active and isinstance(budget_status, dict) and budget_status.get("pass") is False)
summary = {
    "run_id": run_id,
    "mode": "dry-run" if dry_run == "true" else "real",
    "external_app": external_app == "true",
    "duration_scale": float(duration_scale),
    "budget_target_qpr": float(budget_target),
    "budget_gate_active": budget_gate_active,
    "budget_status": budget_status,
    "status": "failed" if failed or san_rc not in (None, 0) or budget_failed else "succeeded",
    "scenario_count": len(scenarios),
    "failed_scenario_count": len(failed),
    "budget_failed": budget_failed,
    "sanitizer_exit_code": san_rc,
    "scenarios": scenarios,
    "artifact_paths": {
        "commands": str(run_path / "commands.txt"),
        "scenario_plan": str(run_path / "scenario.json"),
        "driver": str(run_path / "driver"),
        "probe": str(run_path / "probe"),
        "query_summary": str(query_summary_path),
    },
}
(run_path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
PY
}

exit_code_from_summary() {
  python3 - "$RUN_DIR/summary.json" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
if summary.get("sanitizer_exit_code") not in (None, 0):
    print(1)
elif summary.get("failed_scenario_count", 0) > 0 or summary.get("budget_failed") is True:
    print(20)
else:
    print(0)
PY
}

write_selected_path_manifest() {
  if [[ "$BUDGET_TARGET_ACTIVE" != "true" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$SELECTED_PATH_FILE")"
  python3 - "$RUN_DIR/summary.json" "$SELECTED_PATH_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

summary_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
summary = json.loads(summary_path.read_text())
query_path = Path(summary.get("artifact_paths", {}).get("query_summary", ""))
query = json.loads(query_path.read_text()) if query_path.is_file() else {}
budget = query.get("budget_status") if isinstance(query, dict) else None
tables = query.get("table_shares") if isinstance(query, dict) else {}
if not isinstance(tables, dict):
    tables = {}
target = budget.get("target_qpr") if isinstance(budget, dict) else summary.get("budget_target_qpr")
trusted_local = (
    summary.get("mode") == "real"
    and summary.get("sanitizer_exit_code") == 0
    and Path(summary.get("artifact_paths", {}).get("probe", "")).is_dir()
    and query_path.is_file()
    and isinstance(budget, dict)
)
k8s_contract_executable = Path("scripts/dev/gateway-perf-k8s.sh").is_file()
routing_quota_share = float(tables.get("account_quota_windows", 0) or 0) + float(tables.get("routing_circuit_states", 0) or 0)
routing_quota_hotspot = routing_quota_share >= 0.40
if trusted_local and k8s_contract_executable and target == 20 and budget.get("pass") is False and routing_quota_hotspot:
    decision = "continue_task_5"
    reason = "budget_failed_with_routing_quota_fanout_hotspot"
else:
    decision = "stop_report"
    reasons = []
    if not trusted_local:
        reasons.append("local_evidence_not_trusted")
    if not k8s_contract_executable:
        reasons.append("k8s_lane_contract_not_executable")
    if target != 20:
        reasons.append("active_budget_target_not_20")
    if not isinstance(budget, dict) or budget.get("pass") is not False:
        reasons.append("budget_not_failed")
    if not routing_quota_hotspot:
        reasons.append("routing_quota_fanout_hotspot_false")
    reason = "+".join(reasons) or "gate_a_stop"
manifest = {
    "gate": "Gate A",
    "active_budget_target": target,
    "decision": decision,
    "executed_tasks": [1, 2, 3, 4],
    "skipped_tasks": [],
    "evidence_path": str(query_path),
    "reason": reason,
    "written_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

main() {
  parse_args "$@"
  prepare_run_dir
  trap cleanup EXIT

  if [[ "$DRY_RUN" == "true" ]]; then
    BOOTSTRAP_DIR="$RUN_DIR/bootstrap"
    PERF_ENV_PATH="$BOOTSTRAP_DIR/perf.env"
    PROFILE_MANIFEST="$BOOTSTRAP_DIR/profile-manifest.json"
    record_comment "dry-run: skipped db setup, perf seed, guard, fake upstream startup, app startup, and network traffic"
    write_dry_run_bootstrap
  else
    real_bootstrap
    start_fake_upstream
    start_or_verify_app
  fi

  run_plan
  run_sanitizer
  write_summary
  write_selected_path_manifest

  local final_rc
  final_rc="$(exit_code_from_summary)"
  log_info "summary: $RUN_DIR/summary.json"
  log_info "completed with exit code $final_rc"
  exit "$final_rc"
}

main "$@"
