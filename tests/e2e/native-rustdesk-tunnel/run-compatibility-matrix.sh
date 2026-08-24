#!/usr/bin/env bash
set -Eeuo pipefail

# Runs only version-pinned artifacts. This script never builds source: the
# compatibility claim is about the supplied old/new artifacts, not HEAD.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/tests/e2e/native-rustdesk-tunnel/run.sh"
MANIFEST=""
TARGET_ROOT="/tmp/nexusflow-native-tunnel-compat"
VALIDATE_ONLY=0

usage() {
  cat <<'EOF'
Usage: run-compatibility-matrix.sh --manifest FILE [--target-root DIR] [--validate-only]

Manifest version 1 has exactly these cases:
  old-client-old-server, old-client-new-server, new-disabled-client-old-server,
  new-enabled-client-new-server, new-enabled-client-old-server.

Each case supplies absolute executable artifacts `controlPlane`, `hbbs`, `hbbr`,
`host`, and `gateway`, with matching non-empty `versions` and `sha256` objects and all three
`transports`: direct, kcp, relay. `--validate-only` checks this contract without
starting a process; it is intentionally not a compatibility pass.
EOF
}

while (($#)); do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --target-root) TARGET_ROOT="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || { echo '--manifest must name an existing file' >&2; exit 2; }
[[ "$TARGET_ROOT" = /* ]] || { echo '--target-root must be an absolute path' >&2; exit 2; }
command -v jq >/dev/null || { echo 'missing command: jq' >&2; exit 2; }
command -v sha256sum >/dev/null || { echo 'missing command: sha256sum' >&2; exit 2; }

expected_cases=(
  old-client-old-server
  old-client-new-server
  new-disabled-client-old-server
  new-enabled-client-new-server
  new-enabled-client-old-server
)
artifact_keys=(controlPlane hbbs hbbr host gateway)

[[ "$(jq -r '.version // empty' "$MANIFEST")" == 1 ]] || { echo 'manifest version must be 1' >&2; exit 2; }
mapfile -t actual_cases < <(jq -r '.cases[]?.id // empty' "$MANIFEST" | sort)
[[ "${#actual_cases[@]}" == "${#expected_cases[@]}" ]] || { echo 'manifest must contain exactly five compatibility cases' >&2; exit 2; }
for case_id in "${expected_cases[@]}"; do
  [[ " ${actual_cases[*]} " == *" $case_id "* ]] || { echo "manifest is missing case: $case_id" >&2; exit 2; }
done
[[ "$(printf '%s\n' "${actual_cases[@]}" | uniq | wc -l)" == "${#actual_cases[@]}" ]] || { echo 'manifest case IDs must be unique' >&2; exit 2; }

validate_case() {
  local case_id="$1" key path digest version
  jq -e --arg id "$case_id" '
    .cases[] | select(.id == $id)
    | (.transports | sort == ["direct", "kcp", "relay"])
  ' "$MANIFEST" >/dev/null || { echo "$case_id must cover direct, kcp, and relay" >&2; return 2; }
  for key in "${artifact_keys[@]}"; do
    path="$(jq -r --arg id "$case_id" --arg key "$key" '.cases[] | select(.id == $id) | .artifacts[$key] // empty' "$MANIFEST")"
    version="$(jq -r --arg id "$case_id" --arg key "$key" '.cases[] | select(.id == $id) | .versions[$key] // empty' "$MANIFEST")"
    digest="$(jq -r --arg id "$case_id" --arg key "$key" '.cases[] | select(.id == $id) | .sha256[$key] // empty' "$MANIFEST")"
    [[ "$path" = /* && -x "$path" ]] || { echo "$case_id.$key must be an executable absolute path" >&2; return 2; }
    [[ -n "$version" ]] || { echo "$case_id.$key requires a frozen version identifier" >&2; return 2; }
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || { echo "$case_id.$key requires a SHA-256" >&2; return 2; }
    [[ "$(sha256sum "$path" | awk '{print $1}')" == "${digest,,}" ]] || { echo "$case_id.$key SHA-256 mismatch" >&2; return 2; }
  done
}

for case_id in "${expected_cases[@]}"; do validate_case "$case_id"; done
if ((VALIDATE_ONLY)); then
  echo 'compatibility manifest contract is valid; no compatibility result was produced'
  exit 0
fi

mkdir -p "$TARGET_ROOT"
summary="$TARGET_ROOT/compatibility-result.json"
entries="$TARGET_ROOT/compatibility-entries.jsonl"
: >"$entries"
for case_id in "${expected_cases[@]}"; do
  for transport in direct kcp relay; do
    case_root="$TARGET_ROOT/$case_id/$transport"
    args=(
      --target-root "$case_root" --matrix all --transport "$transport"
      --control-plane-bin "$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .artifacts.controlPlane' "$MANIFEST")"
      --hbbs-bin "$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .artifacts.hbbs' "$MANIFEST")"
      --hbbr-bin "$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .artifacts.hbbr' "$MANIFEST")"
      --host-bin "$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .artifacts.host' "$MANIFEST")"
      --gateway-bin "$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .artifacts.gateway' "$MANIFEST")"
    )
    if "$RUNNER" "${args[@]}"; then
      jq -n --arg case "$case_id" --arg transport "$transport" --arg result "$case_root/result.json" '{case:$case,transport:$transport,result:$result,status:"passed"}' >>"$entries"
    else
      jq -n --arg case "$case_id" --arg transport "$transport" --arg root "$case_root" '{case:$case,transport:$transport,targetRoot:$root,status:"failed"}' >>"$entries"
      jq -s --arg manifest "$MANIFEST" '{result:"failed",runs:.,manifest:$manifest}' "$entries" >"$summary"
      exit 1
    fi
  done
done
jq -s --arg manifest "$MANIFEST" '{result:"passed",runs:.,manifest:$manifest}' "$entries" >"$summary"
echo "compatibility matrix passed: $summary"
