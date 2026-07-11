#!/usr/bin/env bash
set -euo pipefail

validate_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
validate_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

resolve_platform_manifest() {
  jq -er '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")]
    | if length == 1 then .[0].digest else error("expected one linux/amd64 manifest") end
  ' "$1"
}

validate_provenance_chain() {
  local index_file="$1" provenance_file="$2" expected_sha="$3" platform_digest="$4"
  local labels_file="${5:-}" revision builder_platform attestation_count label_revision

  revision="$(jq -er '.SLSA.runDetails.metadata.buildkit_metadata.vcs.revision' "$provenance_file")"
  builder_platform="$(jq -er '.SLSA.buildDefinition.internalParameters.builderPlatform' "$provenance_file")"
  [[ "$(jq -er '.SLSA.buildDefinition.buildType' "$provenance_file")" == \
    "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md" ]] || return 1
  [[ "$revision" == "$expected_sha" ]] || return 1
  [[ "$builder_platform" == "linux/amd64" ]] || return 1

  attestation_count="$(jq -er --arg digest "$platform_digest" '
    [.manifests[] | select(
      .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
      .annotations["vnd.docker.reference.digest"] == $digest
    )] | length
  ' "$index_file")"
  [[ "$attestation_count" == "1" ]] || return 1

  if [[ -n "$labels_file" ]]; then
    label_revision="$(jq -r '."org.opencontainers.image.revision" // empty' "$labels_file")"
    [[ -z "$label_revision" || "$label_revision" == "$expected_sha" ]] || return 1
  fi
}

validate_workloads() {
  local workloads_file="$1" expected_digest="$2" expected_architecture="$3"
  local selected_count image_id pod_architecture role pod container

  selected_count=0
  while IFS=$'\t' read -r role pod container image_id pod_architecture; do
    [[ -n "$role" && -n "$pod" && -n "$container" ]] || return 1
    [[ "$role" == "app" || "$role" == "oban-worker" || "$role" == "oban-scheduler" ]] || continue
    selected_count=$((selected_count + 1))
    [[ "$image_id" == "docker-pullable://"*"@${expected_digest}" || \
      "$image_id" == *"@${expected_digest}" ]] || return 1
    [[ "$pod_architecture" == "$expected_architecture" ]] || return 1
  done <"$workloads_file"

  [[ "$selected_count" -ge 4 ]]
}

self_test() {
  local temp_dir expected_sha expected_digest platform_digest other_digest
  temp_dir="$(mktemp -d)"
  self_test_temp_dir="$temp_dir"
  trap 'rm -rf "$self_test_temp_dir"' EXIT
  expected_sha="0123456789abcdef0123456789abcdef01234567"
  expected_digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  platform_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  other_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  jq -n --arg platform "$platform_digest" '{schemaVersion: 2, manifests: [
    {digest: $platform, platform: {os: "linux", architecture: "amd64"}},
    {digest: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
     platform: {os: "unknown", architecture: "unknown"}, annotations: {
       "vnd.docker.reference.type": "attestation-manifest",
       "vnd.docker.reference.digest": $platform}}
  ]}' >"$temp_dir/index.json"
  jq -n --arg revision "$expected_sha" '{SLSA: {buildDefinition: {
    buildType: "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
    internalParameters: {builderPlatform: "linux/amd64"}}, runDetails: {metadata: {
    buildkit_metadata: {vcs: {revision: $revision}}}}}}' >"$temp_dir/provenance.json"
  printf '{}\n' >"$temp_dir/labels.json"
  printf 'app\tapp-1\tapp\tdocker-pullable://registry.example/app@%s\tamd64\napp\tapp-2\tapp\tdocker-pullable://registry.example/app@%s\tamd64\noban-worker\tworker-1\tworker\tdocker-pullable://registry.example/app@%s\tamd64\noban-scheduler\tscheduler-1\tscheduler\tdocker-pullable://registry.example/app@%s\tamd64\n' \
    "$expected_digest" "$expected_digest" "$expected_digest" "$expected_digest" >"$temp_dir/workloads.tsv"

  [[ "$(resolve_platform_manifest "$temp_dir/index.json")" == "$platform_digest" ]]
  validate_provenance_chain "$temp_dir/index.json" "$temp_dir/provenance.json" "$expected_sha" "$platform_digest" "$temp_dir/labels.json"
  validate_workloads "$temp_dir/workloads.tsv" "$expected_digest" amd64

  if validate_workloads "$temp_dir/workloads.tsv" "$other_digest" amd64; then return 1; fi
  sed "3s/$expected_digest/$other_digest/" "$temp_dir/workloads.tsv" >"$temp_dir/mixed.tsv"
  if validate_workloads "$temp_dir/mixed.tsv" "$expected_digest" amd64; then return 1; fi
  sed '2s/amd64$/arm64/' "$temp_dir/workloads.tsv" >"$temp_dir/wrong-architecture.tsv"
  if validate_workloads "$temp_dir/wrong-architecture.tsv" "$expected_digest" amd64; then return 1; fi
  sed '2s#docker-pullable://registry.example/app@[^[:space:]]*##' "$temp_dir/workloads.tsv" >"$temp_dir/missing-image-id.tsv"
  if validate_workloads "$temp_dir/missing-image-id.tsv" "$expected_digest" amd64; then return 1; fi
  jq --arg digest "$other_digest" '.manifests[0].digest = $digest' "$temp_dir/index.json" >"$temp_dir/wrong-platform.json"
  if validate_provenance_chain "$temp_dir/wrong-platform.json" "$temp_dir/provenance.json" "$expected_sha" "$other_digest"; then return 1; fi
  if validate_provenance_chain "$temp_dir/index.json" "$temp_dir/provenance.json" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$platform_digest"; then return 1; fi

  printf 'read-only rollout observer self-test passed\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

context=""
namespace=""
source_sha=""
expected_digest=""
repository=""
label="app.kubernetes.io/name=codex-pooler"

while (($#)); do
  case "$1" in
    --context) context="${2:-}"; shift 2 ;;
    --namespace) namespace="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --expected-digest) expected_digest="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

[[ "$context" =~ ^[a-zA-Z0-9._-]+$ ]] || { printf 'invalid context\n' >&2; exit 2; }
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'invalid namespace\n' >&2; exit 2; }
[[ "$repository" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$ ]] || { printf 'invalid repository\n' >&2; exit 2; }
[[ "$label" =~ ^[a-zA-Z0-9./_-]+=[a-zA-Z0-9._-]+$ ]] || { printf 'invalid label\n' >&2; exit 2; }
validate_sha "$source_sha" || { printf 'invalid source sha\n' >&2; exit 2; }
validate_digest "$expected_digest" || { printf 'invalid expected digest\n' >&2; exit 2; }

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
immutable_ref="${repository}@${expected_digest}"
docker buildx imagetools inspect "$immutable_ref" --raw >"$temp_dir/index.json"
platform_digest="$(resolve_platform_manifest "$temp_dir/index.json")"
docker buildx imagetools inspect "$immutable_ref" --format '{{json .Provenance}}' >"$temp_dir/provenance.json"
docker buildx imagetools inspect "${repository}@${platform_digest}" \
  --format '{{json .Image.Config.Labels}}' >"$temp_dir/labels.json"
validate_provenance_chain "$temp_dir/index.json" "$temp_dir/provenance.json" \
  "$source_sha" "$platform_digest" "$temp_dir/labels.json" || {
  printf 'trusted index/platform/source provenance mismatch\n' >&2
  exit 1
}

kubectl --context "$context" -n "$namespace" get pods -l "$label" -o json >"$temp_dir/pods.json"
kubectl --context "$context" get nodes -o json >"$temp_dir/nodes.json"
jq -er --slurpfile nodes "$temp_dir/nodes.json" '
  .items[] as $pod
  | ($nodes[0].items[] | select(.metadata.name == $pod.spec.nodeName) | .status.nodeInfo.architecture) as $architecture
  | ($pod.metadata.labels["app.kubernetes.io/component"] // "") as $role
  | $pod.status.containerStatuses[]
  | [$role, $pod.metadata.name, .name, (.imageID // ""), $architecture]
  | @tsv
' "$temp_dir/pods.json" >"$temp_dir/workloads.tsv"
validate_workloads "$temp_dir/workloads.tsv" "$expected_digest" amd64 || {
  printf 'rollout workload index or architecture mismatch\n' >&2
  exit 1
}

printf 'rollout observation passed source_sha=%s index_digest=%s platform_digest=%s platform=linux/amd64 containers=%s\n' \
  "$source_sha" "$expected_digest" "$platform_digest" "$(wc -l <"$temp_dir/workloads.tsv" | tr -d ' ')"
