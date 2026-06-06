#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SMOKE_ROOT="tmp/openclaw-smoke"
OPENCLAW_SMOKE_RUN_ID="${OPENCLAW_SMOKE_RUN_ID:-}"
OPENCLAW_SMOKE_LOG_ROOT="${OPENCLAW_SMOKE_LOG_ROOT:-$SMOKE_ROOT/logs}"
OPENCLAW_SMOKE_TIMEOUT_SECONDS="${OPENCLAW_SMOKE_TIMEOUT_SECONDS:-300}"
OPENCLAW_SMOKE_BASE_URL="${OPENCLAW_SMOKE_BASE_URL:-${OPENAI_BASE_URL:-http://127.0.0.1:4000/v1}}"
OPENCLAW_SMOKE_MODEL="${OPENCLAW_SMOKE_MODEL:-gpt-5.5}"
OPENCLAW_SMOKE_PROVIDER_ID="${OPENCLAW_SMOKE_PROVIDER_ID:-openai}"
OPENCLAW_SMOKE_DB_URL="${OPENCLAW_SMOKE_DB_URL:-${CODEX_SMOKE_DB_URL:-postgres://postgres:postgres@localhost:5433/codex_pooler_dev}}"
OPENCLAW_SMOKE_DB_RETRY_SECONDS="${OPENCLAW_SMOKE_DB_RETRY_SECONDS:-30}"
OPENCLAW_SMOKE_MCP_URL="${OPENCLAW_SMOKE_MCP_URL:-}"
OPENCLAW_SMOKE_MCP_SERVER_NAME="${OPENCLAW_SMOKE_MCP_SERVER_NAME:-codex_pooler}"
OPENCLAW_SMOKE_MCP_EXPECTED_TOOL="${OPENCLAW_SMOKE_MCP_EXPECTED_TOOL:-codex_pooler_get_mcp_service_status}"
OPENCLAW_SMOKE_MCP_TOKEN_FILE="${OPENCLAW_SMOKE_MCP_TOKEN_FILE:-}"
ORIGINAL_HOME="${HOME:-}"
ORIGINAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"
ORIGINAL_XDG_CACHE_HOME="${XDG_CACHE_HOME:-}"
ORIGINAL_XDG_DATA_HOME="${XDG_DATA_HOME:-}"
SMOKE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

DRY_RUN=false
RUN_ID_PROVIDED=false
REUSE_EXISTING_RUN=false
RUN_ID=""
RUN_DIR=""
HOME_DIR=""
CONFIG_DIR=""
CACHE_DIR=""
DATA_DIR=""
STATE_DIR=""
WORKSPACE_DIR=""
CONFIG_PATH=""
COMMANDS_FILE=""
BINARY_METADATA_FILE=""
CONFIG_METADATA_FILE=""
PROVIDER_METADATA_FILE=""
ONESHOT_METADATA_FILE=""
AGENT_METADATA_FILE=""
IMAGE_METADATA_FILE=""
EVIDENCE_METADATA_FILE=""
MCP_METADATA_FILE=""
REDACTION_METADATA_FILE=""
START_METADATA_FILE=""
SUMMARY_FILE=""
STATUS="succeeded"
FAILURE_CLASS=""
OPENCLAW_PATH=""
OPENCLAW_VERSION=""
OPENCLAW_INSTALL_ACTION="not_needed"
EFFECTIVE_API_KEY=""
EFFECTIVE_API_KEY_SOURCE=""
EFFECTIVE_MCP_KEY=""
EFFECTIVE_MCP_KEY_SOURCE=""
MCP_TOKEN_FILE=""
SMOKE_TEXT_MODEL=""
CONFIG_READY=false
PROVIDER_READY=false
declare -a STAGES=()
declare -a COMPLETED_STAGES=()

usage() {
  cat <<'EOF'
Usage: scripts/dev/openclaw-smoke.sh [options]

Stages:
  config    generate isolated OpenClaw JSON5 provider config plus sanitized metadata
  provider  check local /v1/models readiness for the configured text model
  oneshot   run a real OpenClaw one-shot text smoke through the configured /v1 provider
  agent     run a real OpenClaw agent --local smoke through the configured /v1 provider
  image     run a real OpenClaw image/vision smoke through the configured /v1 provider
  evidence  verify metadata-only request-log evidence for completed /v1 smoke stages
  mcp       configure isolated OpenClaw MCP and prove catalog/tool visibility through OpenClaw MCP CLI
  redact    scan generated metadata artifacts for raw secret/body leaks
  all       expands to config, provider, oneshot, agent, image, evidence, mcp, redact. Default when --stage is omitted

Options:
  --stage NAME  Add a stage. Repeatable. Defaults to all when omitted
  --run-id ID   Use an explicit run id. Must match [A-Za-z0-9._-]+
  --dry-run     Write isolated metadata artifacts only. No Codex Pooler calls and no OpenClaw execution
  --help        Show this message

Environment:
  OPENCLAW_SMOKE_RUN_ID          optional run id; overridden by --run-id
  OPENCLAW_SMOKE_LOG_ROOT        defaults to tmp/openclaw-smoke/logs
  OPENCLAW_SMOKE_TIMEOUT_SECONDS bounds real OpenClaw execution stages; defaults to 300
  OPENCLAW_SMOKE_BASE_URL        defaults to http://127.0.0.1:4000/v1
  OPENCLAW_SMOKE_MODEL           selected model for /v1 checks; defaults to gpt-5.5
  OPENCLAW_SMOKE_PROVIDER_ID     defaults to openai
  OPENCLAW_SMOKE_DB_URL          defaults to CODEX_SMOKE_DB_URL or local dev Postgres
  OPENCLAW_SMOKE_DB_RETRY_SECONDS bounds DB evidence polling; defaults to 30
  OPENCLAW_SMOKE_MCP_URL          defaults to OPENCLAW_SMOKE_BASE_URL origin plus /mcp
  OPENCLAW_SMOKE_MCP_KEY          optional override for MCP token negative-path QA
  OPENCLAW_SMOKE_MCP_TOKEN_FILE   optional disposable MCP token path when env token is absent
  CODEX_POOLER_MCP_KEY            preferred MCP token source for real mcp stage
  OPENCLAW_SMOKE_EVIDENCE_FIXTURE=unexpected_failed_row injects deterministic evidence failure
  OPENCLAW_SMOKE_REDACTION_FIXTURE=leak injects deterministic redaction failure
  CODEX_POOLER_API_KEY           required for real config/provider stages

Safety:
  This helper is local-dev-only and targets localhost smoke workflows only.
  It never reads or mutates the operator's real ~/.openclaw config.
  Per-run HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_DATA_HOME, OPENCLAW_CONFIG_PATH,
  and OPENCLAW_STATE_DIR are isolated under tmp/openclaw-smoke/home/<run-id>.
  Dry-run writes metadata-only logs and summary.json, and does not call Codex Pooler or
  execute OpenClaw/provider/MCP traffic.
  Real config/provider stages use CODEX_POOLER_API_KEY directly and never provision
  fake smoke pools, upstreams, API keys, or dev bootstrap rows. The MCP stage
  uses CODEX_POOLER_MCP_KEY or a disposable operator MCP token, never the Pool API key.
  Evidence must remain metadata-only: no raw API keys, bearer tokens, auth JSON,
  prompts beyond the fixed sentinel, request/response bodies, media bytes, websocket frames,
  raw stdout/stderr copies outside ignored tmp/openclaw-smoke logs, or raw idempotency keys.
  If openclaw is missing for real validation and npm is available, the helper installs the latest stable
  official npm package openclaw@<latest>, never beta unless latest stable is beta. If npm is not
  available, it fails quickly with missing_binary before any app/provider traffic.
EOF
}

fail() {
  local class="$1"
  shift
  STATUS="failed"
  FAILURE_CLASS="$class"
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log_info() {
  printf '[openclaw-smoke] %s\n' "$*"
}

append_stage() {
  case "$1" in
    config|provider|oneshot|agent|image|evidence|mcp|redact)
      STAGES+=("$1")
      ;;
    all)
      STAGES+=(config provider oneshot agent image evidence mcp redact)
      ;;
    *)
      fail argument "unsupported stage '$1'"
      ;;
  esac
}

parse_args() {
  RUN_ID="$OPENCLAW_SMOKE_RUN_ID"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      --stage)
        [[ $# -ge 2 ]] || fail argument "--stage requires a value"
        append_stage "$2"
        shift
        ;;
      --run-id)
        [[ $# -ge 2 ]] || fail argument "--run-id requires a value"
        RUN_ID="$2"
        RUN_ID_PROVIDED=true
        shift
        ;;
      *)
        fail argument "unknown argument '$1'"
        ;;
    esac
    shift
  done

  if [[ ${#STAGES[@]} -eq 0 ]]; then
    append_stage all
  fi

  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi

  validate_run_id
  derive_paths
  validate_fresh_run_paths
}

validate_run_id() {
  if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail invalid_run_id "--run-id may contain only letters, numbers, dot, underscore, and dash"
  fi
}

derive_paths() {
  RUN_DIR="$OPENCLAW_SMOKE_LOG_ROOT/$RUN_ID"
  HOME_DIR="$SMOKE_ROOT/home/$RUN_ID"
  CONFIG_DIR="$HOME_DIR/.config"
  CACHE_DIR="$HOME_DIR/.cache"
  DATA_DIR="$HOME_DIR/.local/share"
  STATE_DIR="$HOME_DIR/state"
  WORKSPACE_DIR="$SMOKE_ROOT/workspace/$RUN_ID"
  CONFIG_PATH="$CONFIG_DIR/openclaw/openclaw.json"
  COMMANDS_FILE="$RUN_DIR/commands.txt"
  BINARY_METADATA_FILE="$RUN_DIR/openclaw-binary.log"
  CONFIG_METADATA_FILE="$RUN_DIR/openclaw-config-metadata.json"
  PROVIDER_METADATA_FILE="$RUN_DIR/openclaw-provider-metadata.json"
  ONESHOT_METADATA_FILE="$RUN_DIR/openclaw-oneshot-metadata.json"
  AGENT_METADATA_FILE="$RUN_DIR/openclaw-agent-metadata.json"
  IMAGE_METADATA_FILE="$RUN_DIR/openclaw-image-metadata.json"
  EVIDENCE_METADATA_FILE="$RUN_DIR/openclaw-evidence-metadata.json"
  MCP_METADATA_FILE="$RUN_DIR/openclaw-mcp-metadata.json"
  REDACTION_METADATA_FILE="$RUN_DIR/openclaw-redaction-metadata.json"
  MCP_TOKEN_FILE="${OPENCLAW_SMOKE_MCP_TOKEN_FILE:-$HOME_DIR/mcp-token}"
  START_METADATA_FILE="$RUN_DIR/run-start.json"
  SUMMARY_FILE="$RUN_DIR/summary.json"
}

safe_rm_dry_run_path() {
  local target="$1"
  case "$target" in
    tmp/openclaw-smoke/logs/openclaw-dry-run|tmp/openclaw-smoke/home/openclaw-dry-run|tmp/openclaw-smoke/workspace/openclaw-dry-run)
      rm -rf "$target"
      ;;
    *)
      fail internal "refusing to clean unexpected dry-run path: $target"
      ;;
  esac
}

stages_allow_existing_run() {
  local stage
  for stage in "${STAGES[@]}"; do
    case "$stage" in
      evidence|redact)
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 0
}

write_start_metadata() {
  [[ "$REUSE_EXISTING_RUN" == "true" ]] && return 0
  /usr/bin/python3 - "$START_METADATA_FILE" "$RUN_ID" "$SMOKE_STARTED_AT" "$OPENCLAW_SMOKE_MODEL" "${OPENCLAW_SMOKE_BASE_URL%/}" <<'START_META_PY'
import json
import sys
from pathlib import Path

output, run_id, started_at, model, base_url = sys.argv[1:6]
metadata = {
    "run_id": run_id,
    "smoke_started_at": started_at,
    "base_url": base_url,
    "selected_model": model,
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
START_META_PY
}

read_smoke_started_at() {
  if [[ -f "$START_METADATA_FILE" ]]; then
    /usr/bin/python3 - "$START_METADATA_FILE" <<'READ_START_PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text()).get("smoke_started_at", ""))
READ_START_PY
    return 0
  fi

  if [[ -f "$SUMMARY_FILE" ]]; then
    local summary_started_at
    summary_started_at="$(/usr/bin/python3 - "$SUMMARY_FILE" <<'READ_SUMMARY_START_PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print(summary.get("smoke_started_at") or "")
READ_SUMMARY_START_PY
)"
    if [[ -n "$summary_started_at" ]]; then
      printf '%s\n' "$summary_started_at"
      return 0
    fi
  fi

  printf '%s\n' "$SMOKE_STARTED_AT"
}

read_smoke_model() {
  if [[ -f "$START_METADATA_FILE" ]]; then
    /usr/bin/python3 - "$START_METADATA_FILE" <<'READ_MODEL_START_PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text()).get("selected_model", ""))
READ_MODEL_START_PY
    return 0
  fi

  if [[ -f "$SUMMARY_FILE" ]]; then
    /usr/bin/python3 - "$SUMMARY_FILE" <<'READ_MODEL_SUMMARY_PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print((summary.get("provider_config") or {}).get("selected_model") or "")
READ_MODEL_SUMMARY_PY
    return 0
  fi

  printf '%s\n' "$OPENCLAW_SMOKE_MODEL"
}

validate_fresh_run_paths() {
  if [[ -e "$RUN_DIR" || -e "$HOME_DIR" || -e "$WORKSPACE_DIR" ]]; then
    if [[ "$DRY_RUN" == "true" && "$RUN_ID" == "openclaw-dry-run" ]]; then
      safe_rm_dry_run_path "$RUN_DIR"
      safe_rm_dry_run_path "$HOME_DIR"
      safe_rm_dry_run_path "$WORKSPACE_DIR"
      return 0
    fi

    if [[ "$RUN_ID_PROVIDED" == "true" ]] && stages_allow_existing_run; then
      REUSE_EXISTING_RUN=true
      return 0
    fi

    if [[ "$RUN_ID_PROVIDED" == "true" ]]; then
      fail stale_run "run artifacts already exist for provided run id: $RUN_ID"
    fi

    fail stale_run "generated run artifacts already exist for run id: $RUN_ID"
  fi
}

prepare_directories() {
  mkdir -p "$RUN_DIR/stages" "$CONFIG_DIR/openclaw" "$CACHE_DIR" "$DATA_DIR" "$STATE_DIR" "$WORKSPACE_DIR"
  chmod 700 "$HOME_DIR" "$STATE_DIR"
  if [[ "$REUSE_EXISTING_RUN" != "true" ]]; then
    : > "$COMMANDS_FILE"
  fi
}

record_command() {
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
  printf '%s\n' "$output" >> "$COMMANDS_FILE"
}

resolve_latest_stable_openclaw() {
  /usr/bin/python3 - <<'LATEST_PY'
import json
import subprocess

output = subprocess.check_output(['npm', 'view', 'openclaw', 'dist-tags.latest', '--json'], text=True)
print(json.loads(output))
LATEST_PY
}

capture_openclaw_version() {
  local version_output
  if [[ -n "$OPENCLAW_PATH" ]]; then
    version_output="$("$OPENCLAW_PATH" --version 2>&1 || true)"
    version_output="${version_output//$'\n'/ }"
    OPENCLAW_VERSION="$version_output"
  fi
}

ensure_openclaw() {
  if OPENCLAW_PATH="$(command -v openclaw 2>/dev/null)"; then
    OPENCLAW_INSTALL_ACTION="not_needed"
    capture_openclaw_version
    write_binary_metadata
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    OPENCLAW_PATH=""
    OPENCLAW_VERSION=""
    OPENCLAW_INSTALL_ACTION="not_attempted_npm_missing"
    write_binary_metadata
    fail missing_binary "openclaw CLI is not installed or not on PATH, and npm is unavailable for official install"
  fi

  local latest install_log
  if ! latest="$(resolve_latest_stable_openclaw)" || [[ -z "$latest" ]]; then
    OPENCLAW_PATH=""
    OPENCLAW_VERSION=""
    OPENCLAW_INSTALL_ACTION="npm_latest_resolution_failed"
    write_binary_metadata
    fail missing_binary "could not resolve official openclaw latest stable version from npm"
  fi

  OPENCLAW_INSTALL_ACTION="npm install -g openclaw@$latest"
  install_log="$RUN_DIR/openclaw-install.log"
  log_info "openclaw missing; installing official stable openclaw@$latest"
  record_command npm install -g "openclaw@$latest"
  npm install -g "openclaw@$latest" > "$install_log" 2>&1 || fail missing_binary "official OpenClaw install failed; see $install_log"

  if ! OPENCLAW_PATH="$(command -v openclaw 2>/dev/null)"; then
    fail missing_binary "openclaw still missing after official npm install"
  fi
  capture_openclaw_version
  write_binary_metadata
}

write_binary_metadata() {
  {
    printf '[openclaw] present=%s\n' "$([[ -n "$OPENCLAW_PATH" ]] && printf true || printf false)"
    printf '[openclaw] path=%s\n' "${OPENCLAW_PATH:-missing}"
    printf '[openclaw] version=%s\n' "${OPENCLAW_VERSION:-unknown}"
    printf '[openclaw] install_action=%s\n' "$OPENCLAW_INSTALL_ACTION"
    printf '[openclaw] official_source=npm:openclaw\n'
  } > "$BINARY_METADATA_FILE"
}

export_isolation_env() {
  export HOME="$ROOT_DIR/$HOME_DIR"
  export XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR"
  export XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR"
  export XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR"
  export OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR"
  export OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH"
}

write_scaffold_config() {
  cat > "$CONFIG_PATH" <<'JSON'
{
  "openclawSmokeScaffold": true,
  "note": "Dry-run writes isolated metadata for the complete OpenClaw validation runner without provider traffic."
}
JSON
  chmod 600 "$CONFIG_PATH"
}

require_env_credentials() {
  SMOKE_TEXT_MODEL="$OPENCLAW_SMOKE_MODEL"
  if [[ -n "${OPENCLAW_SMOKE_API_KEY:-}" ]]; then
    EFFECTIVE_API_KEY="$OPENCLAW_SMOKE_API_KEY"
    EFFECTIVE_API_KEY_SOURCE="OPENCLAW_SMOKE_API_KEY"
  else
    EFFECTIVE_API_KEY="${CODEX_POOLER_API_KEY:-}"
    EFFECTIVE_API_KEY_SOURCE="CODEX_POOLER_API_KEY"
  fi

  [[ -n "$SMOKE_TEXT_MODEL" ]] || fail missing_env "OPENCLAW_SMOKE_MODEL must not be empty"
  [[ -n "$EFFECTIVE_API_KEY" ]] || fail missing_env "CODEX_POOLER_API_KEY is required for real OpenClaw config/provider stages, unless OPENCLAW_SMOKE_API_KEY is set for negative-path QA"
}

write_openclaw_provider_config() {
  CODEX_POOLER_API_KEY="$EFFECTIVE_API_KEY" /usr/bin/python3 - "$CONFIG_PATH" "$OPENCLAW_SMOKE_PROVIDER_ID" "$OPENCLAW_SMOKE_BASE_URL" "$SMOKE_TEXT_MODEL" "$OPENCLAW_SMOKE_TIMEOUT_SECONDS" <<'CONFIG_PY'
import json
import os
import sys
from pathlib import Path

output, provider_id, base_url, model_id, timeout_seconds = sys.argv[1:6]
api_key = os.environ["CODEX_POOLER_API_KEY"]

def js(value):
    return json.dumps(value)

config = f'''{{
  agents: {{
    defaults: {{
      model: {{ primary: {js(provider_id + "/" + model_id)} }},
    }},
  }},
  models: {{
    mode: "merge",
    providers: {{
      {js(provider_id)}: {{
        baseUrl: {js(base_url.rstrip("/"))},
        apiKey: {js(api_key)},
        api: "openai-responses",
        agentRuntime: {{ id: "openclaw" }},
        timeoutSeconds: {int(timeout_seconds)},
        models: [
          {{
            id: {js(model_id)},
            name: {js(model_id + " via Codex Pooler")},
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 400000,
            contextTokens: 256000,
            maxTokens: 128000,
          }},
        ],
      }},
    }},
  }},
}}
'''
Path(output).write_text(config)
CONFIG_PY
  chmod 600 "$CONFIG_PATH"
}

write_config_metadata() {
  /usr/bin/python3 - "$CONFIG_METADATA_FILE" "$RUN_ID" "$EFFECTIVE_API_KEY_SOURCE" "$OPENCLAW_SMOKE_PROVIDER_ID" "$OPENCLAW_SMOKE_BASE_URL" "$SMOKE_TEXT_MODEL" "$CONFIG_PATH" "$OPENCLAW_PATH" "$OPENCLAW_VERSION" "$OPENCLAW_INSTALL_ACTION" <<'META_PY'
import json
import sys
from pathlib import Path

(
    output,
    run_id,
    credential_source,
    provider_id,
    base_url,
    text_model,
    config_path,
    openclaw_path,
    openclaw_version,
    install_action,
) = sys.argv[1:11]

metadata = {
    "run_id": run_id,
    "credential_source": credential_source,
    "provider": {
        "id": provider_id,
        "base_url": base_url.rstrip("/"),
        "api": "openai-responses",
        "agent_runtime": "openclaw",
        "selected_model": text_model,
    },
    "openclaw": {
        "path": openclaw_path,
        "version": openclaw_version,
        "install_action": install_action,
        "config_path": config_path,
    },
    "redaction": {
        "raw_pool_api_key_recorded": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
META_PY
}

ensure_config_contract() {
  if [[ "$CONFIG_READY" == "true" ]]; then
    return 0
  fi

  require_env_credentials
  write_openclaw_provider_config
  write_config_metadata
  CONFIG_READY=true
}

run_config_stage() {
  if [[ "$DRY_RUN" == "true" ]]; then
    write_stage_log config
    return 0
  fi

  ensure_config_contract
  {
    printf '[stage] config\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real config; local /v1 provider; metadata-only\n'
    printf '[credential-source] %s\n' "$EFFECTIVE_API_KEY_SOURCE"
    printf '[provider-id] %s\n' "$OPENCLAW_SMOKE_PROVIDER_ID"
    printf '[base-url] %s\n' "${OPENCLAW_SMOKE_BASE_URL%/}"
    printf '[selected-model] %s\n' "$SMOKE_TEXT_MODEL"
    printf '[openclaw-path] %s\n' "$OPENCLAW_PATH"
    printf '[openclaw-version] %s\n' "$OPENCLAW_VERSION"
    printf '[config-path] %s\n' "$CONFIG_PATH"
    printf '[metadata] %s\n' "$CONFIG_METADATA_FILE"
    printf '[status] config-ok\n'
  } > "$RUN_DIR/stages/config.log"
  COMPLETED_STAGES+=(config)
  log_info "config metadata written to $RUN_DIR/stages/config.log"
}

run_provider_stage() {
  if [[ "$PROVIDER_READY" == "true" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    write_stage_log provider
    PROVIDER_READY=true
    return 0
  fi

  ensure_config_contract
  record_command curl -fsS -H "Authorization: Bearer <redacted>" "${OPENCLAW_SMOKE_BASE_URL%/}/models"

  local provider_result
  if ! provider_result="$(CODEX_POOLER_API_KEY="$EFFECTIVE_API_KEY" /usr/bin/python3 - "$PROVIDER_METADATA_FILE" "$RUN_ID" "$EFFECTIVE_API_KEY_SOURCE" "$OPENCLAW_SMOKE_PROVIDER_ID" "$OPENCLAW_SMOKE_BASE_URL" "$SMOKE_TEXT_MODEL" "$OPENCLAW_PATH" "$OPENCLAW_VERSION" <<'PROVIDER_PY'
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path

output, run_id, credential_source, provider_id, base_url, selected_model, openclaw_path, openclaw_version = sys.argv[1:9]
api_key = os.environ["CODEX_POOLER_API_KEY"]
models_url = base_url.rstrip("/") + "/models"
metadata = {
    "run_id": run_id,
    "provider": {"id": provider_id, "base_url": base_url.rstrip("/"), "selected_model": selected_model},
    "credential_source": credential_source,
    "openclaw": {"path": openclaw_path, "version": openclaw_version},
    "request": {"method": "GET", "path": "/v1/models"},
    "status": "failed",
    "failure_class": None,
    "http_status": None,
    "model_count": 0,
    "selected_model_visible": False,
}

def finish(status, failure_class=None):
    metadata["status"] = status
    metadata["failure_class"] = failure_class
    Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    if failure_class:
        print(failure_class)
        sys.exit(1)
    print("ok")

request = urllib.request.Request(models_url, headers={"Authorization": f"Bearer {api_key}"})
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        metadata["http_status"] = response.status
        raw_body = response.read()
except urllib.error.HTTPError as error:
    metadata["http_status"] = error.code
    if error.code in (401, 403):
        finish("failed", "auth")
    finish("failed", "provider_unready")
except (urllib.error.URLError, TimeoutError, socket.timeout):
    finish("failed", "app_unavailable")

try:
    body = json.loads(raw_body.decode("utf-8"))
except Exception:
    finish("failed", "provider_unready")

model_ids = [model.get("id") for model in body.get("data", []) if isinstance(model, dict) and model.get("id")]
metadata["model_count"] = len(model_ids)
metadata["selected_model_visible"] = selected_model in model_ids

if metadata["http_status"] != 200:
    finish("failed", "provider_unready")
if selected_model not in model_ids:
    finish("failed", "provider_unready")

finish("succeeded")
PROVIDER_PY
)"; then
    fail "$provider_result" "provider readiness failed with class '$provider_result'; see $PROVIDER_METADATA_FILE"
  fi

  {
    printf '[stage] provider\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real provider readiness; local /v1/models; metadata-only\n'
    printf '[provider-id] %s\n' "$OPENCLAW_SMOKE_PROVIDER_ID"
    printf '[base-url] %s\n' "${OPENCLAW_SMOKE_BASE_URL%/}"
    printf '[selected-model] %s\n' "$SMOKE_TEXT_MODEL"
    printf '[credential-source] %s\n' "$EFFECTIVE_API_KEY_SOURCE"
    printf '[metadata] %s\n' "$PROVIDER_METADATA_FILE"
    printf '[status] provider-ok\n'
  } > "$RUN_DIR/stages/provider.log"
  COMPLETED_STAGES+=(provider)
  PROVIDER_READY=true
  log_info "provider metadata written to $RUN_DIR/stages/provider.log"
}


openclaw_sentinel_for() {
  printf 'OPENCLAW_SMOKE_OK_%s' "$RUN_ID"
}

timeout_exec() {
  perl -e 'alarm shift; exec @ARGV' "$OPENCLAW_SMOKE_TIMEOUT_SECONDS" "$@"
}

write_oneshot_metadata() {
  local stdout_file="$1"
  local stderr_file="$2"
  local rc="$3"
  local sentinel="$4"
  local command_shape="$5"
  /usr/bin/python3 - "$ONESHOT_METADATA_FILE" "$stdout_file" "$stderr_file" "$RUN_ID" "$sentinel" "$OPENCLAW_SMOKE_PROVIDER_ID" "$SMOKE_TEXT_MODEL" "${OPENCLAW_SMOKE_BASE_URL%/}" "$rc" "$command_shape" <<'ONESHOT_META_PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    output,
    stdout_file,
    stderr_file,
    run_id,
    sentinel,
    provider_id,
    model_id,
    base_url,
    exit_status,
    command_shape,
) = sys.argv[1:11]

exit_status_int = int(exit_status)
stdout_path = Path(stdout_file)
stderr_path = Path(stderr_file)
stdout_text = stdout_path.read_text(errors="replace") if stdout_path.exists() else ""
stderr_text = stderr_path.read_text(errors="replace") if stderr_path.exists() else ""
parsed_text = None
parsed_field_path = None
parse_error = None
payload = None


def normalize(value):
    return value.replace("\r", "").rstrip("\n")


def sha256(value):
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def load_json_candidate(raw):
    stripped = raw.strip()
    if not stripped:
        raise ValueError("empty stdout")
    try:
        return json.loads(stripped)
    except Exception:
        for line in reversed([candidate.strip() for candidate in raw.splitlines() if candidate.strip()]):
            if line.startswith("{") and line.endswith("}"):
                return json.loads(line)
        raise

try:
    payload = load_json_candidate(stdout_text)
    result = payload.get("result") if isinstance(payload, dict) else None
    payloads = result.get("payloads") if isinstance(result, dict) else None
    if isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parsed_text = item["text"]
                parsed_field_path = f"result.payloads[{index}].text"
    payloads = payload.get("payloads") if isinstance(payload, dict) else None
    if parsed_text is None and isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parsed_text = item["text"]
                parsed_field_path = f"payloads[{index}].text"
    outputs = payload.get("outputs") if isinstance(payload, dict) else None
    if parsed_text is None and isinstance(outputs, list):
        for index, item in enumerate(outputs):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parsed_text = item["text"]
                parsed_field_path = f"outputs[{index}].text"
    if parsed_text is None:
        parse_error = "missing result.payloads[].text, payloads[].text, or outputs[].text"
except Exception as error:
    parse_error = error.__class__.__name__

failure_class = None
status = "succeeded"
if exit_status_int != 0:
    combined = f"{stdout_text}\n{stderr_text}".lower()
    if exit_status_int in (124, 137, 142, 143) or "timed out" in combined or "timeout" in combined:
        failure_class = "timeout"
    elif re.search(r"\b(401|403|unauthorized|forbidden|auth|api key|bearer)\b", combined):
        failure_class = "auth"
    else:
        failure_class = "provider_config"
elif parse_error is not None:
    failure_class = "response_parse"
elif normalize(parsed_text or "") != sentinel:
    failure_class = "sentinel_mismatch"

if failure_class is not None:
    status = "failed"

metadata = {
    "run_id": run_id,
    "stage": "oneshot",
    "status": status,
    "failure_class": failure_class,
    "command": {
        "shape": command_shape,
        "surface": "infer model run",
        "selector": None,
        "json": True,
        "model": f"{provider_id}/{model_id}",
    },
    "provider": {
        "base_url": base_url,
        "id": provider_id,
        "selected_model": model_id,
    },
    "sentinel": sentinel,
    "parse": {
        "field_path": parsed_field_path,
        "parse_error": parse_error,
        "exact_match": failure_class is None,
        "parsed_text_bytes": len((parsed_text or "").encode("utf-8", errors="replace")) if parsed_text is not None else 0,
        "parsed_text_sha256": sha256(parsed_text) if parsed_text is not None else None,
    },
    "process": {
        "exit_status": exit_status_int,
        "stdout_bytes": stdout_path.stat().st_size if stdout_path.exists() else 0,
        "stdout_sha256": hashlib.sha256(stdout_path.read_bytes()).hexdigest() if stdout_path.exists() else None,
        "stderr_bytes": stderr_path.stat().st_size if stderr_path.exists() else 0,
        "stderr_sha256": hashlib.sha256(stderr_path.read_bytes()).hexdigest() if stderr_path.exists() else None,
    },
    "logs": {
        "stdout_json": stdout_file,
        "stderr_log": stderr_file,
    },
    "redaction": {
        "raw_pool_api_key_recorded": False,
        "raw_prompt_recorded": False,
        "raw_response_body_recorded_in_metadata": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
print(failure_class or "ok")
ONESHOT_META_PY
}

run_oneshot_stage() {
  local stage_log="$RUN_DIR/stages/oneshot.log"
  local stdout_file="$RUN_DIR/openclaw-oneshot.stdout.json"
  local stderr_file="$RUN_DIR/openclaw-oneshot.stderr.log"
  local sentinel prompt rc result command_shape openclaw_bin_dir
  sentinel="$(openclaw_sentinel_for)"
  prompt="Output exactly this line and nothing else: $sentinel"
  rc=0
  command_shape="timeout_exec openclaw infer model run --local --json --model $OPENCLAW_SMOKE_PROVIDER_ID/$OPENCLAW_SMOKE_MODEL --prompt <sentinel:$sentinel>"
  openclaw_bin_dir="$(dirname "$OPENCLAW_PATH")"

  if [[ "$DRY_RUN" == "true" ]]; then
    {
      printf '[stage] oneshot\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[mode] dry-run; prerequisites and OpenClaw execution skipped\n'
      printf '[command-shape] %s\n' "$command_shape"
      printf '[sentinel] %s\n' "$sentinel"
      printf '[status] dry-run-only\n'
    } > "$stage_log"
    COMPLETED_STAGES+=(oneshot)
    log_info "oneshot dry-run metadata written to $stage_log"
    return 0
  fi

  run_provider_stage
  record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" OPENAI_API_KEY="<redacted>" openclaw infer model run --local --json --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" --prompt "<sentinel:$sentinel>"

  log_info "running OpenClaw oneshot with isolated OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
  timeout_exec env \
    PATH="$openclaw_bin_dir:$PATH" \
    HOME="$ROOT_DIR/$HOME_DIR" \
    XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
    XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
    XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
    OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
    OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
    OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" \
    OPENAI_API_KEY="$EFFECTIVE_API_KEY" \
    "$OPENCLAW_PATH" infer model run \
      --local \
      --json \
      --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" \
      --prompt "$prompt" \
      >"$stdout_file" 2>"$stderr_file" || rc=$?

  result="$(write_oneshot_metadata "$stdout_file" "$stderr_file" "$rc" "$sentinel" "$command_shape")"
  {
    printf '[stage] oneshot\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real OpenClaw local model one-shot through configured /v1 provider; raw output kept under tmp/openclaw-smoke only\n'
    printf '[command-shape] %s\n' "$command_shape"
    printf '[sentinel] %s\n' "$sentinel"
    printf '[parsed-field-path] result.payloads[].text, payloads[].text, or outputs[].text\n'
    printf '[exit] %s\n' "$rc"
    printf '[failure-class] %s\n' "$([[ "$result" == "ok" ]] && printf none || printf '%s' "$result")"
    printf '[metadata] %s\n' "$ONESHOT_METADATA_FILE"
    printf '[stdout-log] %s\n' "$stdout_file"
    printf '[stderr-log] %s\n' "$stderr_file"
    printf '[status] %s\n' "$([[ "$result" == "ok" ]] && printf oneshot-ok || printf failed)"
  } > "$stage_log"

  if [[ "$result" != "ok" ]]; then
    fail "$result" "OpenClaw oneshot failed with class '$result'; see $ONESHOT_METADATA_FILE"
  fi

  COMPLETED_STAGES+=(oneshot)
  log_info "oneshot metadata written to $ONESHOT_METADATA_FILE"
}

write_agent_metadata() {
  local stdout_file="$1"
  local stderr_file="$2"
  local rc="$3"
  local sentinel="$4"
  local command_shape="$5"
  /usr/bin/python3 - "$AGENT_METADATA_FILE" "$stdout_file" "$stderr_file" "$RUN_ID" "$sentinel" "$OPENCLAW_SMOKE_PROVIDER_ID" "$SMOKE_TEXT_MODEL" "${OPENCLAW_SMOKE_BASE_URL%/}" "$rc" "$command_shape" <<'AGENT_META_PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    output,
    stdout_file,
    stderr_file,
    run_id,
    sentinel,
    provider_id,
    model_id,
    base_url,
    exit_status,
    command_shape,
) = sys.argv[1:11]

exit_status_int = int(exit_status)
stdout_path = Path(stdout_file)
stderr_path = Path(stderr_file)
stdout_text = stdout_path.read_text(errors="replace") if stdout_path.exists() else ""
stderr_text = stderr_path.read_text(errors="replace") if stderr_path.exists() else ""
combined = f"{stdout_text}\n{stderr_text}"
combined_lower = combined.lower()
parsed_text = None
parsed_field_path = None
parse_error = None
payload = None


def normalize(value):
    return value.replace("\r", "").rstrip("\n")


def sha256(value):
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def load_json_candidate(raw):
    stripped = raw.strip()
    if not stripped:
        raise ValueError("empty stdout")
    try:
        return json.loads(stripped)
    except Exception:
        for line in reversed([candidate.strip() for candidate in raw.splitlines() if candidate.strip()]):
            if line.startswith("{") and line.endswith("}"):
                return json.loads(line)
        raise


def extract_text(value):
    result = value.get("result") if isinstance(value, dict) else None
    payloads = result.get("payloads") if isinstance(result, dict) else None
    if isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"result.payloads[{index}].text"
    payloads = value.get("payloads") if isinstance(value, dict) else None
    if isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"payloads[{index}].text"
    outputs = value.get("outputs") if isinstance(value, dict) else None
    if isinstance(outputs, list):
        for index, item in enumerate(outputs):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"outputs[{index}].text"
    summary = value.get("summary") if isinstance(value, dict) else None
    if isinstance(summary, str):
        return summary, "summary"
    return None, None


try:
    payload = load_json_candidate(stdout_text)
    parsed_text, parsed_field_path = extract_text(payload)
    if parsed_text is None:
        parse_error = "missing result.payloads[].text, payloads[].text, outputs[].text, or summary"
except Exception as error:
    if stdout_text.strip():
        parse_error = error.__class__.__name__

failure_class = None
status = "succeeded"
diagnostic = None
http_status = None
upstream_error_code = None
upstream_error_type = None

status_match = re.search(r"status=(\d{3})", combined)
if status_match:
    http_status = int(status_match.group(1))

code_match = re.search(r"code=([A-Za-z0-9_.:-]+)", combined)
if code_match:
    upstream_error_code = code_match.group(1)

type_match = re.search(r"type=([A-Za-z0-9_.:-]+)", combined)
if type_match:
    upstream_error_type = type_match.group(1)

if exit_status_int != 0:
    if exit_status_int in (124, 137, 142, 143) or "timed out" in combined_lower or "timeout" in combined_lower:
        failure_class = "timeout"
    elif re.search(r"\b(401|403|unauthorized|forbidden|auth|api key|bearer)\b", combined_lower):
        failure_class = "auth"
    elif http_status == 400 and upstream_error_code == "upstream_status":
        failure_class = "upstream_rejected_agent_shape"
        diagnostic = "Codex Pooler admitted and forwarded OpenClaw agent --local Responses payload; upstream returned 400 upstream_status for the tool-heavy agent shape."
    elif http_status == 400:
        failure_class = "agent_payload_rejected"
        diagnostic = "OpenClaw agent --local produced a request that failed with HTTP 400 before a successful final agent result."
    else:
        failure_class = "agent_runtime_failed"
elif parse_error is not None:
    failure_class = "response_parse"
elif normalize(parsed_text or "") != sentinel:
    failure_class = "sentinel_mismatch"

if failure_class is not None:
    status = "failed"

metadata = {
    "run_id": run_id,
    "stage": "agent",
    "status": status,
    "failure_class": failure_class,
    "diagnostic": diagnostic,
    "command": {
        "shape": command_shape,
        "surface": "agent --local",
        "selector": "--agent main",
        "json": True,
        "model": f"{provider_id}/{model_id}",
    },
    "provider": {
        "base_url": base_url,
        "id": provider_id,
        "selected_model": model_id,
    },
    "sentinel": sentinel,
    "parse": {
        "field_path": parsed_field_path,
        "parse_error": parse_error,
        "exact_match": failure_class is None,
        "parsed_text_bytes": len((parsed_text or "").encode("utf-8", errors="replace")) if parsed_text is not None else 0,
        "parsed_text_sha256": sha256(parsed_text) if parsed_text is not None else None,
    },
    "process": {
        "exit_status": exit_status_int,
        "stdout_bytes": stdout_path.stat().st_size if stdout_path.exists() else 0,
        "stdout_sha256": hashlib.sha256(stdout_path.read_bytes()).hexdigest() if stdout_path.exists() else None,
        "stderr_bytes": stderr_path.stat().st_size if stderr_path.exists() else 0,
        "stderr_sha256": hashlib.sha256(stderr_path.read_bytes()).hexdigest() if stderr_path.exists() else None,
    },
    "observed_error": {
        "http_status": http_status,
        "code": upstream_error_code,
        "type": upstream_error_type,
    },
    "logs": {
        "stdout_json": stdout_file,
        "stderr_log": stderr_file,
    },
    "redaction": {
        "raw_pool_api_key_recorded": False,
        "raw_prompt_recorded": False,
        "raw_request_body_recorded_in_metadata": False,
        "raw_response_body_recorded_in_metadata": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
print(failure_class or "ok")
AGENT_META_PY
}

run_agent_stage() {
  local stage_log="$RUN_DIR/stages/agent.log"
  local stdout_file="$RUN_DIR/openclaw-agent.stdout.json"
  local stderr_file="$RUN_DIR/openclaw-agent.stderr.log"
  local sentinel prompt rc result command_shape openclaw_bin_dir
  sentinel="$(openclaw_sentinel_for)"
  prompt="Reply with exactly this line and nothing else: $sentinel"
  rc=0
  command_shape="timeout_exec openclaw agent --local --json --agent main --model $OPENCLAW_SMOKE_PROVIDER_ID/$OPENCLAW_SMOKE_MODEL --message <sentinel:$sentinel>"
  openclaw_bin_dir="$(dirname "$OPENCLAW_PATH")"

  if [[ "$DRY_RUN" == "true" ]]; then
    {
      printf '[stage] agent\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[mode] dry-run; prerequisites and OpenClaw execution skipped\n'
      printf '[command-shape] %s\n' "$command_shape"
      printf '[sentinel] %s\n' "$sentinel"
      printf '[status] dry-run-only\n'
    } > "$stage_log"
    COMPLETED_STAGES+=(agent)
    log_info "agent dry-run metadata written to $stage_log"
    return 0
  fi

  run_provider_stage
  record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" OPENAI_API_KEY="<redacted>" openclaw agent --local --json --agent main --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" --message "<sentinel:$sentinel>"

  log_info "running OpenClaw agent --local with isolated OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
  timeout_exec env \
    PATH="$openclaw_bin_dir:$PATH" \
    HOME="$ROOT_DIR/$HOME_DIR" \
    XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
    XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
    XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
    OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
    OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
    OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" \
    OPENAI_API_KEY="$EFFECTIVE_API_KEY" \
    "$OPENCLAW_PATH" agent \
      --local \
      --json \
      --agent main \
      --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" \
      --message "$prompt" \
      >"$stdout_file" 2>"$stderr_file" || rc=$?

  result="$(write_agent_metadata "$stdout_file" "$stderr_file" "$rc" "$sentinel" "$command_shape")"
  {
    printf '[stage] agent\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real OpenClaw local agent turn through configured /v1 provider; raw output kept under tmp/openclaw-smoke only\n'
    printf '[command-shape] %s\n' "$command_shape"
    printf '[sentinel] %s\n' "$sentinel"
    printf '[exit] %s\n' "$rc"
    printf '[failure-class] %s\n' "$([[ "$result" == "ok" ]] && printf none || printf '%s' "$result")"
    printf '[metadata] %s\n' "$AGENT_METADATA_FILE"
    printf '[stdout-log] %s\n' "$stdout_file"
    printf '[stderr-log] %s\n' "$stderr_file"
    printf '[status] %s\n' "$([[ "$result" == "ok" ]] && printf agent-ok || printf failed)"
  } > "$stage_log"

  if [[ "$result" != "ok" ]]; then
    fail "$result" "OpenClaw agent --local failed with class '$result'; see $AGENT_METADATA_FILE"
  fi

  COMPLETED_STAGES+=(agent)
  log_info "agent metadata written to $AGENT_METADATA_FILE"
}

write_image_fixture() {
  local output_path="$1"

  /usr/bin/python3 - "$output_path" <<'IMAGE_FIXTURE_PY'
import pathlib
import struct
import sys
import zlib


def chunk(kind, payload):
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


width = 64
height = 64
scanlines = []
for _row in range(height):
    scanlines.append(b"\x00" + (b"\xff\x00\x00" * width))

png = b"".join(
    [
        b"\x89PNG\r\n\x1a\n",
        chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)),
        chunk(b"IDAT", zlib.compress(b"".join(scanlines), 9)),
        chunk(b"IEND", b""),
    ]
)
pathlib.Path(sys.argv[1]).write_bytes(png)
IMAGE_FIXTURE_PY
}

write_image_metadata() {
  local stdout_file="$1"
  local stderr_file="$2"
  local rc="$3"
  local expected="$4"
  local command_shape="$5"
  local image_path="$6"
  local help_file="$7"
  /usr/bin/python3 - "$IMAGE_METADATA_FILE" "$stdout_file" "$stderr_file" "$RUN_ID" "$expected" "$OPENCLAW_SMOKE_PROVIDER_ID" "$SMOKE_TEXT_MODEL" "${OPENCLAW_SMOKE_BASE_URL%/}" "$rc" "$command_shape" "$image_path" "$help_file" "$OPENCLAW_VERSION" <<'IMAGE_META_PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    output,
    stdout_file,
    stderr_file,
    run_id,
    expected,
    provider_id,
    model_id,
    base_url,
    exit_status,
    command_shape,
    image_file,
    help_file,
    openclaw_version,
) = sys.argv[1:14]

exit_status_int = int(exit_status)
stdout_path = Path(stdout_file)
stderr_path = Path(stderr_file)
image_path = Path(image_file)
help_path = Path(help_file)
stdout_text = stdout_path.read_text(errors="replace") if stdout_path.exists() else ""
stderr_text = stderr_path.read_text(errors="replace") if stderr_path.exists() else ""
combined = f"{stdout_text}\n{stderr_text}"
combined_lower = combined.lower()
parsed_text = None
parsed_field_path = None
parse_error = None
payload = None
help_text = help_path.read_text(errors="replace") if help_path.exists() else ""
cli_supports_file = "--file" in help_text


def normalize(value):
    return value.replace("\r", "").rstrip("\n").strip().lower()


def sha256_text(value):
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def sha256_file(path):
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def load_json_candidate(raw):
    stripped = raw.strip()
    if not stripped:
        raise ValueError("empty stdout")
    try:
        return json.loads(stripped)
    except Exception:
        for line in reversed([candidate.strip() for candidate in raw.splitlines() if candidate.strip()]):
            if line.startswith("{") and line.endswith("}"):
                return json.loads(line)
        raise


def extract_text(value):
    result = value.get("result") if isinstance(value, dict) else None
    payloads = result.get("payloads") if isinstance(result, dict) else None
    if isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"result.payloads[{index}].text"
    payloads = value.get("payloads") if isinstance(value, dict) else None
    if isinstance(payloads, list):
        for index, item in enumerate(payloads):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"payloads[{index}].text"
    outputs = value.get("outputs") if isinstance(value, dict) else None
    if isinstance(outputs, list):
        for index, item in enumerate(outputs):
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                return item["text"], f"outputs[{index}].text"
    summary = value.get("summary") if isinstance(value, dict) else None
    if isinstance(summary, str):
        return summary, "summary"
    return None, None

try:
    payload = load_json_candidate(stdout_text)
    parsed_text, parsed_field_path = extract_text(payload)
    if parsed_text is None:
        parse_error = "missing result.payloads[].text, payloads[].text, outputs[].text, or summary"
except Exception as error:
    if stdout_text.strip() or exit_status_int == 0:
        parse_error = error.__class__.__name__

failure_class = None
status = "succeeded"
if not cli_supports_file:
    failure_class = "image_unsupported_by_openclaw_cli"
elif exit_status_int != 0:
    if exit_status_int in (124, 137, 142, 143) or "timed out" in combined_lower or "command timed out" in combined_lower:
        failure_class = "timeout"
    elif re.search(r"\b(401|403|unauthorized|forbidden|auth|api key|bearer)\b", combined_lower):
        failure_class = "auth"
    elif re.search(r"(unknown|unrecognized|unsupported).{0,40}(--file|file|image|vision)", combined_lower):
        failure_class = "image_unsupported_by_openclaw_cli"
    else:
        failure_class = "image_runtime_failed"
elif parse_error is not None:
    failure_class = "response_parse"
elif normalize(parsed_text or "") != expected:
    failure_class = "sentinel_mismatch"

if failure_class is not None:
    status = "failed"

metadata = {
    "run_id": run_id,
    "stage": "image",
    "status": status,
    "failure_class": failure_class,
    "command": {
        "shape": command_shape,
        "surface": "infer model run --file",
        "json": True,
        "model": f"{provider_id}/{model_id}",
    },
    "provider": {
        "base_url": base_url,
        "id": provider_id,
        "selected_model": model_id,
    },
    "expected": expected,
    "openclaw": {
        "version": openclaw_version,
        "infer_model_run_file_option": cli_supports_file,
        "help_bytes": help_path.stat().st_size if help_path.exists() else 0,
        "help_sha256": sha256_file(help_path),
    },
    "fixture": {
        "format": "png",
        "dominant_color": "red",
        "bytes": image_path.stat().st_size if image_path.exists() else 0,
        "sha256": sha256_file(image_path),
        "stored_under_ignored_tmp": True,
    },
    "parse": {
        "field_path": parsed_field_path,
        "parse_error": parse_error,
        "exact_match": failure_class is None,
        "parsed_text_bytes": len((parsed_text or "").encode("utf-8", errors="replace")) if parsed_text is not None else 0,
        "parsed_text_sha256": sha256_text(parsed_text) if parsed_text is not None else None,
    },
    "process": {
        "exit_status": exit_status_int,
        "stdout_bytes": stdout_path.stat().st_size if stdout_path.exists() else 0,
        "stdout_sha256": sha256_file(stdout_path),
        "stderr_bytes": stderr_path.stat().st_size if stderr_path.exists() else 0,
        "stderr_sha256": sha256_file(stderr_path),
    },
    "logs": {
        "stdout_json": stdout_file,
        "stderr_log": stderr_file,
        "help_log": help_file,
    },
    "redaction": {
        "metadata_only": True,
        "raw_pool_api_key_recorded": False,
        "raw_prompt_recorded": False,
        "raw_image_bytes_recorded_in_metadata": False,
        "raw_request_body_recorded_in_metadata": False,
        "raw_response_body_recorded_in_metadata": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
print(failure_class or "ok")
IMAGE_META_PY
}

run_image_stage() {
  local stage_log="$RUN_DIR/stages/image.log"
  local stdout_file="$RUN_DIR/openclaw-image.stdout.json"
  local stderr_file="$RUN_DIR/openclaw-image.stderr.log"
  local help_file="$RUN_DIR/openclaw-infer-model-run-help.log"
  local image_path="$WORKSPACE_DIR/openclaw-image-red-$RUN_ID.png"
  local expected prompt rc result command_shape openclaw_bin_dir help_rc
  expected="red"
  prompt="Look at the attached image. Output exactly one lowercase word naming its dominant color."
  rc=0
  help_rc=0
  command_shape="timeout_exec openclaw infer model run --local --json --model $OPENCLAW_SMOKE_PROVIDER_ID/$OPENCLAW_SMOKE_MODEL --file <generated-red-png> --prompt <vision-dominant-color-red>"
  openclaw_bin_dir="$(dirname "$OPENCLAW_PATH")"

  if [[ "$DRY_RUN" == "true" ]]; then
    {
      printf '[stage] image\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[mode] dry-run; prerequisites, fixture generation, and OpenClaw execution skipped\n'
      printf '[command-shape] %s\n' "$command_shape"
      printf '[expected] %s\n' "$expected"
      printf '[status] dry-run-only\n'
    } > "$stage_log"
    COMPLETED_STAGES+=(image)
    log_info "image dry-run metadata written to $stage_log"
    return 0
  fi

  run_provider_stage
  record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" openclaw infer model run --help
  env \
    PATH="$openclaw_bin_dir:$PATH" \
    HOME="$ROOT_DIR/$HOME_DIR" \
    XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
    XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
    XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
    OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
    OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
    "$OPENCLAW_PATH" infer model run --help >"$help_file" 2>&1 || help_rc=$?
  if [[ "$help_rc" -ne 0 ]]; then
    rc="$help_rc"
    : > "$stdout_file"
    printf 'openclaw infer model run --help failed with exit %s\n' "$help_rc" > "$stderr_file"
    result="$(write_image_metadata "$stdout_file" "$stderr_file" "$help_rc" "$expected" "$command_shape" "$image_path" "$help_file")"
  elif ! grep -F -- '--file' "$help_file" >/dev/null 2>&1; then
    : > "$stdout_file"
    : > "$stderr_file"
    result="$(write_image_metadata "$stdout_file" "$stderr_file" 0 "$expected" "$command_shape" "$image_path" "$help_file")"
  else
    write_image_fixture "$image_path"
    record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" OPENAI_API_KEY="<redacted>" openclaw infer model run --local --json --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" --file "<generated-red-png>" --prompt "<vision-dominant-color-red>"

    log_info "running OpenClaw image smoke with isolated OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
    timeout_exec env \
      PATH="$openclaw_bin_dir:$PATH" \
      HOME="$ROOT_DIR/$HOME_DIR" \
      XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
      XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
      XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
      OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
      OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
      OPENAI_BASE_URL="${OPENCLAW_SMOKE_BASE_URL%/}" \
      OPENAI_API_KEY="$EFFECTIVE_API_KEY" \
      "$OPENCLAW_PATH" infer model run \
        --local \
        --json \
        --model "$OPENCLAW_SMOKE_PROVIDER_ID/$SMOKE_TEXT_MODEL" \
        --file "$image_path" \
        --prompt "$prompt" \
        >"$stdout_file" 2>"$stderr_file" || rc=$?

    result="$(write_image_metadata "$stdout_file" "$stderr_file" "$rc" "$expected" "$command_shape" "$image_path" "$help_file")"
  fi

  {
    printf '[stage] image\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real OpenClaw local image turn through configured /v1 provider; raw output kept under tmp/openclaw-smoke only\n'
    printf '[command-shape] %s\n' "$command_shape"
    printf '[expected] %s\n' "$expected"
    if [[ -f "$image_path" ]]; then
      printf '[fixture-format] png\n'
      printf '[fixture-dominant-color] red\n'
      printf '[fixture-bytes] %s\n' "$(wc -c < "$image_path" | tr -d ' ')"
      printf '[fixture-sha256] %s\n' "$(shasum -a 256 "$image_path" | awk '{print $1}')"
    fi
    printf '[exit] %s\n' "$rc"
    printf '[failure-class] %s\n' "$([[ "$result" == "ok" ]] && printf none || printf '%s' "$result")"
    printf '[metadata] %s\n' "$IMAGE_METADATA_FILE"
    printf '[stdout-log] %s\n' "$stdout_file"
    printf '[stderr-log] %s\n' "$stderr_file"
    printf '[help-log] %s\n' "$help_file"
    printf '[status] %s\n' "$([[ "$result" == "ok" ]] && printf image-ok || printf failed)"
  } > "$stage_log"

  if [[ "$result" != "ok" ]]; then
    fail "$result" "OpenClaw image smoke failed with class '$result'; see $IMAGE_METADATA_FILE"
  fi

  COMPLETED_STAGES+=(image)
  log_info "image metadata written to $IMAGE_METADATA_FILE"
}



require_psql() {
  command -v psql >/dev/null 2>&1 || fail missing_prerequisite "psql is required for OpenClaw DB evidence"
}

sql_literal() {
  /usr/bin/python3 - "$1" <<'SQL_LITERAL_PY'
import sys

value = sys.argv[1]
print("'" + value.replace("'", "''") + "'")
SQL_LITERAL_PY
}

redacted_db_url() {
  /usr/bin/python3 - "$OPENCLAW_SMOKE_DB_URL" <<'REDACT_DB_URL_PY'
import re
import sys

url = sys.argv[1]
print(re.sub(r'//([^:/@]+)(?::[^@]*)?@', r'//\1:[redacted]@', url))
REDACT_DB_URL_PY
}

psql_scalar() {
  local query="$1"
  psql "$OPENCLAW_SMOKE_DB_URL" -v ON_ERROR_STOP=1 -At -c "$query"
}

openclaw_response_where_clause() {
  local model_literal start_literal
  model_literal="$(sql_literal "$SMOKE_TEXT_MODEL")"
  start_literal="$(sql_literal "$(read_smoke_started_at)")"
  cat <<SQL
endpoint = '/backend-api/codex/responses'
and request_metadata #>> '{openai_compatibility,source_endpoint}' = '/v1/responses'
and requested_model = $model_literal
and admitted_at >= $start_literal
SQL
}

expected_openclaw_response_count() {
  /usr/bin/python3 - "$ONESHOT_METADATA_FILE" "$AGENT_METADATA_FILE" "$IMAGE_METADATA_FILE" <<'EXPECTED_RESPONSES_PY'
import json
import sys
from pathlib import Path

count = 0
for path_value in sys.argv[1:]:
    path = Path(path_value)
    if not path.exists():
        continue
    try:
        payload = json.loads(path.read_text())
    except Exception:
        continue
    if payload.get("status") == "succeeded":
        count += 1
print(count)
EXPECTED_RESPONSES_PY
}

append_openclaw_db_snapshot() {
  local evidence_log="$1"
  local expected_count="$2"
  local succeeded_count="$3"
  local bad_count="$4"

  {
    printf '[db-url] configured=%s\n' "$(redacted_db_url)"
    printf '[window-start] %s\n' "$(read_smoke_started_at)"
    printf '[attribution] endpoint=/backend-api/codex/responses source_endpoint=/v1/responses requested_model=%s\n' "$SMOKE_TEXT_MODEL"
    printf '[expected-succeeded] %s\n' "$expected_count"
    printf '[observed-succeeded] %s\n' "$succeeded_count"
    printf '[observed-bad] %s\n' "$bad_count"
    printf '\n[response-summary]\n'
    psql "$OPENCLAW_SMOKE_DB_URL" -v ON_ERROR_STOP=1 -c \
      "select endpoint, transport, status, response_status_code, requested_model, request_metadata #>> '{openai_compatibility,source_endpoint}' as source_endpoint, request_metadata #>> '{openai_compatibility,translated_endpoint}' as translated_endpoint, count(*) from requests where $(openclaw_response_where_clause) group by endpoint, transport, status, response_status_code, requested_model, source_endpoint, translated_endpoint order by endpoint, transport, status, response_status_code, requested_model, source_endpoint, translated_endpoint;"
    printf '\n[unexpected-rows]\n'
    psql "$OPENCLAW_SMOKE_DB_URL" -v ON_ERROR_STOP=1 -c \
      "select endpoint, transport, status, response_status_code, requested_model, coalesce(last_error_code, '') as last_error_code, admitted_at from requests where $(openclaw_response_where_clause) and (status = 'failed' or response_status_code is null or response_status_code < 200 or response_status_code >= 300) order by admitted_at;"
  } >> "$evidence_log"
}

write_evidence_metadata() {
  local status="$1"
  local failure_class="$2"
  local expected_count="$3"
  local succeeded_count="$4"
  local bad_count="$5"
  /usr/bin/python3 - "$EVIDENCE_METADATA_FILE" "$RUN_ID" "$(read_smoke_started_at)" "$status" "$failure_class" "$expected_count" "$succeeded_count" "$bad_count" "$SMOKE_TEXT_MODEL" "${OPENCLAW_SMOKE_BASE_URL%/}" <<'EVIDENCE_META_PY'
import json
import sys
from pathlib import Path

(output, run_id, started_at, status, failure_class, expected_count, succeeded_count, bad_count, model, base_url) = sys.argv[1:11]
metadata = {
    "run_id": run_id,
    "stage": "evidence",
    "status": status,
    "failure_class": failure_class or None,
    "filters": {
        "admitted_at_gte": started_at,
        "endpoint": "/backend-api/codex/responses",
        "source_endpoint": "/v1/responses",
        "requested_model": model,
        "base_url": base_url,
    },
    "counts": {
        "expected_succeeded": int(expected_count),
        "observed_succeeded": int(succeeded_count),
        "observed_bad": int(bad_count),
    },
    "redaction": {
        "metadata_only": True,
        "raw_prompts_recorded": False,
        "raw_response_bodies_recorded": False,
        "raw_stdout_stderr_copied": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
EVIDENCE_META_PY
}

run_evidence_stage() {
  local stage_log="$RUN_DIR/stages/evidence.log"
  local evidence_log="$RUN_DIR/db-evidence.log"
  local expected_count succeeded_count bad_count deadline now

  if [[ "$DRY_RUN" == "true" ]]; then
    write_stage_log evidence
    return 0
  fi

  if [[ -z "$SMOKE_TEXT_MODEL" ]]; then
    SMOKE_TEXT_MODEL="$(read_smoke_model)"
  fi

  if [[ "${OPENCLAW_SMOKE_EVIDENCE_FIXTURE:-}" == "unexpected_failed_row" ]]; then
    expected_count=1
    succeeded_count=1
    bad_count=1
    {
      printf '[stage] evidence\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[fixture] unexpected_failed_row\n'
      printf '[synthetic-row] endpoint=/backend-api/codex/responses source_endpoint=/v1/responses status=failed response_status_code=500\n'
      printf '[status] failed\n'
      printf '[failure-class] failed_row\n'
    } > "$stage_log"
    write_evidence_metadata failed failed_row "$expected_count" "$succeeded_count" "$bad_count"
    fail failed_row "failed_row: OpenClaw evidence fixture injected an unexpected failed row"
  fi

  require_psql
  if [[ -z "$SMOKE_TEXT_MODEL" ]]; then
    SMOKE_TEXT_MODEL="$(read_smoke_model)"
  fi
  [[ -n "$SMOKE_TEXT_MODEL" ]] || fail missing_metadata "OpenClaw evidence could not resolve the smoke model for run id $RUN_ID"
  expected_count="$(expected_openclaw_response_count)"
  if [[ "$expected_count" -lt 1 ]]; then
    expected_count=1
  fi
  deadline=$(( $(date +%s) + OPENCLAW_SMOKE_DB_RETRY_SECONDS ))
  : > "$evidence_log"

  while true; do
    succeeded_count="$(psql_scalar "select count(*) from requests where $(openclaw_response_where_clause) and status = 'succeeded' and response_status_code = 200;")"
    bad_count="$(psql_scalar "select count(*) from requests where $(openclaw_response_where_clause) and (status = 'failed' or response_status_code is null or response_status_code < 200 or response_status_code >= 300);")"

    if [[ "$bad_count" != "0" ]]; then
      append_openclaw_db_snapshot "$evidence_log" "$expected_count" "$succeeded_count" "$bad_count"
      write_evidence_metadata failed failed_row "$expected_count" "$succeeded_count" "$bad_count"
      {
        printf '[stage] evidence\n'
        printf '[run-id] %s\n' "$RUN_ID"
        printf '[metadata] %s\n' "$EVIDENCE_METADATA_FILE"
        printf '[db-evidence] %s\n' "$evidence_log"
        printf '[status] failed\n'
        printf '[failure-class] failed_row\n'
      } > "$stage_log"
      fail failed_row "OpenClaw evidence found failed or non-2xx /v1 response rows; see $evidence_log"
    fi

    if [[ "$succeeded_count" -ge "$expected_count" ]]; then
      append_openclaw_db_snapshot "$evidence_log" "$expected_count" "$succeeded_count" "$bad_count"
      write_evidence_metadata succeeded "" "$expected_count" "$succeeded_count" "$bad_count"
      {
        printf '[stage] evidence\n'
        printf '[run-id] %s\n' "$RUN_ID"
        printf '[mode] real DB evidence; metadata-only /v1 Responses rows\n'
        printf '[window-start] %s\n' "$(read_smoke_started_at)"
        printf '[attribution] endpoint=/backend-api/codex/responses source_endpoint=/v1/responses requested_model=%s\n' "$SMOKE_TEXT_MODEL"
        printf '[expected-succeeded] %s\n' "$expected_count"
        printf '[observed-succeeded] %s\n' "$succeeded_count"
        printf '[observed-bad] %s\n' "$bad_count"
        printf '[metadata] %s\n' "$EVIDENCE_METADATA_FILE"
        printf '[db-evidence] %s\n' "$evidence_log"
        printf '[status] evidence-ok\n'
      } > "$stage_log"
      COMPLETED_STAGES+=(evidence)
      log_info "evidence metadata written to $EVIDENCE_METADATA_FILE"
      return 0
    fi

    now=$(date +%s)
    if [[ "$now" -ge "$deadline" ]]; then
      append_openclaw_db_snapshot "$evidence_log" "$expected_count" "$succeeded_count" "$bad_count"
      write_evidence_metadata failed missing_row "$expected_count" "$succeeded_count" "$bad_count"
      {
        printf '[stage] evidence\n'
        printf '[run-id] %s\n' "$RUN_ID"
        printf '[metadata] %s\n' "$EVIDENCE_METADATA_FILE"
        printf '[db-evidence] %s\n' "$evidence_log"
        printf '[status] failed\n'
        printf '[failure-class] missing_row\n'
      } > "$stage_log"
      fail missing_row "OpenClaw evidence timed out waiting for $expected_count successful /v1 response rows; saw $succeeded_count; see $evidence_log"
    fi

    sleep 1
  done
}

openclaw_mcp_endpoint() {
  if [[ -n "$OPENCLAW_SMOKE_MCP_URL" ]]; then
    printf '%s\n' "${OPENCLAW_SMOKE_MCP_URL%/}"
    return 0
  fi

  local base="${OPENCLAW_SMOKE_BASE_URL%/}"
  case "$base" in
    */v1)
      printf '%s/mcp\n' "${base%/v1}"
      ;;
    */backend-api/codex)
      printf '%s/mcp\n' "${base%/backend-api/codex}"
      ;;
    */mcp)
      printf '%s\n' "$base"
      ;;
    *)
      printf '%s/mcp\n' "$base"
      ;;
  esac
}

require_mcp_token() {
  if [[ -n "$EFFECTIVE_MCP_KEY" ]]; then
    return 0
  fi

  if [[ -n "${OPENCLAW_SMOKE_MCP_KEY:-}" ]]; then
    EFFECTIVE_MCP_KEY="$OPENCLAW_SMOKE_MCP_KEY"
    EFFECTIVE_MCP_KEY_SOURCE="OPENCLAW_SMOKE_MCP_KEY"
  elif [[ -n "${CODEX_POOLER_MCP_KEY:-}" ]]; then
    EFFECTIVE_MCP_KEY="$CODEX_POOLER_MCP_KEY"
    EFFECTIVE_MCP_KEY_SOURCE="CODEX_POOLER_MCP_KEY"
  else
    prepare_disposable_mcp_token
  fi

  [[ -n "$EFFECTIVE_MCP_KEY" ]] || fail missing_env "CODEX_POOLER_MCP_KEY is required for real OpenClaw MCP stage unless OPENCLAW_SMOKE_MCP_KEY or disposable bootstrap is available"
}

prepare_disposable_mcp_token() {
  local token_path="$ROOT_DIR/$MCP_TOKEN_FILE"
  local -a setup_env
  setup_env=("MCP_SMOKE_TOKEN_FILE=$token_path")
  [[ -n "$ORIGINAL_HOME" ]] && setup_env+=("HOME=$ORIGINAL_HOME")
  [[ -n "$ORIGINAL_XDG_CONFIG_HOME" ]] && setup_env+=("XDG_CONFIG_HOME=$ORIGINAL_XDG_CONFIG_HOME")
  [[ -n "$ORIGINAL_XDG_CACHE_HOME" ]] && setup_env+=("XDG_CACHE_HOME=$ORIGINAL_XDG_CACHE_HOME")
  [[ -n "$ORIGINAL_XDG_DATA_HOME" ]] && setup_env+=("XDG_DATA_HOME=$ORIGINAL_XDG_DATA_HOME")

  log_info "CODEX_POOLER_MCP_KEY missing; preparing disposable MCP token at $MCP_TOKEN_FILE"
  record_command env MCP_SMOKE_TOKEN_FILE="$MCP_TOKEN_FILE" mix run scripts/dev/ensure-mcp-smoke-setup.exs
  env "${setup_env[@]}" mix run scripts/dev/ensure-mcp-smoke-setup.exs >/dev/null
  [[ -s "$token_path" ]] || fail mcp_auth "disposable MCP token file was not created"

  local mode
  mode="$(stat -f '%Lp' "$token_path" 2>/dev/null || stat -c '%a' "$token_path")"
  [[ "$mode" == "600" ]] || fail mcp_auth "disposable MCP token file must have 0600 permissions, got $mode"

  EFFECTIVE_MCP_KEY="$(tr -d '\n' < "$token_path")"
  EFFECTIVE_MCP_KEY_SOURCE="disposable_token_file"
}

write_openclaw_mcp_config() {
  local endpoint="$1"
  CODEX_POOLER_MCP_KEY="$EFFECTIVE_MCP_KEY" /usr/bin/python3 - "$CONFIG_PATH" "$OPENCLAW_SMOKE_MCP_SERVER_NAME" "$endpoint" "$OPENCLAW_SMOKE_MCP_EXPECTED_TOOL" <<'MCP_CONFIG_PY'
import json
import os
import sys
from pathlib import Path

output, server_name, endpoint, expected_tool = sys.argv[1:5]
token = os.environ["CODEX_POOLER_MCP_KEY"]
config = {
    "mcp": {
        "servers": {
            server_name: {
                "url": endpoint.rstrip("/"),
                "transport": "streamable-http",
                "headers": {"Authorization": f"Bearer {token}"},
                "timeout": 30,
                "connectTimeout": 15,
                "include": [expected_tool],
            }
        }
    }
}
Path(output).write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
Path(output).chmod(0o600)
MCP_CONFIG_PY
}

write_mcp_metadata() {
  local status_stdout="$1"
  local status_stderr="$2"
  local probe_stdout="$3"
  local probe_stderr="$4"
  local status_rc="$5"
  local probe_rc="$6"
  local endpoint="$7"
  local command_shape="$8"
  /usr/bin/python3 - "$MCP_METADATA_FILE" "$status_stdout" "$status_stderr" "$probe_stdout" "$probe_stderr" "$RUN_ID" "$OPENCLAW_SMOKE_MCP_SERVER_NAME" "$OPENCLAW_SMOKE_MCP_EXPECTED_TOOL" "$endpoint" "$EFFECTIVE_MCP_KEY_SOURCE" "$status_rc" "$probe_rc" "$command_shape" "$OPENCLAW_VERSION" <<'MCP_META_PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    output,
    status_stdout,
    status_stderr,
    probe_stdout,
    probe_stderr,
    run_id,
    server_name,
    expected_tool,
    endpoint,
    credential_source,
    status_exit,
    probe_exit,
    command_shape,
    openclaw_version,
) = sys.argv[1:15]

status_stdout_path = Path(status_stdout)
status_stderr_path = Path(status_stderr)
probe_stdout_path = Path(probe_stdout)
probe_stderr_path = Path(probe_stderr)
status_text = status_stdout_path.read_text(errors="replace") if status_stdout_path.exists() else ""
probe_text = probe_stdout_path.read_text(errors="replace") if probe_stdout_path.exists() else ""
probe_error_text = probe_stderr_path.read_text(errors="replace") if probe_stderr_path.exists() else ""
combined_lower = f"{probe_text}\n{probe_error_text}".lower()
status_payload = None
probe_payload = None
parse_error = None


def sha256_file(path):
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def load_json(raw):
    stripped = raw.strip()
    if not stripped:
        raise ValueError("empty JSON output")
    return json.loads(stripped)

try:
    if status_text.strip():
        status_payload = load_json(status_text)
except Exception as error:
    parse_error = f"status:{error.__class__.__name__}"

try:
    probe_payload = load_json(probe_text)
except Exception as error:
    parse_error = parse_error or f"probe:{error.__class__.__name__}"
    probe_payload = {}

servers = probe_payload.get("servers") if isinstance(probe_payload, dict) else {}
tools = probe_payload.get("tools") if isinstance(probe_payload, dict) else []
diagnostics = probe_payload.get("diagnostics") if isinstance(probe_payload, dict) else []
server_payload = servers.get(server_name) if isinstance(servers, dict) else None
expected_openclaw_tool = f"{server_name}__{expected_tool}"
expected_tool_visible = expected_tool in tools or expected_openclaw_tool in tools
failure_class = None

status_exit_int = int(status_exit)
probe_exit_int = int(probe_exit)
if (
    status_exit_int in (124, 137, 142, 143)
    or probe_exit_int in (124, 137, 142, 143)
    or "timed out" in combined_lower
    or "command timed out" in combined_lower
):
    failure_class = "timeout"
elif re.search(r"\b(401|403|unauthorized|forbidden|auth|bearer|api key)\b", combined_lower):
    failure_class = "mcp_auth"
elif parse_error:
    failure_class = "mcp_response_parse"
elif probe_exit_int != 0:
    failure_class = "mcp_probe_failed"
elif not isinstance(server_payload, dict):
    failure_class = "mcp_probe_failed"
elif not expected_tool_visible:
    failure_class = "mcp_catalog_missing_tool"

metadata = {
    "run_id": run_id,
    "stage": "mcp",
    "status": "failed" if failure_class else "succeeded",
    "failure_class": failure_class,
    "proof_level": "openclaw_mcp_probe_catalog" if not failure_class else None,
    "limitation": "OpenClaw 2026.6.1 does not expose a direct `openclaw mcp call <tool>` CLI; this stage proves the strongest OpenClaw-native MCP operation available: probe/catalog connectivity and expected safe tool visibility.",
    "direct_tool_call_cli_available": False,
    "server": {
        "name": server_name,
        "url": endpoint.rstrip("/"),
        "transport": "streamable-http",
        "expected_tool": expected_tool,
        "expected_openclaw_tool": expected_openclaw_tool,
        "expected_tool_visible": expected_tool_visible,
        "tool_count": len(tools) if isinstance(tools, list) else 0,
        "diagnostics_count": len(diagnostics) if isinstance(diagnostics, list) else 0,
    },
    "command": {
        "status_shape": "openclaw mcp status --json --verbose",
        "probe_shape": command_shape,
        "surface": "openclaw mcp probe --json",
    },
    "process": {
        "status_exit": status_exit_int,
        "probe_exit": probe_exit_int,
        "status_stdout_bytes": status_stdout_path.stat().st_size if status_stdout_path.exists() else 0,
        "status_stdout_sha256": sha256_file(status_stdout_path),
        "status_stderr_bytes": status_stderr_path.stat().st_size if status_stderr_path.exists() else 0,
        "status_stderr_sha256": sha256_file(status_stderr_path),
        "probe_stdout_bytes": probe_stdout_path.stat().st_size if probe_stdout_path.exists() else 0,
        "probe_stdout_sha256": sha256_file(probe_stdout_path),
        "probe_stderr_bytes": probe_stderr_path.stat().st_size if probe_stderr_path.exists() else 0,
        "probe_stderr_sha256": sha256_file(probe_stderr_path),
    },
    "openclaw": {"version": openclaw_version},
    "credential_source": credential_source,
    "logs": {
        "status_stdout": status_stdout,
        "status_stderr": status_stderr,
        "probe_stdout": probe_stdout,
        "probe_stderr": probe_stderr,
    },
    "redaction": {
        "metadata_only": True,
        "raw_mcp_token_recorded": False,
        "raw_pool_api_key_recorded": False,
        "raw_mcp_stdout_stderr_copied": False,
        "raw_response_body_recorded_in_metadata": False,
    },
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
print(failure_class or "ok")
MCP_META_PY
}

run_mcp_stage() {
  local stage_log="$RUN_DIR/stages/mcp.log"
  local status_stdout="$RUN_DIR/openclaw-mcp-status.stdout.json"
  local status_stderr="$RUN_DIR/openclaw-mcp-status.stderr.log"
  local probe_stdout="$RUN_DIR/openclaw-mcp-probe.stdout.json"
  local probe_stderr="$RUN_DIR/openclaw-mcp-probe.stderr.log"
  local endpoint status_rc probe_rc result command_shape openclaw_bin_dir
  endpoint="$(openclaw_mcp_endpoint)"
  status_rc=0
  probe_rc=0
  command_shape="timeout_exec openclaw mcp probe $OPENCLAW_SMOKE_MCP_SERVER_NAME --json"
  openclaw_bin_dir="$(dirname "$OPENCLAW_PATH")"

  if [[ "$DRY_RUN" == "true" ]]; then
    {
      printf '[stage] mcp\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[mode] dry-run; MCP token resolution, OpenClaw MCP config, status, and probe skipped\n'
      printf '[mcp-url] %s\n' "$endpoint"
      printf '[server] %s\n' "$OPENCLAW_SMOKE_MCP_SERVER_NAME"
      printf '[expected-tool] %s\n' "$OPENCLAW_SMOKE_MCP_EXPECTED_TOOL"
      printf '[status] dry-run-only\n'
    } > "$stage_log"
    COMPLETED_STAGES+=(mcp)
    log_info "mcp dry-run metadata written to $stage_log"
    return 0
  fi

  require_mcp_token
  write_openclaw_mcp_config "$endpoint"
  record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" openclaw mcp status --json --verbose
  record_command env PATH="<openclaw-bin>:\$PATH" HOME="$ROOT_DIR/$HOME_DIR" OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" openclaw mcp probe "$OPENCLAW_SMOKE_MCP_SERVER_NAME" --json

  log_info "running OpenClaw MCP probe against $endpoint with isolated OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
  timeout_exec env \
    PATH="$openclaw_bin_dir:$PATH" \
    HOME="$ROOT_DIR/$HOME_DIR" \
    XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
    XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
    XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
    OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
    OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
    "$OPENCLAW_PATH" mcp status --json --verbose \
      >"$status_stdout" 2>"$status_stderr" || status_rc=$?

  timeout_exec env \
    PATH="$openclaw_bin_dir:$PATH" \
    HOME="$ROOT_DIR/$HOME_DIR" \
    XDG_CONFIG_HOME="$ROOT_DIR/$CONFIG_DIR" \
    XDG_CACHE_HOME="$ROOT_DIR/$CACHE_DIR" \
    XDG_DATA_HOME="$ROOT_DIR/$DATA_DIR" \
    OPENCLAW_STATE_DIR="$ROOT_DIR/$STATE_DIR" \
    OPENCLAW_CONFIG_PATH="$ROOT_DIR/$CONFIG_PATH" \
    "$OPENCLAW_PATH" mcp probe "$OPENCLAW_SMOKE_MCP_SERVER_NAME" --json \
      >"$probe_stdout" 2>"$probe_stderr" || probe_rc=$?

  result="$(write_mcp_metadata "$status_stdout" "$status_stderr" "$probe_stdout" "$probe_stderr" "$status_rc" "$probe_rc" "$endpoint" "$command_shape")"
  {
    printf '[stage] mcp\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] real OpenClaw-native MCP probe/catalog proof; raw stdout/stderr kept under tmp/openclaw-smoke only\n'
    printf '[mcp-url] %s\n' "$endpoint"
    printf '[server] %s\n' "$OPENCLAW_SMOKE_MCP_SERVER_NAME"
    printf '[expected-tool] %s\n' "$OPENCLAW_SMOKE_MCP_EXPECTED_TOOL"
    printf '[credential-source] %s\n' "$EFFECTIVE_MCP_KEY_SOURCE"
    printf '[direct-tool-call-cli] unavailable-in-openclaw-2026.6.1\n'
    printf '[proof-level] %s\n' "$([[ "$result" == "ok" ]] && printf openclaw_mcp_probe_catalog || printf none)"
    printf '[status-exit] %s\n' "$status_rc"
    printf '[probe-exit] %s\n' "$probe_rc"
    printf '[failure-class] %s\n' "$([[ "$result" == "ok" ]] && printf none || printf '%s' "$result")"
    printf '[metadata] %s\n' "$MCP_METADATA_FILE"
    printf '[status-stdout-log] %s\n' "$status_stdout"
    printf '[status-stderr-log] %s\n' "$status_stderr"
    printf '[probe-stdout-log] %s\n' "$probe_stdout"
    printf '[probe-stderr-log] %s\n' "$probe_stderr"
    printf '[status] %s\n' "$([[ "$result" == "ok" ]] && printf mcp-ok || printf failed)"
  } > "$stage_log"

  if [[ "$result" != "ok" ]]; then
    fail "$result" "OpenClaw MCP probe failed with class '$result'; see $MCP_METADATA_FILE"
  fi

  COMPLETED_STAGES+=(mcp)
  log_info "mcp metadata written to $MCP_METADATA_FILE"
}

redaction_scan_file_list() {
  /usr/bin/python3 - "$RUN_DIR" ".omo/evidence" <<'REDACTION_FILE_LIST_PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
evidence_dir = Path(sys.argv[2])
paths = []
if run_dir.exists():
    for path in run_dir.rglob("*"):
        if not path.is_file():
            continue
        if path.name.endswith((".stdout.json", ".stderr.log")):
            continue
        if path.name == "openclaw-install.log":
            continue
        paths.append(path)
if evidence_dir.exists():
    paths.extend(path for path in evidence_dir.glob("task-4-openclaw-evidence*.txt") if path.is_file())
    paths.extend(path for path in evidence_dir.glob("task-5-openclaw-mcp*.txt") if path.is_file())
    paths.extend(path for path in evidence_dir.glob("task-8-openclaw-image*.txt") if path.is_file())
for path in sorted(set(paths)):
    print(path)
REDACTION_FILE_LIST_PY
}

run_redact_stage() {
  local stage_log="$RUN_DIR/stages/redact.log"
  local fixture_file="$RUN_DIR/stages/redaction-fixture.log"

  if [[ "$DRY_RUN" == "true" ]]; then
    write_stage_log redact
    return 0
  fi

  if [[ "${OPENCLAW_SMOKE_REDACTION_FIXTURE:-}" == "leak" ]]; then
    printf 'Authorization: Bearer fixture-redaction-leak\n' > "$fixture_file"
  fi

  local api_key="${EFFECTIVE_API_KEY:-}"
  if [[ -z "$api_key" ]]; then
    if [[ -n "${OPENCLAW_SMOKE_API_KEY:-}" ]]; then
      api_key="$OPENCLAW_SMOKE_API_KEY"
    else
      api_key="${CODEX_POOLER_API_KEY:-}"
    fi
  fi

  local result file_list
  file_list="$RUN_DIR/redaction-files.txt"
  redaction_scan_file_list > "$file_list"
  if ! result="$(API_KEY_TO_SCAN="$api_key" MCP_KEY_TO_SCAN="${CODEX_POOLER_MCP_KEY:-}" /usr/bin/python3 - "$REDACTION_METADATA_FILE" "$RUN_ID" "$(openclaw_sentinel_for)" "$file_list" <<'REDACTION_SCAN_PY'
import json
import os
import re
import sys
from pathlib import Path

output, run_id, sentinel, file_list = sys.argv[1:5]
paths = [Path(line.strip()) for line in Path(file_list).read_text().splitlines() if line.strip()]
api_key = os.environ.get("API_KEY_TO_SCAN", "")
mcp_key = os.environ.get("MCP_KEY_TO_SCAN", "")
leaks = []

bearer_header_pattern = re.compile(r"authorization:\s*bearer\s+([^\s\"']+)", re.IGNORECASE)
allowed_bearer_values = {"<redacted>", "<operator-mcp-token>", "${CODEX_POOLER_MCP_KEY}"}
patterns = [
    ("auth_json", re.compile(r'"(?:access_token|refresh_token|id_token|auth_json)"\s*:', re.IGNORECASE)),
    ("raw_prompt", re.compile(r"(?:Output exactly this line and nothing else:|Reply with exactly this line and nothing else:)")),
    ("raw_response_body", re.compile(r'"(?:outputs|payloads|output_text|response)"\s*:', re.IGNORECASE)),
    ("raw_idempotency_key", re.compile(r'(?:idempotency-key|raw_idempotency_key)\s*[:=]\s*(?!\[REDACTED|<redacted>)[^\s,]+', re.IGNORECASE)),
]

for path in paths:
    try:
        text = path.read_text(errors="replace")
    except Exception:
        continue
    if api_key and api_key in text:
        leaks.append({"file": str(path), "kind": "pool_api_key"})
    if mcp_key and mcp_key in text:
        leaks.append({"file": str(path), "kind": "operator_mcp_token"})
    for match in bearer_header_pattern.finditer(text):
        if match.group(1) not in allowed_bearer_values and not match.group(1).startswith("[REDACTED"):
            leaks.append({"file": str(path), "kind": "bearer_header"})
    for kind, pattern in patterns:
        if pattern.search(text):
            leaks.append({"file": str(path), "kind": kind})

metadata = {
    "run_id": run_id,
    "stage": "redact",
    "status": "failed" if leaks else "succeeded",
    "failure_class": "redaction_leak" if leaks else None,
    "scanned_files": [str(path) for path in paths],
    "ignored_private_logs": ["*.stdout.json", "*.stderr.log", "openclaw-install.log"],
    "allowed_private_secret_path": "tmp/openclaw-smoke/home/<run-id>/.config/openclaw/openclaw.json",
    "allowed_sentinel": sentinel,
    "leak_count": len(leaks),
    "leaks": leaks[:20],
}
Path(output).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
if leaks:
    print("redaction_leak")
    sys.exit(1)
print("ok")
REDACTION_SCAN_PY
)"; then
    {
      printf '[stage] redact\n'
      printf '[run-id] %s\n' "$RUN_ID"
      printf '[metadata] %s\n' "$REDACTION_METADATA_FILE"
      printf '[status] failed\n'
      printf '[failure-class] %s\n' "$result"
    } > "$stage_log"
    fail "$result" "OpenClaw redaction scan failed with class '$result'; see $REDACTION_METADATA_FILE"
  fi

  {
    printf '[stage] redact\n'
    printf '[run-id] %s\n' "$RUN_ID"
    printf '[mode] exact secret and targeted unsafe-artifact scan; raw OpenClaw stdout/stderr ignored under tmp logs\n'
    printf '[metadata] %s\n' "$REDACTION_METADATA_FILE"
    printf '[status] redact-ok\n'
  } > "$stage_log"
  COMPLETED_STAGES+=(redact)
  log_info "redaction metadata written to $REDACTION_METADATA_FILE"
}

json_string_array() {
  /usr/bin/python3 - "$@" <<'JSON_ARRAY_PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
JSON_ARRAY_PY
}

write_stage_log() {
  local stage="$1"
  local log_file="$RUN_DIR/stages/$stage.log"
  {
    printf '[stage] %s\n' "$stage"
    printf '[run-id] %s\n' "$RUN_ID"
    if [[ "$DRY_RUN" == "true" ]]; then
      printf '[mode] dry-run; metadata-only; no Codex Pooler calls; no OpenClaw execution\n'
    else
      printf '[mode] metadata log for the complete OpenClaw validation runner\n'
    fi
    printf '[home] %s\n' "$HOME_DIR"
    printf '[config-path] %s\n' "$CONFIG_PATH"
    printf '[state-dir] %s\n' "$STATE_DIR"
    printf '[workspace] %s\n' "$WORKSPACE_DIR"
    case "$stage" in
      config)
        printf '[would-run] generate isolated OpenClaw provider config from CODEX_POOLER_API_KEY and OPENCLAW_SMOKE_MODEL\n'
        ;;
      provider)
        printf '[would-run] check local /v1/models readiness without printing Pool API keys\n'
        ;;
      oneshot)
        printf '[would-run] openclaw infer model run --local --json --model <provider/model> --prompt <sentinel>\n'
        ;;
      agent)
        printf '[would-run] openclaw agent --local --json --agent main --model <provider/model> --message <sentinel>\n'
        ;;
      image)
        printf '[would-run] openclaw infer model run --local --json --model <provider/model> --file <generated-red-png> --prompt <vision-assertion>\n'
        ;;
      evidence)
        printf '[would-run] query metadata-only request-log evidence for completed /v1 response rows\n'
        ;;
      mcp)
        printf '[would-run] configure isolated OpenClaw MCP and prove catalog/tool visibility through OpenClaw MCP CLI\n'
        ;;
      redact)
        printf '[would-run] scan generated metadata artifacts for raw secret/body leaks\n'
        ;;
    esac
    if [[ "$DRY_RUN" == "true" ]]; then
      printf '[status] dry-run-ok\n'
    else
      printf '[status] metadata-ok\n'
    fi
  } > "$log_file"
  COMPLETED_STAGES+=("$stage")
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "$stage dry-run metadata written to $log_file"
  else
    log_info "$stage metadata written to $log_file"
  fi
}

run_stage() {
  local stage="$1"
  case "$stage" in
    config)
      run_config_stage
      ;;
    provider)
      run_provider_stage
      ;;
    oneshot)
      run_oneshot_stage
      ;;
    agent)
      run_agent_stage
      ;;
    image)
      run_image_stage
      ;;
    evidence)
      run_evidence_stage
      ;;
    mcp)
      run_mcp_stage
      ;;
    redact)
      run_redact_stage
      ;;
    *)
      fail internal "unsupported stage dispatch '$stage'"
      ;;
  esac
}

write_summary() {
  [[ "$REUSE_EXISTING_RUN" == "true" ]] && return 0
  [[ -n "$SUMMARY_FILE" && -d "$RUN_DIR" ]] || return 0
  local selected_json completed_json dry_bool
  if [[ ${#STAGES[@]} -eq 0 ]]; then
    selected_json="[]"
  else
    selected_json="$(json_string_array "${STAGES[@]}")"
  fi
  if [[ ${#COMPLETED_STAGES[@]} -eq 0 ]]; then
    completed_json="[]"
  else
    completed_json="$(json_string_array "${COMPLETED_STAGES[@]}")"
  fi
  dry_bool=false
  [[ "$DRY_RUN" == "true" ]] && dry_bool=true
  /usr/bin/python3 - "$SUMMARY_FILE" "$RUN_ID" "$dry_bool" "$STATUS" "${FAILURE_CLASS:-}" "$selected_json" "$completed_json" "$HOME_DIR" "$CONFIG_PATH" "$STATE_DIR" "$CONFIG_DIR" "$CACHE_DIR" "$DATA_DIR" "$WORKSPACE_DIR" "$RUN_DIR" "${OPENCLAW_PATH:-}" "${OPENCLAW_VERSION:-}" "$OPENCLAW_INSTALL_ACTION" "$OPENCLAW_SMOKE_PROVIDER_ID" "${OPENCLAW_SMOKE_BASE_URL%/}" "${SMOKE_TEXT_MODEL:-}" "$CONFIG_METADATA_FILE" "$PROVIDER_METADATA_FILE" "$ONESHOT_METADATA_FILE" "$AGENT_METADATA_FILE" "$IMAGE_METADATA_FILE" "$EVIDENCE_METADATA_FILE" "$MCP_METADATA_FILE" "$REDACTION_METADATA_FILE" "$EFFECTIVE_API_KEY_SOURCE" "$(read_smoke_started_at)" "$REUSE_EXISTING_RUN" <<'SUMMARY_PY'
import json
import sys
from pathlib import Path
(
    output,
    run_id,
    dry_run,
    status,
    failure_class,
    selected,
    completed,
    home,
    config_path,
    state_dir,
    xdg_config,
    xdg_cache,
    xdg_data,
    workspace,
    log_dir,
    binary_path,
    version,
    install_action,
    provider_id,
    base_url,
    text_model,
    config_metadata_path,
    provider_metadata_path,
    oneshot_metadata_path,
    agent_metadata_path,
    image_metadata_path,
    evidence_metadata_path,
    mcp_metadata_path,
    redaction_metadata_path,
    credential_source,
    smoke_started_at,
    reuse_existing_run,
) = sys.argv[1:33]
summary = {
    "run_id": run_id,
    "dry_run": dry_run == "true",
    "selected_stages": json.loads(selected),
    "completed_stages": json.loads(completed),
    "status": status,
    "failure_class": failure_class or None,
    "smoke_started_at": smoke_started_at or None,
    "reuse_existing_run": reuse_existing_run == "true",
    "isolated_paths": {
        "home": home,
        "openclaw_config_path": config_path,
        "openclaw_state_dir": state_dir,
        "xdg_config_home": xdg_config,
        "xdg_cache_home": xdg_cache,
        "xdg_data_home": xdg_data,
        "workspace": workspace,
        "log_dir": log_dir,
    },
    "binary": {
        "path": binary_path or None,
        "version": version or None,
        "install_action": install_action,
        "official_source": "npm:openclaw",
    },
    "provider_config": {
        "provider_id": provider_id,
        "base_url": base_url,
        "selected_model": text_model or None,
        "credential_source": credential_source if text_model else None,
        "config_metadata_path": config_metadata_path,
        "provider_metadata_path": provider_metadata_path,
        "oneshot_metadata_path": oneshot_metadata_path,
        "agent_metadata_path": agent_metadata_path,
        "image_metadata_path": image_metadata_path,
        "evidence_metadata_path": evidence_metadata_path,
        "mcp_metadata_path": mcp_metadata_path,
        "redaction_metadata_path": redaction_metadata_path,
    },
    "safety": {
        "local_only": True,
        "dry_run_network_calls": False,
        "real_home_access": False,
        "metadata_only_evidence": True,
    },
}
Path(output).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
SUMMARY_PY
}

on_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 && "$STATUS" != "failed" ]]; then
    STATUS="failed"
    FAILURE_CLASS="unexpected_exit"
  fi
  write_summary || true
  exit "$rc"
}

main() {
  parse_args "$@"
  prepare_directories
  write_start_metadata
  trap on_exit EXIT
  ensure_openclaw
  export_isolation_env
  if [[ "$REUSE_EXISTING_RUN" != "true" ]]; then
    write_scaffold_config
  fi

  local stage_name
  for stage_name in "${STAGES[@]}"; do
    run_stage "$stage_name"
  done

  write_summary
  log_info "summary: $SUMMARY_FILE"
}

main "$@"
