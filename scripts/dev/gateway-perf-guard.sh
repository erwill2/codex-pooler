#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PERF_ENV_PATH="${CODEX_POOLER_PERF_ENV:-tmp/gateway-perf/bootstrap/perf.env}"
PERF_POOL_SLUG="${CODEX_POOLER_PERF_POOL_SLUG:-dev-perf-pool}"

usage() {
  cat <<'EOF'
Usage: scripts/dev/gateway-perf-guard.sh --check

Validates gateway performance upstream targets before traffic starts. The guard
checks URL hosts from CODEX_POOLER_PERF_* environment variables and DB-backed
metadata for the dev perf Pool.

Allowed hosts:
  localhost, 127.0.0.1, ::1, *.svc, *.svc.cluster.local, CODEX_POOLER_PERF_ALLOW_HOSTS
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

load_perf_env() {
  if [[ -f "$PERF_ENV_PATH" ]]; then
    set -a
    source "$PERF_ENV_PATH"
    set +a
  fi

  PERF_POOL_SLUG="${CODEX_POOLER_PERF_POOL_SLUG:-$PERF_POOL_SLUG}"
}

env_targets() {
  local name value
  for name in \
    CODEX_POOLER_PERF_HTTP_URL \
    CODEX_POOLER_PERF_BASE_URL \
    CODEX_POOLER_PERF_UPSTREAM_BASE_URL \
    CODEX_POOLER_PERF_WEBSOCKET_URL \
    CODEX_POOLER_PERF_WS_URL
  do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      printf 'env:%s\t%s\n' "$name" "$value"
    fi
  done
}

db_targets() {
  MIX_ENV="${MIX_ENV:-dev}" CODEX_POOLER_PERF_POOL_SLUG="$PERF_POOL_SLUG" mix run -e '
import Ecto.Query

alias CodexPooler.Pools.Pool
alias CodexPooler.Repo
alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

pool_slug = System.fetch_env!("CODEX_POOLER_PERF_POOL_SLUG")
http_keys = ~w(base_url api_base_url upstream_base_url cluster_base_url usage_base_url codex_usage_base_url)
websocket_keys = ~w(websocket_url ws_url cluster_websocket_url)

rows =
  Repo.all(
    from assignment in PoolUpstreamAssignment,
      join: pool in Pool,
      on: pool.id == assignment.pool_id,
      join: identity in UpstreamIdentity,
      on: identity.id == assignment.upstream_identity_id,
      where: pool.slug == ^pool_slug and assignment.status != "deleted",
      select: {assignment.assignment_label, assignment.metadata, identity.metadata}
  )

for {label, assignment_metadata, identity_metadata} <- rows,
    {scope, metadata} <- [{"assignment", assignment_metadata || %{}}, {"identity", identity_metadata || %{}}],
    {kind, keys} <- [{"http", http_keys}, {"websocket", websocket_keys}],
    key <- keys,
    url = Map.get(metadata, key),
    is_binary(url) and String.trim(url) != "" do
  IO.puts(["db:", scope, ":", label, ":", kind, ":", key, "\t", url])
end
'
}

append_db_targets() {
  if [[ "${CODEX_POOLER_PERF_GUARD_DB:-1}" == "0" ]]; then
    return 0
  fi

  db_targets
}

validate_targets() {
  local target_file allowed_hosts
  target_file="$(mktemp)"
  trap 'rm -f "${target_file:-}"' RETURN

  env_targets > "$target_file"
  append_db_targets >> "$target_file"

  allowed_hosts="${CODEX_POOLER_PERF_ALLOW_HOSTS:-}"

  python3 - "$target_file" "$allowed_hosts" <<'PY'
import ipaddress
import sys
from pathlib import Path
from urllib.parse import urlparse

target_path = Path(sys.argv[1])
extra_hosts = {host.strip().lower() for host in sys.argv[2].split(",") if host.strip()}
allowed_fixed = {"localhost", "127.0.0.1", "::1"}
allowed_schemes = {"http", "https", "ws", "wss"}
violations = []
checked = 0

def allowed_host(host):
    normalized = host.strip("[]").lower()
    if normalized in allowed_fixed or normalized in extra_hosts:
        return True
    if normalized.endswith(".svc") or normalized.endswith(".svc.cluster.local"):
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False

for raw_line in target_path.read_text().splitlines():
    line = raw_line.strip()
    if not line or "\t" not in line:
        continue
    source, url = line.split("\t", 1)
    source = source.strip()
    if not (source.startswith("env:") or source.startswith("db:")):
        continue
    parsed = urlparse(url.strip())
    checked += 1
    if parsed.scheme not in allowed_schemes or not parsed.hostname:
        violations.append((source, "invalid-url", url))
        continue
    if not allowed_host(parsed.hostname):
        violations.append((source, parsed.hostname, url))

if violations:
    print(f"gateway perf guard failed: {len(violations)} unsafe target(s)", file=sys.stderr)
    for source, host, url in violations:
        print(f"unsafe target source={source} host={host} url={url}", file=sys.stderr)
    sys.exit(1)

print(f"gateway perf guard ok: checked {checked} target(s)")
PY
}

main() {
  case "${1:-}" in
    --check)
      load_perf_env
      validate_targets
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
