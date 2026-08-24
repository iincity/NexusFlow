#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/tests/e2e/native-rustdesk-tunnel/run-compatibility-matrix.sh"
TEMP_ROOT="$(mktemp -d /tmp/nexusflow-compat-contract.XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

for name in controlPlane hbbs hbbr host gateway; do cp /usr/bin/true "$TEMP_ROOT/$name"; done
digest="$(sha256sum "$TEMP_ROOT/controlPlane" | awk '{print $1}')"
jq -n --arg root "$TEMP_ROOT" --arg digest "$digest" '
  def artifacts: {controlPlane:($root + "/controlPlane"),hbbs:($root + "/hbbs"),hbbr:($root + "/hbbr"),host:($root + "/host"),gateway:($root + "/gateway")};
  def hashes: {controlPlane:$digest,hbbs:$digest,hbbr:$digest,host:$digest,gateway:$digest};
  def versions: {controlPlane:"test",hbbs:"test",hbbr:"test",host:"test",gateway:"test"};
  def case($id): {id:$id,transports:["direct","kcp","relay"],artifacts:artifacts,versions:versions,sha256:hashes};
  {version:1,cases:[case("old-client-old-server"),case("old-client-new-server"),case("new-disabled-client-old-server"),case("new-enabled-client-new-server"),case("new-enabled-client-old-server")]}
' >"$TEMP_ROOT/manifest.json"

"$RUNNER" --manifest "$TEMP_ROOT/manifest.json" --validate-only
jq '.cases[0].sha256.host = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$TEMP_ROOT/manifest.json" >"$TEMP_ROOT/tampered.json"
if "$RUNNER" --manifest "$TEMP_ROOT/tampered.json" --validate-only; then
  echo 'tampered artifact digest was accepted' >&2
  exit 1
fi
echo 'compatibility manifest contract tests passed'
