#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="codex-pooler-perf"
IMAGE_TAG="codex-pooler:perf-local"
OVERLAY_DIR="scripts/dev/k8s/codex-pooler-perf"
RUN_ROOT="tmp/gateway-perf"
APP_SERVICE_HTTP="http://codex-pooler-app.codex-pooler-perf.svc.cluster.local:4000"
APP_SERVICE_WS="ws://codex-pooler-app.codex-pooler-perf.svc.cluster.local:4000"
RUN_ID=""
RUN_ID_PROVIDED=false
MEMORY_PROFILE="safe"
REQUESTED_SCENARIO=""
DURATION_SCALE="${CODEX_POOLER_PERF_K8S_DURATION_SCALE:-1}"
BUDGET_TARGET_QPR="20"
BUDGET_TARGET_ACTIVE=false
SELECTED_PATH_FILE=".omo/evidence/gateway-hot-path-selected-path.json"
PREVIOUS_CONTEXT=""
CONTEXT_RESTORE_ARMED=false

usage() {
  cat <<'USAGE'
Usage: scripts/dev/gateway-perf-k8s.sh <command> [options]

Docker Desktop Kubernetes reproduction lane for gateway performance runs. All
mutating commands refuse to run unless the current kubectl context is exactly
`docker-desktop`.

Commands:
  up --memory-profile safe|low [--run-id ID]
      Build no image and apply only the isolated codex-pooler-perf namespace,
      disposable Postgres, fake upstream, migrations, seed job, and app resources.

  capture --run-id ID
      Capture pod/resource/log evidence for codex-pooler-perf. Writes kubectl
      top output when metrics-server is available, otherwise writes a
      metrics-fallback.txt with pod descriptions, restart/OOM state, logs, and
      probe/cgroup evidence.

  run --run-id ID
      Build codex-pooler:perf-local, run the in-cluster runner against the safe
      profile and then the low profile, capture artifacts after each profile,
      write tmp/gateway-perf/<ID>/k8s/final-report.md, and tear the namespace
      down only when the full run succeeds. This command does not accept
      --memory-profile.

  down
      Delete the codex-pooler-perf namespace and all disposable resources.

  render [--memory-profile safe|low]
      Client-side dry validation of the dev-only manifests. This does not apply
      resources and is safe on non-docker-desktop contexts.

Options:
  --run-id ID              Artifact directory name under tmp/gateway-perf/.
  --memory-profile PROFILE safe or low. Accepted by up/render only.
  --scenario NAME          Optional scenario selector accepted by run/capture.
  --budget-target-qpr NUM  Mark run/capture reports failed with exit 20 when app probe QPR is >= NUM.
  --help, -h               Show this help.

Environment:
  CODEX_POOLER_PERF_K8S_DURATION_SCALE  Optional positive scale used by the
                                        in-cluster runner. Defaults to 1.
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log_info() {
  printf '[gateway-perf-k8s] %s\n' "$*"
}

redact_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  python3 - "$path" <<'PY'
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = [
    (re.compile(r"(?im)(authorization:\s*bearer\s+)[^\s\r\n]+"), r"\1[REDACTED_BEARER]"),
    (re.compile(r"(?im)(cookie:\s*)[^\r\n]+"), r"\1[REDACTED_COOKIE]"),
    (re.compile(r"(?i)(api[_-]?key|token|secret|password|database_url)(=|:)[^\s\r\n]+"), r"\1\2[REDACTED]"),
    (re.compile(r"ecto://[^\s\r\n]+"), "ecto://[REDACTED_DATABASE_URL]"),
    (re.compile(r"postgres(?:ql)?://[^\s\r\n]+"), "postgresql://[REDACTED_DATABASE_URL]"),
]
for pattern, repl in patterns:
    text = pattern.sub(repl, text)
path.write_text(text, encoding="utf-8")
PY
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "missing command '$name'"
  fi
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id)
        [[ $# -ge 2 ]] || fail "--run-id requires a value"
        RUN_ID="$2"
        RUN_ID_PROVIDED=true
        shift
        ;;
      --memory-profile)
        [[ $# -ge 2 ]] || fail "--memory-profile requires a value"
        MEMORY_PROFILE="$2"
        shift
        ;;
      --scenario)
        [[ $# -ge 2 ]] || fail "--scenario requires a value"
        REQUESTED_SCENARIO="$2"
        shift
        ;;
      --budget-target-qpr)
        [[ $# -ge 2 ]] || fail "--budget-target-qpr requires a value"
        BUDGET_TARGET_QPR="$2"
        BUDGET_TARGET_ACTIVE=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument '$1'"
        ;;
    esac
    shift
  done
}

validate_run_id() {
  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi

  if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "--run-id may contain only letters, numbers, dot, underscore, and dash"
  fi
}

validate_memory_profile() {
  case "$MEMORY_PROFILE" in
    safe|low) ;;
    *) fail "--memory-profile must be safe or low" ;;
  esac
}

validate_scenario() {
  if [[ -z "$REQUESTED_SCENARIO" ]]; then
    return 0
  fi

  case "$REQUESTED_SCENARIO" in
    short-25c) ;;
    *) fail "--scenario currently supports short-25c for k8s perf runs" ;;
  esac
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

run_dir() {
  printf '%s/%s/k8s\n' "$RUN_ROOT" "$RUN_ID"
}

profile_dir() {
  printf '%s/%s\n' "$(run_dir)" "$MEMORY_PROFILE"
}

current_context() {
  kubectl config current-context 2>/dev/null || true
}

require_docker_desktop_context() {
  require_command kubectl
  local ctx
  ctx="$(current_context)"
  if [[ "$ctx" != "docker-desktop" ]]; then
    fail "refusing Kubernetes mutation: current kubectl context is '${ctx:-<none>}', expected 'docker-desktop'"
  fi
}

save_context() {
  PREVIOUS_CONTEXT="$(current_context)"
  CONTEXT_RESTORE_ARMED=true
}

restore_context() {
  if [[ "$CONTEXT_RESTORE_ARMED" == "true" ]] && [[ -n "$PREVIOUS_CONTEXT" ]]; then
    kubectl config use-context "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
  fi
}

mutating_preamble() {
  require_docker_desktop_context
  save_context
  trap restore_context EXIT
}

kubectl_apply() {
  kubectl apply -f "$1"
}

delete_previous_job() {
  local name="$1"
  kubectl -n "$NAMESPACE" delete job "$name" --ignore-not-found=true >/dev/null
}

wait_for_job() {
  local name="$1"
  local timeout="${2:-600s}"
  local deadline status active succeeded failed pod
  deadline=$((SECONDS + ${timeout%s}))

  while (( SECONDS < deadline )); do
    status="$(kubectl -n "$NAMESPACE" get job "$name" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true)"
    if [[ "$status" == *$'Complete=True'* ]]; then
      return 0
    fi
    if [[ "$status" == *$'Failed=True'* ]]; then
      pod="$(kubectl -n "$NAMESPACE" get pods -l job-name="$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "$pod" ]]; then
        kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 >&2 || true
      fi
      return 1
    fi

    active="$(kubectl -n "$NAMESPACE" get job "$name" -o jsonpath='{.status.active}' 2>/dev/null || true)"
    succeeded="$(kubectl -n "$NAMESPACE" get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    failed="$(kubectl -n "$NAMESPACE" get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    log_info "waiting for job $name active=${active:-0} succeeded=${succeeded:-0} failed=${failed:-0}"
    sleep 5
  done

  pod="$(kubectl -n "$NAMESPACE" get pods -l job-name="$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 >&2 || true
  fi
  return 1
}

wait_for_deployment() {
  local name="$1"
  local timeout="${2:-600s}"
  kubectl -n "$NAMESPACE" rollout status "deployment/$name" --timeout="$timeout"
}

wait_for_seed_bootstrap() {
  local deadline pod phase
  deadline=$((SECONDS + 600))

  while (( SECONDS < deadline )); do
    pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=perf-seed -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      phase="$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in
        Running)
          if kubectl -n "$NAMESPACE" exec "$pod" -- test -f /app/tmp/gateway-perf/bootstrap/perf.env >/dev/null 2>&1; then
            return 0
          fi
          ;;
        Failed)
          kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 >&2 || true
          fail "perf seed pod failed before bootstrap was available"
          ;;
        Succeeded)
          fail "perf seed pod completed before bootstrap could be copied"
          ;;
      esac
    fi

    sleep 2
  done

  fail "timed out waiting for perf seed bootstrap"
}

wait_for_runner_summary() {
  local deadline pod phase summary_path
  deadline=$((SECONDS + 7200))
  summary_path="/app/tmp/gateway-perf/$RUN_ID/k8s-runner/$MEMORY_PROFILE/summary.json"

  while (( SECONDS < deadline )); do
    pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=perf-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      phase="$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in
        Running)
          if kubectl -n "$NAMESPACE" exec "$pod" -- test -f "$summary_path" >/dev/null 2>&1; then
            return 0
          fi
          ;;
        Failed|Succeeded)
          kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 >&2 || true
          return 1
          ;;
      esac
    fi

    log_info "waiting for runner summary profile=$MEMORY_PROFILE pod=${pod:-<pending>} phase=${phase:-<none>}"
    sleep 5
  done

  if [[ -n "${pod:-}" ]]; then
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 >&2 || true
  fi
  return 1
}

create_runtime_secret() {
  local generated_secret generated_totp generated_upstream generated_postgres
  if kubectl -n "$NAMESPACE" get secret codex-pooler-perf-env >/dev/null 2>&1; then
    return 0
  fi

  generated_secret="$(openssl rand -base64 48 | tr -d '\n')"
  generated_totp="$(openssl rand -base64 32 | tr -d '\n')"
  generated_upstream="$(openssl rand -base64 32 | tr -d '\n')"
  generated_postgres="$(openssl rand -hex 24)"

  kubectl -n "$NAMESPACE" create secret generic codex-pooler-perf-env \
    --from-literal=DATABASE_URL="ecto://postgres:${generated_postgres}@codex-pooler-postgres.${NAMESPACE}.svc.cluster.local:5432/codex_pooler_perf" \
    --from-literal=SECRET_KEY_BASE="$generated_secret" \
    --from-literal=CODEX_POOLER_TOTP_ENCRYPTION_KEY="$generated_totp" \
    --from-literal=CODEX_POOLER_TOTP_KEY_VERSION=v1 \
    --from-literal=CODEX_POOLER_UPSTREAM_SECRET_KEY="$generated_upstream" \
    --from-literal=CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION=v1 \
    --from-literal=POOL_SIZE=10 \
    --from-literal=ECTO_IPV6=false \
    --from-literal=OBAN_JOBS_QUEUE_LIMIT=8 \
    --from-literal=OBAN_SHUTDOWN_GRACE_PERIOD_MS=55000 \
    --from-literal=LANG=C.UTF-8 \
    --from-literal=LC_ALL=C.UTF-8 \
    --from-literal=postgres-password="$generated_postgres" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

create_run_config() {
  kubectl -n "$NAMESPACE" create configmap codex-pooler-perf-run \
    --from-literal=run-id="$RUN_ID" \
    --from-literal=memory-profile="$MEMORY_PROFILE" \
    --from-literal=duration-scale="$DURATION_SCALE" \
    --from-literal=scenario="${REQUESTED_SCENARIO:-}" \
    --from-literal=budget-target-qpr="$BUDGET_TARGET_QPR" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

copy_seed_bootstrap() {
  local output_dir pod
  output_dir="$(run_dir)/bootstrap"
  mkdir -p "$output_dir"
  pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=perf-seed -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$NAMESPACE" cp "$pod:/app/tmp/gateway-perf/bootstrap/." "$output_dir" >/dev/null
  chmod 700 "$output_dir" || true
  if [[ -f "$output_dir/perf.env" ]]; then
    chmod 600 "$output_dir/perf.env" || true
  fi
}

create_bootstrap_secret() {
  local bootstrap_dir perf_env
  bootstrap_dir="$(run_dir)/bootstrap"
  perf_env="$bootstrap_dir/perf.env"
  [[ -f "$perf_env" ]] || fail "missing perf bootstrap env at $perf_env"

  set -a
  source "$perf_env"
  set +a

  kubectl -n "$NAMESPACE" create secret generic codex-pooler-perf-bootstrap \
    --from-literal=CODEX_POOLER_PERF_API_KEY="${CODEX_POOLER_PERF_API_KEY:?}" \
    --from-literal=CODEX_POOLER_PERF_POOL_SLUG="${CODEX_POOLER_PERF_POOL_SLUG:-dev-perf-pool}" \
    --from-literal=CODEX_POOLER_PERF_METRICS_TOKEN="${CODEX_POOLER_PERF_METRICS_TOKEN:-}" \
    --from-literal=CODEX_POOLER_PERF_ALLOW_HOSTS="${CODEX_POOLER_PERF_ALLOW_HOSTS:-}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

run_migrations_and_seed() {
  delete_previous_job codex-pooler-migrations
  kubectl_apply "$OVERLAY_DIR/migration-job.yaml"
  wait_for_job codex-pooler-migrations 600s

  delete_previous_job codex-pooler-perf-seed
  kubectl_apply "$OVERLAY_DIR/seed-job.yaml"
  wait_for_seed_bootstrap
  copy_seed_bootstrap
  delete_previous_job codex-pooler-perf-seed
  create_bootstrap_secret
}

apply_static_resources() {
  kubectl_apply "$OVERLAY_DIR/namespace.yaml"
  create_runtime_secret
  create_run_config
  kubectl_apply "$OVERLAY_DIR/postgres.yaml"
  wait_for_deployment codex-pooler-postgres 300s
  run_migrations_and_seed
  kubectl_apply "$OVERLAY_DIR/runner-configmap.yaml"
  kubectl_apply "$OVERLAY_DIR/fake-upstream.yaml"
  wait_for_deployment gateway-perf-fake-upstream 300s
  kubectl_apply "$OVERLAY_DIR/app-${MEMORY_PROFILE}.yaml"
  wait_for_deployment codex-pooler-app 600s
}

render_manifests() {
  require_command kubectl
  validate_memory_profile
  local render_dir
  render_dir="$(mktemp -d)"
  cp "$OVERLAY_DIR/namespace.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/postgres.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/migration-job.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/seed-job.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/fake-upstream.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/runner-configmap.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/runner-job.yaml" "$render_dir/"
  cp "$OVERLAY_DIR/app-${MEMORY_PROFILE}.yaml" "$render_dir/"
  local rc
  set +e
  kubectl apply --dry-run=client --validate=false -f "$render_dir" >/dev/null
  rc=$?
  set -e
  rm -rf "$render_dir"
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  log_info "render ok for memory profile $MEMORY_PROFILE"
}

cmd_up() {
  parse_common_args "$@"
  validate_run_id
  validate_memory_profile
  validate_scenario
  validate_duration_scale
  validate_budget_target
  mutating_preamble
  apply_static_resources
  log_info "namespace $NAMESPACE is ready for run-id $RUN_ID profile $MEMORY_PROFILE"
}

write_metrics_fallback() {
  local dir="$1"
  {
    printf '# metrics fallback\n\n'
    printf 'metrics-server unavailable or kubectl top failed; captured describe/log/probe/cgroup evidence instead\n\n'
    kubectl -n "$NAMESPACE" get pods -o wide || true
    printf '\n## pod restart and oom state\n'
    kubectl -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.name}{":restart="}{.restartCount}{":reason="}{.lastState.terminated.reason}{" "}{end}{"\n"}{end}' || true
    printf '\n## pod descriptions\n'
    kubectl -n "$NAMESPACE" describe pods || true
    printf '\n## cgroup probes\n'
    local pod
    for pod in $(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | sed 's#pod/##'); do
      printf '\n### %s\n' "$pod"
      kubectl -n "$NAMESPACE" exec "$pod" -- /bin/sh -lc 'printf "memory.current="; cat /sys/fs/cgroup/memory.current 2>/dev/null || true; printf "memory.max="; cat /sys/fs/cgroup/memory.max 2>/dev/null || true' 2>/dev/null || true
    done
  } > "$dir/metrics-fallback.txt"
  redact_file "$dir/metrics-fallback.txt"
}

capture_logs() {
  local dir="$1"
  local pod
  mkdir -p "$dir/logs"
  for pod in $(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | sed 's#pod/##'); do
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=500 > "$dir/logs/${pod}.log" 2>&1 || true
    redact_file "$dir/logs/${pod}.log"
  done
}

capture_runner_artifacts() {
  local dir="$1"
  local pod
  pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=perf-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    return 0
  fi
  mkdir -p "$dir/runner-artifacts"
  kubectl -n "$NAMESPACE" cp "$pod:/app/tmp/gateway-perf/$RUN_ID/k8s-runner/." "$dir/runner-artifacts" >/dev/null 2>&1 || true
}

capture_app_probe_artifacts() {
  local pod source_dir output_dir deadline reason
  output_dir="$(run_dir)/probe"
  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    reason="missing app pod for probe capture"
    write_probe_capture_error "$output_dir" "$reason"
    log_info "$reason"
    return 1
  fi

  source_dir="/app/tmp/gateway-perf/$RUN_ID/probe"
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if kubectl -n "$NAMESPACE" exec "$pod" -- test -f "$source_dir/query-summary.json" >/dev/null 2>&1 &&
      kubectl -n "$NAMESPACE" exec "$pod" -- test -f "$source_dir/request-summary.json" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl -n "$NAMESPACE" exec "$pod" -- test -f "$source_dir/query-summary.json" >/dev/null 2>&1; then
    reason="missing app probe artifact query-summary.json in pod $pod"
    write_probe_capture_error "$output_dir" "$reason"
    log_info "$reason"
    return 1
  fi

  if ! kubectl -n "$NAMESPACE" exec "$pod" -- test -f "$source_dir/request-summary.json" >/dev/null 2>&1; then
    reason="missing app probe artifact request-summary.json in pod $pod"
    write_probe_capture_error "$output_dir" "$reason"
    log_info "$reason"
    return 1
  fi

  kubectl -n "$NAMESPACE" cp "$pod:$source_dir/." "$output_dir" >/dev/null
  redact_probe_artifacts "$output_dir"
  log_info "captured app probe artifacts to $output_dir"
}

write_probe_capture_error() {
  local output_dir="$1"
  local reason="$2"
  python3 - "$output_dir/capture-error.json" "$RUN_ID" "$NAMESPACE" "$reason" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, run_id, namespace, reason = sys.argv[1:5]
Path(path).write_text(json.dumps({
    "status": "failed",
    "reason_code": "app_probe_artifact_missing",
    "reason": reason,
    "run_id": run_id,
    "namespace": namespace,
    "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}, indent=2) + "\n")
PY
}

redact_probe_artifacts() {
  local dir="$1"
  local file
  for file in "$dir"/*; do
    [[ -f "$file" ]] || continue
    redact_file "$file"
  done
}

capture_profile_artifacts() {
  local dir="$1"
  local probe_rc=0
  mkdir -p "$dir"

  kubectl -n "$NAMESPACE" get all -o wide > "$dir/resources.txt" 2>&1 || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp > "$dir/events.txt" 2>&1 || true
  kubectl -n "$NAMESPACE" get pods -o yaml > "$dir/pods.yaml" 2>&1 || true
  kubectl -n "$NAMESPACE" get configmap codex-pooler-perf-run -o yaml > "$dir/run-configmap.yaml" 2>&1 || true
  kubectl -n "$NAMESPACE" get deployment codex-pooler-app gateway-perf-fake-upstream codex-pooler-postgres -o yaml > "$dir/deployments.yaml" 2>&1 || true
  for metadata_file in "$dir/resources.txt" "$dir/events.txt" "$dir/pods.yaml" "$dir/run-configmap.yaml" "$dir/deployments.yaml"; do
    redact_file "$metadata_file"
  done

  if kubectl top pods -n "$NAMESPACE" > "$dir/kubectl-top.txt" 2>&1; then
    log_info "captured kubectl top metrics"
  else
    rm -f "$dir/kubectl-top.txt"
    write_metrics_fallback "$dir"
    log_info "metrics unavailable; wrote metrics fallback"
  fi

  capture_logs "$dir"
  capture_app_probe_artifacts || probe_rc=$?
  capture_runner_artifacts "$dir"
  log_info "capture written to $dir"
  return "$probe_rc"
}

cmd_capture() {
  parse_common_args "$@"
  [[ "$RUN_ID_PROVIDED" == "true" ]] || fail "capture requires --run-id"
  validate_run_id
  validate_scenario
  mutating_preamble

  local dir
  dir="$(profile_dir)/capture-$(date -u +%Y%m%dT%H%M%SZ)"
  if ! capture_profile_artifacts "$dir"; then
    fail "app probe artifact capture failed; see $(run_dir)/probe/capture-error.json"
  fi
}

run_runner_job() {
  local summary_status capture_dir capture_rc=0
  delete_previous_job codex-pooler-perf-runner
  create_run_config
  kubectl_apply "$OVERLAY_DIR/runner-job.yaml"
  if ! wait_for_runner_summary; then
    capture_dir="$(profile_dir)/capture-$(date -u +%Y%m%dT%H%M%SZ)"
    capture_profile_artifacts "$capture_dir" || true
    delete_previous_job codex-pooler-perf-runner
    log_info "perf runner job failed for $MEMORY_PROFILE profile"
    return 1
  fi

  capture_dir="$(profile_dir)/capture-$(date -u +%Y%m%dT%H%M%SZ)"
  capture_profile_artifacts "$capture_dir" || capture_rc=$?
  summary_status="$(python3 - "$(profile_dir)" <<'PY'
import json
import sys
from pathlib import Path
profile_dir = Path(sys.argv[1])
summaries = sorted(profile_dir.glob("capture-*/runner-artifacts/*/summary.json"))
if not summaries:
    raise SystemExit("missing")
print(json.loads(summaries[-1].read_text()).get("status", "missing"))
PY
)"
  delete_previous_job codex-pooler-perf-runner

  if [[ "$capture_rc" -ne 0 ]]; then
    log_info "app probe artifact capture failed for $MEMORY_PROFILE profile"
    return 1
  fi

  if [[ -z "$summary_status" ]] || [[ "$summary_status" == "missing" ]]; then
    log_info "perf runner summary artifact missing for $MEMORY_PROFILE profile"
    return 1
  fi

  if [[ "$summary_status" != "succeeded" ]]; then
    log_info "perf runner completed with scenario failures for $MEMORY_PROFILE profile"
    return 20
  fi

  local budget_rc
  budget_rc="$(budget_probe_exit_code)"
  if [[ "$budget_rc" -ne 0 ]]; then
    if [[ "$budget_rc" -eq 20 ]]; then
      log_info "query budget breached for $MEMORY_PROFILE profile"
    else
      log_info "query budget report missing or invalid for $MEMORY_PROFILE profile"
    fi
    return "$budget_rc"
  fi
}

budget_probe_exit_code() {
  if [[ "$BUDGET_TARGET_ACTIVE" != "true" ]]; then
    printf '0\n'
    return 0
  fi

  python3 - "$(run_dir)/probe/query-summary.json" "$BUDGET_TARGET_QPR" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = float(sys.argv[2])
if not path.is_file():
    print(1)
    raise SystemExit(0)
try:
    data = json.loads(path.read_text())
except json.JSONDecodeError:
    print(1)
    raise SystemExit(0)
budget = data.get("budget_status")
if not isinstance(budget, dict):
    print(1)
    raise SystemExit(0)
if float(budget.get("target_qpr", -1)) != target:
    print(1)
    raise SystemExit(0)
print(20 if budget.get("pass") is False else 0)
PY
}

write_selected_path_manifest() {
  if [[ "$BUDGET_TARGET_ACTIVE" != "true" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$SELECTED_PATH_FILE")"
  python3 - "$(run_dir)/probe/query-summary.json" "$SELECTED_PATH_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

query_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
query = json.loads(query_path.read_text()) if query_path.is_file() else {}
budget = query.get("budget_status") if isinstance(query, dict) else None
tables = query.get("table_shares") if isinstance(query, dict) else {}
if not isinstance(tables, dict):
    tables = {}
target = budget.get("target_qpr") if isinstance(budget, dict) else None
trusted_evidence = query_path.is_file() and isinstance(budget, dict)
k8s_contract_executable = Path("scripts/dev/gateway-perf-k8s.sh").is_file()
routing_quota_share = float(tables.get("account_quota_windows", 0) or 0) + float(tables.get("routing_circuit_states", 0) or 0)
routing_quota_hotspot = routing_quota_share >= 0.40
if trusted_evidence and k8s_contract_executable and target == 20 and budget.get("pass") is False and routing_quota_hotspot:
    decision = "continue_task_5"
    reason = "budget_failed_with_routing_quota_fanout_hotspot"
else:
    decision = "stop_report"
    reasons = []
    if not trusted_evidence:
        reasons.append("evidence_not_trusted")
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

build_local_image_if_needed() {
  if rg -q "image: ${IMAGE_TAG}$" "$OVERLAY_DIR"/*.yaml; then
    log_info "building $IMAGE_TAG"
    docker build -t "$IMAGE_TAG" .
  else
    log_info "skipping local build; perf manifests do not reference $IMAGE_TAG"
  fi
}

write_final_report() {
  local report
  report="$(run_dir)/final-report.md"
  mkdir -p "$(run_dir)"
  python3 - "$RUN_ID" "$(run_dir)" "$report" <<'PY'
import json
import sys
from pathlib import Path
run_id, run_dir, report = sys.argv[1:4]
root = Path(run_dir)
lines = [f"# Gateway perf Kubernetes run {run_id}", ""]
status = "succeeded"
probe_dir = root / "probe"
probe_files = [probe_dir / "query-summary.json", probe_dir / "request-summary.json"]
query_summary = json.loads(probe_files[0].read_text()) if probe_files[0].is_file() else None
budget_status = query_summary.get("budget_status") if isinstance(query_summary, dict) else None
if all(path.is_file() for path in probe_files):
    lines.append("App probe artifacts: captured")
    if isinstance(budget_status, dict):
        lines.append(f"Budget: target_qpr={budget_status.get('target_qpr')} actual_qpr={budget_status.get('actual_qpr')} pass={budget_status.get('pass')}")
        if budget_status.get("pass") is False:
            status = "failed"
else:
    missing = ", ".join(str(path.relative_to(root)) for path in probe_files if not path.is_file())
    lines.append(f"App probe artifacts: missing {missing}")
    status = "failed"
lines.append("")
for profile in ["safe", "low"]:
    lines.append(f"## {profile} profile")
    summaries = sorted((root / profile).glob("capture-*/runner-artifacts/*/summary.json"))
    if not summaries:
        lines.append("- summary: missing")
        status = "failed"
        continue
    data = json.loads(summaries[-1].read_text())
    lines.append(f"- status: {data.get('status')}")
    lines.append(f"- scenario_count: {data.get('scenario_count')}")
    lines.append(f"- failed_scenario_count: {data.get('failed_scenario_count')}")
    lines.append(f"- duration_scale: {data.get('duration_scale')}")
    if data.get("status") != "succeeded":
        status = "failed"
    lines.append("")
lines.insert(2, f"Overall status: {status}")
Path(report).write_text("\n".join(lines).rstrip() + "\n")
PY
  log_info "final report written to $report"
}

run_sanitizer() {
  local log_file tmp_log rc
  log_file="$(run_dir)/logs/sanitize.log"
  mkdir -p "$(dirname "$log_file")"
  tmp_log="$(mktemp)"

  set +e
  scripts/dev/gateway-perf-sanitize.sh "$(run_dir)" > "$tmp_log" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    mv "$tmp_log" "$log_file"
  else
    {
      printf 'gateway-perf-sanitize: failed with exit code %s\n' "$rc"
      printf 'matching-line output suppressed in retained artifacts to keep evidence metadata-only\n'
      printf 'rerun scripts/dev/gateway-perf-sanitize.sh %s locally after inspecting the retained tree\n' "$(run_dir)"
    } > "$log_file"
    rm -f "$tmp_log"
  fi

  return "$rc"
}

capture_request_log_evidence() {
  local output_file pod rc query_output
  output_file="$(run_dir)/request-log-sanitized.json"
  mkdir -p "$(run_dir)"
  pod="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgres,app.kubernetes.io/instance=codex-pooler-perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "$pod" ]]; then
    write_request_log_diagnostic "$output_file" "postgres_pod_unavailable" "Postgres pod was not available for sanitized request-log inspection"
    return 0
  fi

  set +e
  # shellcheck disable=SC2016
  query_output="$(kubectl -n "$NAMESPACE" exec -i "$pod" -- /bin/sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d codex_pooler_perf -tA -f -' <<'SQL'
WITH recent AS (
  SELECT
    id::text,
    endpoint,
    transport,
    status,
    usage_status,
    requested_model,
    admitted_at,
    completed_at,
    response_status_code,
    retry_count,
    last_error_code
  FROM requests
  WHERE admitted_at >= now() - interval '6 hours'
    AND (
      user_agent = 'codex-pooler-gateway-perf-k8s/1'
      OR correlation_id LIKE 'k8s-ws-%'
    )
  ORDER BY admitted_at DESC
  LIMIT 100
), status_counts AS (
  SELECT jsonb_object_agg(status, count) AS counts
  FROM (SELECT status, count(*) AS count FROM recent GROUP BY status) grouped
), endpoint_counts AS (
  SELECT jsonb_object_agg(endpoint, count) AS counts
  FROM (SELECT endpoint, count(*) AS count FROM recent GROUP BY endpoint) grouped
)
SELECT jsonb_build_object(
  'source', 'postgres.requests',
  'privacy', 'metadata_only',
  'window', 'last_6_hours_k8s_perf_user_agent_or_ws_correlation',
  'row_count', (SELECT count(*) FROM recent),
  'status_counts', COALESCE((SELECT counts FROM status_counts), '{}'::jsonb),
  'endpoint_counts', COALESCE((SELECT counts FROM endpoint_counts), '{}'::jsonb),
  'rows', COALESCE((SELECT jsonb_agg(to_jsonb(recent)) FROM recent), '[]'::jsonb)
)::text;
SQL
)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]] || [[ -z "$query_output" ]]; then
    write_request_log_diagnostic "$output_file" "request_log_query_failed" "Sanitized request-log SQL inspection failed or returned no JSON"
    return 0
  fi

  python3 - "$output_file" "$RUN_ID" "$NAMESPACE" "$query_output" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, run_id, namespace, raw = sys.argv[1:5]
payload = json.loads(raw)
payload.update({
    "run_id": run_id,
    "namespace": namespace,
    "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
})
Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

write_request_log_diagnostic() {
  local output_file="$1"
  local reason_code="$2"
  local detail="$3"
  python3 - "$output_file" "$RUN_ID" "$NAMESPACE" "$reason_code" "$detail" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path, run_id, namespace, reason_code, detail = sys.argv[1:6]
Path(path).write_text(json.dumps({
    "run_id": run_id,
    "namespace": namespace,
    "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "source": "postgres.requests",
    "privacy": "metadata_only",
    "status": "diagnostic",
    "reason_code": reason_code,
    "detail": detail,
    "row_count": 0,
    "rows": [],
}, indent=2, sort_keys=True) + "\n")
PY
}

write_retention_artifacts() {
  local reason="$1"
  local exit_code="$2"
  local retained_file cleanup_file
  retained_file="$(run_dir)/retained-namespace.txt"
  cleanup_file="$(run_dir)/cleanup-command.txt"
  mkdir -p "$(run_dir)"

  capture_request_log_evidence

  {
    printf 'namespace=%s\n' "$NAMESPACE"
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'reason=%s\n' "$reason"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'evidence_dir=%s\n' "$(run_dir)"
    printf 'retained_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$retained_file"

  {
    printf '# cleanup retained Docker Desktop perf namespace\n'
    printf 'kubectl config current-context  # must print docker-desktop\n'
    printf 'scripts/dev/gateway-perf-k8s.sh down\n'
  } > "$cleanup_file"

  redact_file "$retained_file"
  redact_file "$cleanup_file"
  redact_file "$(run_dir)/request-log-sanitized.json"
}

retain_failure_and_exit() {
  local reason="$1"
  local exit_code="$2"
  write_retention_artifacts "$reason" "$exit_code"
  write_selected_path_manifest || true
  if ! run_sanitizer; then
    if [[ "$reason" != "sanitizer_failed" ]]; then
      reason="${reason}+sanitizer_failed"
    fi
    write_retention_artifacts "$reason" "$exit_code"
    write_selected_path_manifest || true
  fi
  log_info "retained namespace $NAMESPACE for $reason"
  log_info "retained evidence: $(run_dir)"
  log_info "cleanup instructions: $(run_dir)/cleanup-command.txt"
  exit "$exit_code"
}

cmd_run() {
  local arg profile runner_rc=0 final_rc=0 failure_reason=""
  for arg in "$@"; do
    if [[ "$arg" == "--memory-profile" ]]; then
      fail "run always executes safe then low profiles and does not accept --memory-profile"
    fi
  done
  parse_common_args "$@"
  [[ "$RUN_ID_PROVIDED" == "true" ]] || fail "run requires --run-id"
  validate_run_id
  validate_scenario
  validate_duration_scale
  validate_budget_target
  mutating_preamble
  require_command docker
  require_command rg

  mkdir -p "$(run_dir)"
  build_local_image_if_needed

  for profile in safe low; do
    MEMORY_PROFILE="$profile"
    log_info "starting $profile profile"
    apply_static_resources
    set +e
    run_runner_job
    runner_rc=$?
    set -e
    if [[ "$runner_rc" -ne 0 ]]; then
      final_rc="$runner_rc"
      if [[ "$runner_rc" -eq 20 ]]; then
        failure_reason="scenario_or_budget_failed_$profile"
      else
        failure_reason="runner_or_capture_failed_$profile"
      fi
      break
    fi
  done

  if ! write_final_report; then
    retain_failure_and_exit "final_report_failed" 1
  fi

  if [[ "$final_rc" -eq 0 ]]; then
    write_selected_path_manifest
    if ! run_sanitizer; then
      retain_failure_and_exit "sanitizer_failed" 1
    fi
    cmd_down
    return 0
  fi

  retain_failure_and_exit "$failure_reason" "$final_rc"
}

cmd_down() {
  parse_common_args "$@"
  mutating_preamble
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  log_info "namespace $NAMESPACE deleted"
}

main() {
  local command="${1:-}"
  if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    exit 0
  fi
  shift

  case "$command" in
    up) cmd_up "$@" ;;
    capture) cmd_capture "$@" ;;
    run) cmd_run "$@" ;;
    down) cmd_down "$@" ;;
    render) parse_common_args "$@"; validate_budget_target; render_manifests ;;
    *) usage >&2; fail "unknown command '$command'" ;;
  esac
}

main "$@"
