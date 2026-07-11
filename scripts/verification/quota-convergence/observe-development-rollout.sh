#!/usr/bin/env bash
set -euo pipefail

validate_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
validate_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

validate_observed_images() {
  local images="$1"
  local expected_digest="$2"
  local expected_source_sha="$3"
  local metadata_file="${4:-}"
  local image digest repository revision

  [[ -n "$images" ]] || return 1

  while IFS= read -r image; do
    [[ -n "$image" ]] || return 1
    digest="${image##*@}"
    validate_digest "$digest" || return 1
    [[ "$digest" == "$expected_digest" ]] || return 1
    repository="${image%@*}"
    repository="${repository#docker-pullable://}"

    if [[ -n "$metadata_file" ]]; then
      revision="$(awk -F '\t' -v repository="$repository" -v digest="$digest" \
        '$1 == repository && $2 == digest {print $3}' "$metadata_file")"
    else
      revision="$(docker buildx imagetools inspect "$repository@$digest" \
        --format '{{json .Image.Config.Labels}}' | jq -er '."org.opencontainers.image.revision"')"
    fi

    [[ "$revision" == "$expected_source_sha" ]] || return 1
  done <<<"$images"
}

if [[ "${1:-}" == "--self-test" ]]; then
  validate_sha 0123456789abcdef0123456789abcdef01234567
  if validate_sha main; then exit 1; fi
  validate_digest sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  if validate_digest sha256:short; then exit 1; fi
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  expected_sha="0123456789abcdef0123456789abcdef01234567"
  expected_digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  other_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  printf 'registry.example.com/example/app\t%s\t%s\n' "$expected_digest" "$expected_sha" >"$temp_dir/metadata.tsv"
  images="docker-pullable://registry.example.com/example/app@$expected_digest"
  validate_observed_images "$images" "$expected_digest" "$expected_sha" "$temp_dir/metadata.tsv"
  if validate_observed_images "$images" "$other_digest" "$expected_sha" "$temp_dir/metadata.tsv"; then exit 1; fi
  mixed="$images"$'\n'"docker-pullable://registry.example.com/example/app@$other_digest"
  if validate_observed_images "$mixed" "$expected_digest" "$expected_sha" "$temp_dir/metadata.tsv"; then exit 1; fi
  printf 'registry.example.com/example/app\t%s\t%s\n' "$expected_digest" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"$temp_dir/bad-mapping.tsv"
  if validate_observed_images "$images" "$expected_digest" "$expected_sha" "$temp_dir/bad-mapping.tsv"; then exit 1; fi
  printf 'read-only rollout observer self-test passed\n'
  exit 0
fi

context=""
namespace=""
source_sha=""
expected_digest=""
label="app.kubernetes.io/name=codex-pooler"

while (($#)); do
  case "$1" in
    --context) context="${2:-}"; shift 2 ;;
    --namespace) namespace="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --expected-digest) expected_digest="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

[[ "$context" =~ ^[a-zA-Z0-9._-]+$ ]] || { printf 'invalid context\n' >&2; exit 2; }
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'invalid namespace\n' >&2; exit 2; }
[[ "$label" =~ ^[a-zA-Z0-9./_-]+=[a-zA-Z0-9._-]+$ ]] || { printf 'invalid label\n' >&2; exit 2; }
validate_sha "$source_sha" || { printf 'invalid source sha\n' >&2; exit 2; }
validate_digest "$expected_digest" || { printf 'invalid expected digest\n' >&2; exit 2; }

images="$(kubectl --context "$context" -n "$namespace" get pods -l "$label" \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' | sort -u)"
[[ -n "$images" ]] || { printf 'no matching rollout images\n' >&2; exit 1; }
validate_observed_images "$images" "$expected_digest" "$source_sha" || {
  printf 'rollout image digest or revision mismatch\n' >&2
  exit 1
}

printf 'rollout observation passed source_sha=%s expected_digest=%s image_count=%s\n' \
  "$source_sha" "$expected_digest" "$(wc -l <<<"$images" | tr -d ' ')"
