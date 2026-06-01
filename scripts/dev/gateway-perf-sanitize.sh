#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <run-dir>\n' "$(basename "$0")" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

run_dir="$1"

if [ ! -d "$run_dir" ]; then
  printf 'gateway-perf-sanitize: run directory not found: %s\n' "$run_dir" >&2
  exit 2
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'gateway-perf-sanitize: rg is required\n' >&2
  exit 2
fi

pattern='SENTINEL_PROMPT_DO_NOT_LOG|dev-perf-metrics-[A-Za-z0-9_-]+|"(prompt|messages|authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?json|request[_-]?body|response[_-]?body|raw[_-]?request|raw[_-]?response|websocket[_-]?frame)"[[:space:]]*:|\b(Bearer|Authorization|Cookie|Set-Cookie)[[:space:]]*[:=]|\b(prompt|messages|request_body|response_body|raw_request|raw_response|websocket_frame)[[:space:]]*='

if rg --hidden --follow --line-number --color never \
  --glob '*.json' \
  --glob '*.csv' \
  --glob '*.txt' \
  --glob '*.md' \
  --glob '*.log' \
  --glob '!bootstrap/perf.env' \
  --glob '!perf.env' \
  -i -e "$pattern" "$run_dir"; then
  printf 'gateway-perf-sanitize: unsafe payload or secret marker found in generated artifacts\n' >&2
  exit 1
fi

printf 'gateway-perf-sanitize: ok\n'
