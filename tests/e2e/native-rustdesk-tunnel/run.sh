#!/usr/bin/env bash
set -Eeuo pipefail

# Native RustDesk process harness. It deliberately owns only the explicit
# target directory supplied by the caller; no repository state is modified.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TARGET_ROOT="/tmp/nexusflow-native-tunnel"
CARGO_HOME_OVERRIDE=""
MATRIX="smoke"
TRANSPORT="direct"
CP_BIN_OVERRIDE=""
HBBS_BIN_OVERRIDE=""
HBBR_BIN_OVERRIDE=""
HOST_BIN_OVERRIDE=""
GATEWAY_BIN_OVERRIDE=""
PIDS=()
GATEWAY_PIDS=()

usage() {
  cat <<'EOF'
Usage: run.sh [--target-root DIR] [--cargo-home DIR] [--matrix smoke|authi|all] [--transport LIST]
              [--control-plane-bin FILE] [--hbbs-bin FILE] [--hbbr-bin FILE]
              [--host-bin FILE] [--gateway-bin FILE]

smoke starts the real control-plane, hbbs and hbbr binaries and verifies that
their listeners stay alive. all additionally requires explicit Host/Gateway
credentials and is reserved for the full multi-process matrix.
authi runs the same real Host/Control-Plane Agent lifecycle only, so each
transport can be verified without repeating the longer PortForward matrix.
EOF
}

while (($#)); do
  case "$1" in
    --target-root) TARGET_ROOT="$2"; shift 2 ;;
    --cargo-home) CARGO_HOME_OVERRIDE="$2"; shift 2 ;;
    --matrix) MATRIX="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --control-plane-bin) CP_BIN_OVERRIDE="$2"; shift 2 ;;
    --hbbs-bin) HBBS_BIN_OVERRIDE="$2"; shift 2 ;;
    --hbbr-bin) HBBR_BIN_OVERRIDE="$2"; shift 2 ;;
    --host-bin) HOST_BIN_OVERRIDE="$2"; shift 2 ;;
    --gateway-bin) GATEWAY_BIN_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MATRIX" in smoke|authi|all) ;; *) echo "--matrix must be smoke, authi, or all" >&2; exit 2 ;; esac
case "$CARGO_HOME_OVERRIDE" in ''|/*) ;; *) echo "--cargo-home must be an absolute path" >&2; exit 2 ;; esac
case "$TRANSPORT" in
  direct) HBBS_ALWAYS_USE_RELAY=N; GATEWAY_FORCE_RELAY=N; HOST_DISABLE_DIRECT_SERVER=0 ;;
  # Keep the Host's native direct listener available: RustDesk's KCP acceptor
  # is owned by that listener. The Gateway test hook skips its TCP candidate,
  # so the session still proves UDP/KCP selection without disabling the host
  # transport required to accept it.
  kcp) HBBS_ALWAYS_USE_RELAY=N; GATEWAY_FORCE_RELAY=N; HOST_DISABLE_DIRECT_SERVER=0 ;;
  relay) HBBS_ALWAYS_USE_RELAY=Y; GATEWAY_FORCE_RELAY=Y; HOST_DISABLE_DIRECT_SERVER=0 ;;
  *) echo "--transport must be direct, kcp, or relay" >&2; exit 2 ;;
esac
mkdir -p "$TARGET_ROOT/logs" "$TARGET_ROOT/run"
# The harness creates a fresh Host identity for each process run. Do not let a
# stale hbbs SQLite peer record rewrite that identity during another transport
# matrix; this directory is explicitly owned by the test invocation.
rm -f "$TARGET_ROOT/run/db_v2.sqlite3" "$TARGET_ROOT/run/db_v2.sqlite3-shm" "$TARGET_ROOT/run/db_v2.sqlite3-wal"
# Give each test run its own native IPC namespace. RustDesk derives Unix IPC
# paths from APP_NAME; a unique name prevents an interrupted prior run from
# poisoning the next host process.
NEXUS_E2E_APP_NAME="RustDesk-NexusE2E-$$_$(date +%s)"
export NEXUS_E2E_APP_NAME

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

stop_gateways() {
  local pid
  for pid in "${GATEWAY_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${GATEWAY_PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
  GATEWAY_PIDS=()
}

if ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 2; }; }
require_cmd cargo
require_cmd curl
require_cmd jq
require_cmd openssl
require_cmd xxd
require_cmd python3
require_cmd ip

# hbbr reserves loopback peers for its legacy local console. Relay matrix uses
# the WSL eth0 address so its real framed Relay path is exercised; direct
# matrix stays on loopback for the smallest local fixture.
RUSTDESK_BIND_ADDR="127.0.0.1"
if [[ "$TRANSPORT" == relay ]]; then
  RUSTDESK_BIND_ADDR="$(ip -4 -o addr show dev eth0 scope global | awk 'NR == 1 { split($4, address, "/"); print address[1] }')"
  [[ -n "$RUSTDESK_BIND_ADDR" ]] || { echo 'relay E2E requires a WSL eth0 IPv4 address' >&2; exit 2; }
fi

CP_MANIFEST="$ROOT/components/nexus-platform/control-plane/Cargo.toml"
SERVER_MANIFEST="$ROOT/components/rustdesk-server/Cargo.toml"
CP_TARGET="$TARGET_ROOT/cp-target"
SERVER_TARGET="$TARGET_ROOT/server-target"
CLIENT_TARGET="$TARGET_ROOT/client-target"
PKG_CONFIG_DIR="$TARGET_ROOT/pkgconfig"
# Never use the workstation-shared Cargo home: a previous root build can leave
# registry checkouts unreadable to the WSL user. By default the harness owns
# its cache; an explicit private cache lets a repeated matrix reuse its locked
# Git objects without copying a large cache during the test run.
export CARGO_HOME="${CARGO_HOME_OVERRIDE:-$TARGET_ROOT/cargo-home}"
mkdir -p "$CARGO_HOME"
export GIT_CONFIG_GLOBAL="$CARGO_HOME/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" \
  url.https://github.com/webmproject/libwebm.git.insteadOf \
  https://chromium.googlesource.com/webm/libwebm
export CARGO_NET_GIT_FETCH_WITH_CLI=true
# CI can retain the deterministic offline default; a fresh local WSL cache can
# explicitly set CARGO_NET_OFFLINE=false to fetch its locked crate archives.
export CARGO_NET_OFFLINE="${CARGO_NET_OFFLINE:-true}"
export CARGO_BUILD_JOBS=1
mkdir -p "$PKG_CONFIG_DIR"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:$PKG_CONFIG_DIR"
if [[ ! -f "$PKG_CONFIG_DIR/libyuv.pc" ]]; then
  cat > "$PKG_CONFIG_DIR/libyuv.pc" <<'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=/usr/lib/x86_64-linux-gnu
includedir=/usr/include
Name: libyuv
Description: libyuv
Version: 0.0
Libs: -L${libdir} -lyuv
Cflags: -I${includedir}
EOF
fi
if [[ ! -f "$PKG_CONFIG_DIR/vpx.pc" ]]; then
  cat > "$PKG_CONFIG_DIR/vpx.pc" <<'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=/usr/lib/x86_64-linux-gnu
includedir=/usr/include
Name: vpx
Description: libvpx
Version: 1.14
Libs: -L${libdir} -lvpx
Cflags: -I${includedir}
EOF
fi
# Reuse only archive/index caches. Cargo safely unpacks archives beneath this
# private CARGO_HOME; copying registry/src can preserve an interrupted unpack.
if [[ -z "$CARGO_HOME_OVERRIDE" ]]; then
  for cargo_cache in git registry/cache registry/index; do
    if [[ -d "$HOME/.cargo/$cargo_cache" ]]; then
      mkdir -p "$CARGO_HOME/$cargo_cache"
      cp -a --update=none "$HOME/.cargo/$cargo_cache/." "$CARGO_HOME/$cargo_cache/" 2>/dev/null || true
    fi
  done
fi
# rust-webm pins libwebm as a Git submodule. Keep Cargo's real checked-out
# submodule metadata intact: unpacking a source tarball here makes the
# worktree look populated but leaves no commit for Cargo to verify offline.
# A cold cache must be primed once with CARGO_NET_OFFLINE=false; subsequent
# runs reuse this harness-private CARGO_HOME without another network fetch.
mkdir -p "$TARGET_ROOT/logs"

echo "[native-e2e] root=$ROOT target=$TARGET_ROOT matrix=$MATRIX transport=$TRANSPORT rustdesk-bind=$RUSTDESK_BIND_ADDR"
if [[ "${NEXUS_E2E_SKIP_BUILD:-0}" != 1 && ( -z "$CP_BIN_OVERRIDE" || -z "$HBBS_BIN_OVERRIDE" || -z "$HBBR_BIN_OVERRIDE" ) ]]; then
  echo "[native-e2e] building control-plane and RustDesk server binaries"
  CARGO_TARGET_DIR="$CP_TARGET" cargo build --locked --manifest-path "$CP_MANIFEST" --bin nexus-control-plane \
    2>&1 | tee "$TARGET_ROOT/logs/build-control-plane.log"
  CARGO_TARGET_DIR="$SERVER_TARGET" cargo build --locked --manifest-path "$SERVER_MANIFEST" --bin hbbs --bin hbbr --features nexus-native-tunnel \
    2>&1 | tee "$TARGET_ROOT/logs/build-rustdesk-server.log"
fi

CP_BIN="$CP_TARGET/debug/nexus-control-plane"
HBBS_BIN="$SERVER_TARGET/debug/hbbs"
HBBR_BIN="$SERVER_TARGET/debug/hbbr"
[[ -z "$CP_BIN_OVERRIDE" ]] || CP_BIN="$CP_BIN_OVERRIDE"
[[ -z "$HBBS_BIN_OVERRIDE" ]] || HBBS_BIN="$HBBS_BIN_OVERRIDE"
[[ -z "$HBBR_BIN_OVERRIDE" ]] || HBBR_BIN="$HBBR_BIN_OVERRIDE"
if [[ "$MATRIX" != smoke ]]; then
  echo "[native-e2e] building RustDesk Client Host/Gateway binaries"
  if [[ "${NEXUS_E2E_SKIP_BUILD:-0}" != 1 && ( -z "$HOST_BIN_OVERRIDE" || -z "$GATEWAY_BIN_OVERRIDE" ) ]]; then
    (
      cd "$ROOT/components/nexus-rustdesk"
      python3 res/inline-sciter.py
    )
    CARGO_TARGET_DIR="$CLIENT_TARGET" cargo build --locked --manifest-path "$ROOT/components/nexus-rustdesk/Cargo.toml" \
      --no-default-features --bin nexus-e2e-host --bin nexus-e2e-gateway \
      --features nexus-e2e-host,nexus-e2e-gateway,linux-pkg-config,use_dasp \
      2>&1 | tee "$TARGET_ROOT/logs/build-rustdesk-client.log"
  fi
  HOST_BIN="$CLIENT_TARGET/debug/nexus-e2e-host"
  GATEWAY_BIN="$CLIENT_TARGET/debug/nexus-e2e-gateway"
  [[ -z "$HOST_BIN_OVERRIDE" ]] || HOST_BIN="$HOST_BIN_OVERRIDE"
  [[ -z "$GATEWAY_BIN_OVERRIDE" ]] || GATEWAY_BIN="$GATEWAY_BIN_OVERRIDE"
  [[ -x "$HOST_BIN" && -x "$GATEWAY_BIN" ]] || { echo "native Client binaries were not produced" >&2; exit 2; }
fi
[[ -x "$CP_BIN" && -x "$HBBS_BIN" && -x "$HBBR_BIN" ]] || { echo "native control-plane/server binaries were not produced" >&2; exit 2; }

export PORT=23005 METRICS_PORT=23909
export DATABASE_URL="postgres://nexus-e2e.invalid/nexus"
export REDIS_URL="redis://127.0.0.1:63999"
export HANDY_MASTER_SECRET="native-e2e-only-secret"
export S3_HOST="127.0.0.1:9000"
export S3_PUBLIC_URL="http://127.0.0.1:9000"
export S3_USE_SSL=false
export S3_BUCKET="nexus-native-e2e"
export S3_REGION="us-east-1"
export S3_ACCESS_KEY="native-e2e"
export S3_SECRET_KEY="native-e2e-only-secret"
export NEXUS_CONTROL_PLANE_USE_IN_MEMORY_IDENTITY_STORE=true
export NEXUS_CONTROL_PLANE_USE_IN_MEMORY_SYNC_STORE=true
export NEXUS_CONTROL_PLANE_USE_IN_MEMORY_USAGE_STORE=true
export NEXUS_CONTROL_PLANE_USE_IN_MEMORY_OPENCLAW_STORE=true
export NEXUS_CONTROL_PLANE_USE_IN_MEMORY_ORCHESTRATOR_STORE=true
export NEXUS_PRESENCE_RESOLVER_TOKEN="native-e2e-registration-secret"
export NEXUS_RUSTDESK_REGISTRATION_TOKEN="$NEXUS_PRESENCE_RESOLVER_TOKEN"
export NEXUS_E2E_AUTODISPATCH=1
# Keep the fixture key exactly 32 bytes (64 hex characters); shell printf's
# repeated-format behavior differs between environments.
export NEXUS_CONTROL_PLANE_TUNNEL_SIGNING_KEY="$(python3 -c 'print("1d" * 32, end="")')"
# The native relay admission verifier runs inside hbbr, so the harness must
# provision the same node credential and signing public key that the control
# plane uses for the short-lived relay grant.  Keep this test-only material
# deterministic; production relay credentials are injected by deployment.
export NEXUS_RELAY_NODE_CREDENTIALS='{"native-e2e":"native-e2e-relay-secret"}'
export NEXUS_CONTROL_PLANE_URL="http://127.0.0.1:23005"
export NEXUS_RELAY_NODE_ID="native-e2e"
export NEXUS_RELAY_BOOTSTRAP_SECRET="native-e2e-relay-secret"
export NEXUS_TUNNEL_SIGNING_KEY_ID="default"
export NEXUS_TUNNEL_SIGNING_PUBLIC_KEY_HEX="$(printf '302e020100300506032b657004220420%s' "$NEXUS_CONTROL_PLANE_TUNNEL_SIGNING_KEY" | xxd -r -p | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256)"
[[ "${#NEXUS_TUNNEL_SIGNING_PUBLIC_KEY_HEX}" == 64 ]] || { echo 'failed to derive native-e2e relay signing public key' >&2; exit 2; }
export NEXUS_BILLING_WEBHOOK_TOKEN="native-e2e-billing-secret"
# Test diagnostics are opt-in so ordinary runs retain production-level logs.
export RUST_LOG="${NEXUS_E2E_RUST_LOG:-info}"

# This harness owns fixed listener ports. Refuse a run if a previous process
# already owns one: otherwise its /health response can be mistaken for the
# freshly started control plane while the new process is still initialising.
python3 - <<'PY'
import socket
import sys

listeners = (
    (socket.SOCK_STREAM, 23005, "control-plane"),
    (socket.SOCK_STREAM, 23909, "control-plane metrics"),
    (socket.SOCK_STREAM, 23115, "hbbs NAT-test"),
    (socket.SOCK_STREAM, 23116, "hbbs"),
    (socket.SOCK_DGRAM, 23116, "hbbs UDP"),
    (socket.SOCK_STREAM, 23117, "hbbr"),
    (socket.SOCK_STREAM, 23118, "hbbs websocket"),
    (socket.SOCK_STREAM, 23119, "hbbr websocket"),
)
sockets = []
try:
    for kind, port, name in listeners:
        listener = socket.socket(socket.AF_INET, kind)
        listener.bind(("0.0.0.0", port))
        sockets.append(listener)
except OSError as error:
    print(f"native-e2e listener preflight failed for {name} on {port}: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    for listener in sockets:
        listener.close()
PY

pushd "$TARGET_ROOT/run" >/dev/null
"$CP_BIN" >"$TARGET_ROOT/logs/control-plane.log" 2>&1 & PIDS+=("$!")
ALWAYS_USE_RELAY="$HBBS_ALWAYS_USE_RELAY" NEXUS_E2E_FORCE_KCP="$([[ "$TRANSPORT" == kcp ]] && echo 1 || echo 0)" "$HBBS_BIN" --bind "$RUSTDESK_BIND_ADDR" --port 23116 >"$TARGET_ROOT/logs/hbbs.log" 2>&1 & PIDS+=("$!")
"$HBBR_BIN" --bind "$RUSTDESK_BIND_ADDR" --port 23117 >"$TARGET_ROOT/logs/hbbr.log" 2>&1 & PIDS+=("$!")
popd >/dev/null

require_started_process() {
  local pid="$1" name="$2" log="$3" state
  # `kill -0` also succeeds for an exited-but-not-yet-reaped child. Treat a
  # zombie as failed so a stale /health listener cannot make this run pass.
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$state" && "$state" != Z* ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  echo "$name exited during startup; refusing to use a possibly stale listener" >&2
  tail -n 80 "$log" >&2 || true
  exit 1
}

wait_http() {
  local url="$1" i
  # A cold WSL build can leave the freshly linked Control Plane briefly
  # descheduled while hbbs/hbbr are already listening. Keep startup bounded,
  # but do not turn that local scheduler variance into a false E2E failure.
  for i in {1..300}; do
    require_started_process "${PIDS[0]}" control-plane "$TARGET_ROOT/logs/control-plane.log"
    curl --silent --show-error --fail "$url" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

wait_http "http://127.0.0.1:23005/health" || {
  echo "control-plane health endpoint did not become ready" >&2
  exit 1
}
require_started_process "${PIDS[0]}" control-plane "$TARGET_ROOT/logs/control-plane.log"
require_started_process "${PIDS[1]}" hbbs "$TARGET_ROOT/logs/hbbs.log"
require_started_process "${PIDS[2]}" hbbr "$TARGET_ROOT/logs/hbbr.log"
echo "[native-e2e] control-plane, hbbs and hbbr are alive"

if [[ "$MATRIX" != smoke ]]; then
  api="http://127.0.0.1:23005"
  host_home="$TARGET_ROOT/host-home"
  gateway_home="$TARGET_ROOT/gateway-home"
  credential_path="$TARGET_ROOT/gateway-credential.json"
  mkdir -p "$host_home" "$gateway_home"

  json_post() {
    local path="$1" body="$2"
    curl --silent --show-error --fail --header "content-type: application/json" \
      --header "authorization: Bearer $bearer" --data "$body" "$api$path"
  }
  auth_key="$TARGET_ROOT/e2e-auth.key"
  challenge="$TARGET_ROOT/e2e-auth.challenge"
  openssl genpkey -algorithm ED25519 -out "$auth_key" >/dev/null 2>&1
  printf 'nexus-native-e2e' >"$challenge"
  public_key="$(openssl pkey -in "$auth_key" -pubout -outform DER | tail -c 32 | base64 -w0)"
  signed_challenge="$(openssl pkeyutl -sign -rawin -inkey "$auth_key" -in "$challenge" | base64 -w0)"
  auth_payload="$(jq -cn --arg publicKey "$public_key" --arg challenge "$(base64 -w0 "$challenge")" --arg signature "$signed_challenge" '{publicKey:$publicKey,challenge:$challenge,signature:$signature}')"
  bearer="$(curl --silent --show-error --fail --header 'content-type: application/json' --data "$auth_payload" "$api/v1/auth" | jq -er '.token')"

  # The host and gateway generate their normal RustDesk device keys in distinct
  # homes. The harness only reads public material to register those devices.
  rendezvous_key="$(tr -d '\r\n' <"$TARGET_ROOT/run/id_ed25519.pub")"
  (cd "$host_home" && NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_RENDEZVOUS_SERVER="$RUSTDESK_BIND_ADDR:23116" NEXUS_E2E_PRINT_IDENTITY=1 HOME="$host_home" XDG_CONFIG_HOME="$host_home/config" "$HOST_BIN") >"$TARGET_ROOT/logs/host-identity.log" 2>&1
  host_id="$(sed -n 's/^NEXUS_E2E_HOST_ID=//p' "$TARGET_ROOT/logs/host-identity.log" | head -n1)"
  host_key="$(sed -n 's/^NEXUS_E2E_HOST_PUBLIC_KEY_HEX=//p' "$TARGET_ROOT/logs/host-identity.log" | head -n1)"
  [[ -n "$host_id" && -n "$host_key" ]] || { echo 'publishing Host identity unavailable' >&2; exit 1; }
  agent_machine_id="native-e2e-agent-machine"
  json_post /v1/machines "$(jq -cn --arg id "$agent_machine_id" '{id:$id,metadata:"Native RustDesk Agent E2E",daemonState:"ready",dataEncryptionKey:"AQIDBA=="}')" >/dev/null
  host_device="$(json_post /v1/devices/register "$(jq -cn --arg id "$host_id" --arg key "$host_key" --arg machine "$agent_machine_id" '{rustdeskId:$id,publicKeyHex:$key,machineId:$machine,capabilities:["tunnel","agent"]}')")"
  host_uid="$(jq -er '.deviceUid' <<<"$host_device")"
  # Allow the real RustDesk mediator to complete its first RegisterPeer before
  # the Gateway opens its first native PORT_FORWARD connection.
  # KCP deliberately disables the TCP direct listener. The mediator still
  # registers over its native UDP socket, so wait for that instead of a TCP
  # listener log line that the fixture intentionally suppresses.
  host_ready_pattern='start udp:'
  [[ "$HOST_DISABLE_DIRECT_SERVER" == 0 ]] && host_ready_pattern='(start udp:|Direct server listening on:)'
  (cd "$gateway_home" && HOME="$gateway_home" XDG_CONFIG_HOME="$gateway_home/config" NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_PRINT_IDENTITY=1 "$GATEWAY_BIN") >"$TARGET_ROOT/logs/gateway-identity.log" 2>&1
  gateway_id="$(sed -n 's/^NEXUS_E2E_GATEWAY_ID=//p' "$TARGET_ROOT/logs/gateway-identity.log")"
  gateway_key="$(sed -n 's/^NEXUS_E2E_GATEWAY_PUBLIC_KEY_HEX=//p' "$TARGET_ROOT/logs/gateway-identity.log")"
  [[ -n "$gateway_id" && -n "$gateway_key" ]] || { echo 'Gateway identity unavailable' >&2; exit 1; }

  tenant_id="$(json_post /v1/tenants "$(jq -cn '{name:"Native RustDesk E2E"}')" | jq -er '.id')"
  gateway_device="$(json_post /v1/devices/register "$(jq -cn --arg id "$gateway_id" --arg key "$gateway_key" '{rustdeskId:$id,publicKeyHex:$key,capabilities:["tunnel-access-gateway"]}')")"
  gateway_uid="$(jq -er '.deviceUid' <<<"$gateway_device")"
  curl --silent --show-error --fail -X PUT --header "authorization: Bearer $bearer" "$api/v1/tenants/$tenant_id/devices/$host_uid" >/dev/null
  curl --silent --show-error --fail -X PUT --header "authorization: Bearer $bearer" "$api/v1/tenants/$tenant_id/devices/$gateway_uid" >/dev/null
  billing_body="$(jq -cn --arg tenant "$tenant_id" '{provider:"native-e2e",eventId:"native-e2e-tunnel",tenantId:$tenant,entitlement:"tunnel.enabled",enabled:true}')"
  billing_signature="$(printf %s "$billing_body" | openssl dgst -sha256 -hmac "$NEXUS_BILLING_WEBHOOK_TOKEN" -hex | sed 's/^.* //')"
  curl --silent --show-error --fail --header 'content-type: application/json' --header "x-nexus-billing-signature: $billing_signature" --data "$billing_body" "$api/v1/internal/billing/events" >/dev/null

  # The Host begins with the Runtime's local presence-only state at version 1.
  # Issue version 2 before it starts so this process must fetch, verify, apply,
  # and report the Control Plane's signed Desired State rather than merely
  # exposing its local bootstrap state.
  desired_state_version=2
  desired_expires_at="$(( $(date +%s%3N) + 60000 ))"
  json_post "/v1/devices/$host_uid/tunnel/desired-state" "$(jq -cn --argjson version "$desired_state_version" --argjson expiresAt "$desired_expires_at" '{version:$version,mode:"presenceOnly",notBefore:0,expiresAt:$expiresAt}')" >/dev/null
  desired_state_ready_file="$TARGET_ROOT/desired-state.ready"
  rm -f "$desired_state_ready_file"
  billing_body="$(jq -cn --arg tenant "$tenant_id" '{provider:"native-e2e",eventId:"native-e2e-agent",tenantId:$tenant,entitlement:"agent.enabled",enabled:true}')"
  billing_signature="$(printf %s "$billing_body" | openssl dgst -sha256 -hmac "$NEXUS_BILLING_WEBHOOK_TOKEN" -hex | sed 's/^.* //')"
  curl --silent --show-error --fail --header 'content-type: application/json' --header "x-nexus-billing-signature: $billing_signature" --data "$billing_body" "$api/v1/internal/billing/events" >/dev/null

  agent_tls_key="$TARGET_ROOT/agent-control-plane.key"
  agent_tls_cert="$TARGET_ROOT/agent-control-plane.crt"
  agent_proxy_port=23006
  # This is a test-only TLS terminator. It must be an end-entity server
  # certificate: native-tls rejects a CA certificate as a WebSocket server
  # before the E2E-only invalid-chain fallback can apply.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$agent_tls_key" -out "$agent_tls_cert" -days 1 -subj '/CN=127.0.0.1' \
    -addext 'subjectAltName=IP:127.0.0.1' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
  openssl x509 -in "$agent_tls_cert" -noout -text | grep -A1 'Basic Constraints' | grep -q 'CA:FALSE' || {
    echo 'Agent TLS proxy certificate is not an end-entity certificate' >&2
    exit 1
  }
  node -e 'const fs=require("fs"),net=require("net"),tls=require("tls"); const [key,cert,listen,upstream]=process.argv.slice(1); tls.createServer({key:fs.readFileSync(key),cert:fs.readFileSync(cert)}, client=>{const peer=net.connect(+upstream,"127.0.0.1"); client.pipe(peer).pipe(client); client.on("error",()=>peer.destroy()); peer.on("error",()=>client.destroy());}).listen(+listen,"127.0.0.1");' "$agent_tls_key" "$agent_tls_cert" "$agent_proxy_port" 23005 >"$TARGET_ROOT/logs/agent-tls-proxy.log" 2>&1 & PIDS+=("$!")
  for _ in {1..50}; do openssl s_client -connect "127.0.0.1:$agent_proxy_port" -CAfile "$agent_tls_cert" </dev/null >/dev/null 2>&1 && break; sleep 0.1; done
  openssl s_client -connect "127.0.0.1:$agent_proxy_port" -CAfile "$agent_tls_cert" </dev/null >/dev/null 2>&1 || { echo 'Agent TLS proxy did not become ready' >&2; exit 1; }
  agent_api="https://127.0.0.1:$agent_proxy_port"
  agent_ready_file="$TARGET_ROOT/agent.ready"
  agent_payload_file="$TARGET_ROOT/agent-native-tunnel.payload"
  agent_retry_file="$TARGET_ROOT/agent-native-tunnel.retry"
  agent_cancel_file="$TARGET_ROOT/agent-native-tunnel.cancel-ready"
  rm -f "$agent_ready_file" "$agent_payload_file" "$agent_retry_file" "$agent_cancel_file"
  python3 -u -c $'import socket, threading\ns=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",24079)); s.listen()\ndef serve(c):\n    while data := c.recv(65536): c.sendall(data)\n    c.close()\nwhile True:\n    c,_=s.accept(); threading.Thread(target=serve,args=(c,),daemon=True).start()' >"$TARGET_ROOT/logs/private-agent-echo.log" 2>&1 & PIDS+=("$!")
  mkdir -p "$TARGET_ROOT/agent-bin"
  printf '%s\n' '#!/usr/bin/env python3' \
    'import os, socket, sys' \
    'endpoint = os.environ.get("NEXUS_AGENT_TUNNEL_ENDPOINT", "")' \
    'capability = os.environ.get("NEXUS_AGENT_TUNNEL_CAPABILITY", "")' \
    'root = os.environ.get("TMPDIR", "")' \
    'marker = os.path.join(root, "agent-native-tunnel.payload")' \
    'retry = os.path.join(root, "agent-native-tunnel.retry")' \
    'cancel = os.path.join(root, "agent-native-tunnel.cancel-ready")' \
    'if not endpoint or len(capability) != 64 or not marker: sys.exit(2)' \
    'host, port = endpoint.rsplit(":", 1)' \
    'payload = b"agent-execution-native-port-forward"' \
    'with socket.create_connection((host, int(port)), 10) as peer:' \
    '    peer.sendall(capability.encode() + b"\n" + payload)' \
    '    if peer.recv(65536) != payload: sys.exit(3)' \
    'open(marker, "w", encoding="utf-8").write("ok\\n")' >"$TARGET_ROOT/agent-bin/codex"
  printf '%s\n' \
    'prompt = " ".join(sys.argv)' \
    'if "native-rustdesk-host-agent-retry" in prompt and not os.path.exists(retry):' \
    '    open(retry, "w", encoding="utf-8").write("first-attempt\\n"); sys.exit(4)' \
    'if "native-rustdesk-host-agent-cancel" in prompt:' \
    '    open(cancel, "w", encoding="utf-8").write("running\\n"); import time; time.sleep(60)' >>"$TARGET_ROOT/agent-bin/codex"
  chmod 700 "$TARGET_ROOT/agent-bin/codex"
  legacy_password='native-e2e-legacy-password'
  (cd "$host_home" && PATH="$TARGET_ROOT/agent-bin:$PATH" TMPDIR="$TARGET_ROOT" SSL_CERT_FILE="$agent_tls_cert" NEXUS_E2E_ALLOW_INVALID_AGENT_TLS=1 NEXUS_E2E_AGENT_READY_FILE="$agent_ready_file" NEXUS_E2E_AGENT_DEVICE_UID="$host_uid" NEXUS_E2E_AGENT_CONTROL_PLANE_URL="$agent_api" NEXUS_E2E_DESIRED_STATE_READY_FILE="$desired_state_ready_file" NEXUS_E2E_DESIRED_STATE_VERSION="$desired_state_version" NEXUS_E2E_TRACE_PORT_FORWARD=1 NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_RENDEZVOUS_KEY="$rendezvous_key" NEXUS_E2E_RENDEZVOUS_SERVER="$RUSTDESK_BIND_ADDR:23116" NEXUS_E2E_FORCE_KCP="$([[ "$TRANSPORT" == kcp ]] && echo 1 || echo 0)" NEXUS_E2E_TUNNEL_SIGNING_KEY="$NEXUS_CONTROL_PLANE_TUNNEL_SIGNING_KEY" NEXUS_E2E_DISABLE_DIRECT_SERVER="$HOST_DISABLE_DIRECT_SERVER" NEXUS_E2E_LEGACY_PASSWORD="$legacy_password" HOME="$host_home" XDG_CONFIG_HOME="$host_home/config" "$HOST_BIN") >"$TARGET_ROOT/logs/host.log" 2>&1 & PIDS+=("$!")
  for _ in {1..60}; do
    grep -Eq "$host_ready_pattern" "$TARGET_ROOT/logs/host.log" && break
    sleep 0.5
  done
  grep -Eq "$host_ready_pattern" "$TARGET_ROOT/logs/host.log" || {
    echo 'publishing Host native server did not become ready' >&2
    tail -n 40 "$TARGET_ROOT/logs/host.log" >&2
    exit 1
  }
  for _ in {1..150}; do [[ -f "$agent_ready_file" ]] && break; sleep 0.2; done
  [[ -f "$agent_ready_file" ]] || { echo 'RustDesk Host Agent Socket did not become ready' >&2; tail -n 80 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  for _ in {1..150}; do [[ -f "$desired_state_ready_file" ]] && break; sleep 0.2; done
  [[ -f "$desired_state_ready_file" ]] || { echo 'RustDesk Host did not apply the signed Desired State' >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  for _ in {1..150}; do grep -q 'Nexus registration projection delivered' "$TARGET_ROOT/logs/hbbs.log" && break; sleep 0.2; done
  grep -q 'Nexus registration projection delivered' "$TARGET_ROOT/logs/hbbs.log" || { echo 'hbbs did not project the native registration to the Control Plane' >&2; tail -n 120 "$TARGET_ROOT/logs/hbbs.log" >&2; exit 1; }
  echo '[native-e2e] native registration and signed Desired State application passed'
  agent_prompt='native-rustdesk-host-agent-e2e'
  # This is intentionally the Host's own published fixture service.  The
  # scheduler derives an execution-scoped grant for the machine-bound Agent;
  # the Host then opens its existing native PORT_FORWARD listener, rather than
  # receiving a separate Agent data channel or a reusable bearer credential.
  agent_service_id="$(json_post /api/v1/tunnel/services "$(jq -cn --arg tenant "$tenant_id" --arg publisher "$host_uid" '{tenantId:$tenant,publishingDeviceUid:$publisher,name:"native-agent-execution",protocol:"tcp",localAddr:"127.0.0.1:24079"}')" | jq -er '.id')"
  json_post /api/v1/tunnel/routes "$(jq -cn --arg tenant "$tenant_id" --arg access "$host_uid" --arg service "$agent_service_id" '{tenantId:$tenant,accessDeviceUid:$access,serviceId:$service}')" >/dev/null
  agent_run="$(json_post /v1/orchestrator/submit "$(jq -cn --arg machine "$agent_machine_id" --arg prompt "$agent_prompt" --arg service "$agent_service_id" '{title:"Native RustDesk Host Agent E2E",tasks:[{provider:"codex",prompt:$prompt,target:{type:"machine_id",machineId:$machine},tunnelAccess:{serviceId:$service,required:true,ttlSeconds:60,maxConnections:1,maxBytes:1048576,relayNodeId:"native-e2e"}}]}')" | jq -er '.data.runId')"
  for _ in {1..150}; do
    agent_state="$(curl --silent --show-error --fail --header "authorization: Bearer $bearer" "$api/v1/orchestrator/runs/$agent_run?includeExecutions=true")"
    [[ "$(jq -r '.data.status' <<<"$agent_state")" == completed ]] && break
    sleep 0.2
  done
  [[ "$(jq -r '.data.status' <<<"$agent_state")" == completed ]] || { echo 'RustDesk Host Agent dispatch did not complete' >&2; jq . <<<"$agent_state" >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  [[ -f "$agent_payload_file" ]] || { echo 'RustDesk Host Agent execution did not consume the native tunnel capability' >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  agent_audit="$(curl --silent --show-error --fail --header "authorization: Bearer $bearer" "$api/v1/orchestrator/audit")"
  jq -e 'map(.action) | index("submitted") and index("started") and index("finished")' >/dev/null <<<"$agent_audit"
  ! grep -Fq "$agent_prompt" <<<"$agent_audit"
  grep -q '^NEXUS_E2E_AGENT_NATIVE_TUNNEL_READY$' "$TARGET_ROOT/logs/host.log"
  echo '[native-e2e] Control Plane TLS Socket to RustDesk Host Agent execution-native-tunnel lifecycle passed'

  agent_retry_run="$(json_post /v1/orchestrator/submit "$(jq -cn --arg machine "$agent_machine_id" --arg service "$agent_service_id" '{title:"Native RustDesk Host Agent retry E2E",tasks:[{provider:"codex",prompt:"native-rustdesk-host-agent-retry",target:{type:"machine_id",machineId:$machine},retry:{maxAttempts:2,backoffMs:0},tunnelAccess:{serviceId:$service,required:true,ttlSeconds:60,maxConnections:1,maxBytes:1048576,relayNodeId:"native-e2e"}}]}')" | jq -er '.data.runId')"
  for _ in {1..50}; do
    agent_retry_state="$(curl --silent --show-error --fail --header "authorization: Bearer $bearer" "$api/v1/orchestrator/runs/$agent_retry_run?includeExecutions=true")"
    [[ "$(jq -r '.data.status' <<<"$agent_retry_state")" == completed ]] && break
    sleep 0.2
  done
  [[ "$(jq -r '.data.status' <<<"$agent_retry_state")" == completed ]] || { echo 'RustDesk Host Agent retry did not complete' >&2; jq . <<<"$agent_retry_state" >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  jq -e '.data.tasks[0].executions | length == 2 and .[0].status == "failed" and .[1].status == "completed" and .[0].executionId != .[1].executionId' >/dev/null <<<"$agent_retry_state"
  echo '[native-e2e] Host Agent execution retry issued a fresh native-tunnel grant'

  agent_cancel_run="$(json_post /v1/orchestrator/submit "$(jq -cn --arg machine "$agent_machine_id" --arg service "$agent_service_id" '{title:"Native RustDesk Host Agent cancel E2E",tasks:[{provider:"codex",prompt:"native-rustdesk-host-agent-cancel",target:{type:"machine_id",machineId:$machine},tunnelAccess:{serviceId:$service,required:true,ttlSeconds:60,maxConnections:1,maxBytes:1048576,relayNodeId:"native-e2e"}}]}')" | jq -er '.data.runId')"
  for _ in {1..50}; do [[ -f "$agent_cancel_file" ]] && break; sleep 0.2; done
  [[ -f "$agent_cancel_file" ]] || { echo 'RustDesk Host Agent cancel execution did not reach the native tunnel' >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  json_post "/v1/orchestrator/runs/$agent_cancel_run/cancel" '{}' >/dev/null
  for _ in {1..50}; do
    agent_cancel_state="$(curl --silent --show-error --fail --header "authorization: Bearer $bearer" "$api/v1/orchestrator/runs/$agent_cancel_run?includeExecutions=true")"
    [[ "$(jq -r '.data.status' <<<"$agent_cancel_state")" == cancelled ]] && break
    sleep 0.2
  done
  [[ "$(jq -r '.data.status' <<<"$agent_cancel_state")" == cancelled ]] || { echo 'RustDesk Host Agent cancellation did not converge' >&2; tail -n 120 "$TARGET_ROOT/logs/host.log" >&2; exit 1; }
  jq -e '.data.tasks[0].executions[0].status == "cancelled"' >/dev/null <<<"$agent_cancel_state"
  echo '[native-e2e] Host Agent execution cancellation revoked the native tunnel'
  if [[ "$MATRIX" == authi ]]; then
    echo '[native-e2e] Authi Host Agent lifecycle passed'
    exit 0
  fi
  # RustDesk's native registration loop uses the existing 15-second cadence.
  # Wait through its first full cycle instead of racing hbbs peer discovery.
  sleep 16

  # Each service receives a separate one-shot native context and listener.
  # This keeps the HTTP(S) checks from consuming the TCP fixture's grant.
  start_gateway() {
    local name="$1" credential="$2" grant="$3" port="$4" log="$TARGET_ROOT/logs/gateway-$1.log" local_home="$TARGET_ROOT/gateway-home-$1"
    local identity_config identity_dir
    mkdir -p "$local_home"
    identity_config="$(for file in $(find "$gateway_home/config" -type f -name 'RustDesk-*.toml'); do grep -q '^key_pair = ' "$file" && stat -c '%Y %n' "$file"; done | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$identity_config" ]] || { echo 'Gateway identity config was not persisted' >&2; return 1; }
    identity_dir="$(dirname "$identity_config")"
    mkdir -p "$local_home/config/$(basename "$identity_dir")"
    cp "$identity_dir"/RustDesk-*.toml "$local_home/config/$(basename "$identity_dir")/"
    # Each Gateway is a separate RustDesk process. Keep the copied identity
    # (the control-plane device is intentionally shared), but isolate the
    # native Unix IPC namespace so concurrent processes cannot reset each
    # other's connection manager.
    if [[ "$GATEWAY_FORCE_RELAY" != Y ]]; then
      # Reusing a target root across transport runs must not leak the relay
      # preference persisted by the previous relay matrix.
      sed -i "s/^force-always-relay = 'Y'/force-always-relay = 'N'/" \
        "$local_home/config/$(basename "$identity_dir")/$(basename "${identity_config%.toml}2.toml")" 2>/dev/null || true
    fi
    (cd "$local_home" && HOME="$local_home" XDG_CONFIG_HOME="$local_home/config" NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_IPC_NAMESPACE="$name" NEXUS_E2E_RENDEZVOUS_KEY="$rendezvous_key" NEXUS_E2E_FORCE_RELAY="$GATEWAY_FORCE_RELAY" NEXUS_E2E_FORCE_KCP="$([[ "$TRANSPORT" == kcp ]] && echo 1 || echo 0)" NEXUS_E2E_TRACE_PORT_FORWARD=1 NEXUS_TUNNEL_CREDENTIAL_FILE="$credential" NEXUS_GATEWAY_PEER_ID="$host_id" NEXUS_GATEWAY_DEVICE_UID="$gateway_uid" NEXUS_GATEWAY_CONTROL_PLANE_URL="$api" NEXUS_GATEWAY_GRANT_ID="$grant" NEXUS_GATEWAY_RENDEZVOUS_SERVER="$RUSTDESK_BIND_ADDR:23116" NEXUS_GATEWAY_BIND="127.0.0.1:$port" "$GATEWAY_BIN") >"$log" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    GATEWAY_PIDS+=("$pid")
    for _ in {1..75}; do grep -q "listening on port 127.0.0.1:$port" "$log" && return 0; sleep 0.2; done
    tail -n 40 "$log" >&2
    return 1
  }

  # This fixture intentionally carries no Nexus credential or grant. It uses
  # the upstream PortForward branch in a sibling process, while the Remote
  # smoke below uses DEFAULT_CONN. Both are E2E-only binary modes.
  start_legacy_gateway() {
    local port="$1" log="$TARGET_ROOT/logs/gateway-legacy.log" local_home="$TARGET_ROOT/gateway-home-legacy"
    local identity_config identity_dir
    mkdir -p "$local_home"
    identity_config="$(for file in $(find "$gateway_home/config" -type f -name 'RustDesk-*.toml'); do grep -q '^key_pair = ' "$file" && stat -c '%Y %n' "$file"; done | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$identity_config" ]] || { echo 'Gateway identity config was not persisted' >&2; return 1; }
    identity_dir="$(dirname "$identity_config")"
    mkdir -p "$local_home/config/$(basename "$identity_dir")"
    cp "$identity_dir"/RustDesk-*.toml "$local_home/config/$(basename "$identity_dir")/"
    if [[ "$GATEWAY_FORCE_RELAY" != Y ]]; then
      sed -i "s/^force-always-relay = 'Y'/force-always-relay = 'N'/" \
        "$local_home/config/$(basename "$identity_dir")/$(basename "${identity_config%.toml}2.toml")" 2>/dev/null || true
    fi
    (cd "$local_home" && HOME="$local_home" XDG_CONFIG_HOME="$local_home/config" NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_IPC_NAMESPACE=legacy NEXUS_E2E_LEGACY_PORT_FORWARD=1 NEXUS_E2E_LEGACY_PASSWORD="$legacy_password" NEXUS_E2E_PEER_ID="$host_id" NEXUS_E2E_BIND="127.0.0.1:$port" NEXUS_E2E_LEGACY_TARGET=127.0.0.1:24080 NEXUS_E2E_RENDEZVOUS_KEY="$rendezvous_key" NEXUS_E2E_FORCE_RELAY="$GATEWAY_FORCE_RELAY" NEXUS_E2E_RENDEZVOUS_SERVER="$RUSTDESK_BIND_ADDR:23116" "$GATEWAY_BIN") >"$log" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    GATEWAY_PIDS+=("$pid")
    for _ in {1..75}; do grep -q "listening on port 127.0.0.1:$port" "$log" && return 0; sleep 0.2; done
    tail -n 40 "$log" >&2
    return 1
  }

  start_remote_smoke() {
    local log="$TARGET_ROOT/logs/remote-smoke.log" local_home="$TARGET_ROOT/remote-home"
    mkdir -p "$local_home"
    (cd "$local_home" && HOME="$local_home" XDG_CONFIG_HOME="$local_home/config" NEXUS_E2E_APP_NAME="$NEXUS_E2E_APP_NAME" NEXUS_E2E_IPC_NAMESPACE=remote NEXUS_E2E_REMOTE_SMOKE=1 NEXUS_E2E_PEER_ID="$host_id" NEXUS_E2E_RENDEZVOUS_KEY="$rendezvous_key" NEXUS_E2E_FORCE_RELAY="$GATEWAY_FORCE_RELAY" NEXUS_E2E_RENDEZVOUS_SERVER="$RUSTDESK_BIND_ADDR:23116" "$GATEWAY_BIN") >"$log" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    GATEWAY_PIDS+=("$pid")
    for _ in {1..75}; do grep -q '^NEXUS_E2E_REMOTE_CONNECTED$' "$log" && return 0; sleep 0.2; done
    tail -n 40 "$log" >&2
    return 1
  }

  create_grant_for_service() {
    local name="$1" protocol="$2" local_addr="$3" virtual_host="${4:-}" service_id grant_id
    local max_connections=1
    [[ "$name" == native-concurrent ]] && max_connections=3
    local service_body
    service_body="$(jq -cn --arg tenant "$tenant_id" --arg publisher "$host_uid" --arg name "$name" --arg protocol "$protocol" --arg localAddr "$local_addr" --arg virtualHost "$virtual_host" '{tenantId:$tenant,publishingDeviceUid:$publisher,name:$name,protocol:$protocol,localAddr:$localAddr} + (if $virtualHost == "" then {} else {virtualHost:$virtualHost} end)')"
    service_id="$(json_post /api/v1/tunnel/services "$service_body" | jq -er '.id')" || return 1
    json_post /api/v1/tunnel/routes "$(jq -cn --arg tenant "$tenant_id" --arg access "$gateway_uid" --arg service "$service_id" '{tenantId:$tenant,accessDeviceUid:$access,serviceId:$service}')" >/dev/null || return 1
    grant_id="$(json_post /api/v1/tunnel/access-grants "$(jq -cn --arg tenant "$tenant_id" --arg source "$gateway_uid" --arg service "$service_id" --argjson maxConnections "$max_connections" '{tenantId:$tenant,sourceDeviceUid:$source,relayNodeId:"native-e2e",serviceId:$service,ttlSeconds:600,maxConnections:$maxConnections,maxBytes:1048576}')" | jq -er '.id')" || return 1
    [[ "$grant_id" =~ ^[[:alnum:]-]+$ ]] || return 1
    printf '%s\n' "$grant_id"
  }

  # A tiny local TCP echo service stands in for the published private service.
  python3 -u -c $'import socket, threading\ns=socket.socket()\ns.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)\ns.bind(("127.0.0.1",24080))\ns.listen()\ndef serve(c):\n    while data := c.recv(65536): c.sendall(data)\n    c.close()\nwhile True:\n    c,_=s.accept()\n    threading.Thread(target=serve, args=(c,), daemon=True).start()' >"$TARGET_ROOT/logs/private-echo.log" 2>&1 & PIDS+=("$!")
  grant_id="$(create_grant_for_service native-echo tcp 127.0.0.1:24080)"
  start_gateway tcp "$credential_path" "$grant_id" 24081
  payload_ok=1
  for _ in {1..5}; do
    if python3 -c $'import socket\ns=socket.create_connection(("127.0.0.1", 24081), 10)\ns.sendall(b"native-port-forward-e2e")\nassert s.recv(65536) == b"native-port-forward-e2e"\ns.close()'; then
      payload_ok=0
      break
    fi
    sleep 1
  done
  [[ "$payload_ok" == 0 ]]
  if [[ "$TRANSPORT" == kcp ]]; then
    grep -q 'used to establish UDP connection' "$TARGET_ROOT/logs/gateway-tcp.log" || {
      echo 'KCP matrix did not establish the native UDP stream' >&2
      tail -n 80 "$TARGET_ROOT/logs/gateway-tcp.log" >&2
      exit 1
    }
    echo "[native-e2e] KCP native PortForward E2E passed"
  fi
  usage_ok=1
  for _ in {1..20}; do
    usage_json="$(curl --silent --show-error --fail --header "authorization: Bearer $bearer" "$api/api/v1/tunnel/access-grants/$grant_id")"
    if jq -e '(.usedBytes // 0) > 0 and (.activeConnections // 1) == 0' >/dev/null <<<"$usage_json"; then
      usage_ok=0
      break
    fi
    sleep 0.2
  done
  [[ "$usage_ok" == 0 ]]
  echo "[native-e2e] full native PortForward E2E passed"
  stop_gateways

  start_legacy_gateway 24091
  start_remote_smoke
  # Let the host finish the native DEFAULT_CONN authentication before the two
  # PortForward callers concurrently create their own connection managers.
  # This is fixture ordering only; the two forwarding sockets below overlap.
  sleep 2
  mixed_grant="$(create_grant_for_service native-mixed tcp 127.0.0.1:24080)"
  start_gateway mixed-nexus "$TARGET_ROOT/gateway-mixed-credential.json" "$mixed_grant" 24092
  python3 - <<'PY'
import socket
import threading

ports = (24091, 24092)
errors = []

def exercise(port):
    payload = f"mixed-{port}".encode()
    try:
        with socket.create_connection(("127.0.0.1", port), 10) as sock:
            sock.sendall(payload)
            if sock.recv(65536) != payload:
                raise AssertionError(f"port {port} returned the wrong payload")
    except Exception as error:
        errors.append(str(error))

threads = [threading.Thread(target=exercise, args=(port,)) for port in ports]
for thread in threads: thread.start()
for thread in threads: thread.join()
if errors: raise SystemExit('; '.join(errors))
PY
  grep -q '^NEXUS_E2E_REMOTE_CONNECTED$' "$TARGET_ROOT/logs/remote-smoke.log"
  echo "[native-e2e] Remote + legacy + Nexus concurrent session smoke passed"
  stop_gateways

  concurrent_ports=(24088 24089 24090)
  concurrent_grants=()
  for i in 0 1 2; do
    concurrent_grants+=("$(create_grant_for_service "native-concurrent-$i" tcp 127.0.0.1:24080)")
    start_gateway "concurrent-$i" "$TARGET_ROOT/gateway-concurrent-$i-credential.json" "${concurrent_grants[$i]}" "${concurrent_ports[$i]}"
  done
  python3 - "${concurrent_ports[@]}" <<'PY'
import socket
import sys
import threading

ports = [int(value) for value in sys.argv[1:]]
errors = []

def exercise(index, port):
    payload = f"native-concurrent-{index}".encode()
    try:
        with socket.create_connection(("127.0.0.1", port), 10) as sock:
            sock.sendall(payload)
            received = sock.recv(65536)
            if received != payload:
                raise AssertionError(f"port {port}: {received!r}")
    except Exception as error:
        errors.append(str(error))

threads = [threading.Thread(target=exercise, args=(index, port)) for index, port in enumerate(ports)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
if errors:
    raise SystemExit("; ".join(errors))
PY
  echo "[native-e2e] concurrent Nexus PortForward sessions passed"
  stop_gateways

  python3 -u -c $'import socket, time\ns=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 24082)); s.listen(); print("LISTENING 127.0.0.1:24082", flush=True)\nwhile True:\n c,addr=s.accept(); print(f"REQUEST {addr}", flush=True); c.settimeout(2); c.recv(65536); c.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: 15\\r\\nConnection: close\\r\\n\\r\\nnative-http-e2e"); c.setblocking(False); time.sleep(2); c.close()' >"$TARGET_ROOT/logs/private-http.log" 2>&1 & PIDS+=("$!")
  for _ in {1..50}; do grep -q '^LISTENING ' "$TARGET_ROOT/logs/private-http.log" && break; sleep 0.1; done
  grep -q '^LISTENING ' "$TARGET_ROOT/logs/private-http.log" || { echo 'private HTTP fixture did not become ready' >&2; cat "$TARGET_ROOT/logs/private-http.log" >&2; exit 1; }
  http_grant="$(create_grant_for_service native-http http 127.0.0.1:24082 native-http.test)"
  start_gateway http "$TARGET_ROOT/gateway-http-credential.json" "$http_grant" 24083
  http_ok=1
  for _ in {1..5}; do
    if python3 -c $'import socket, time\ns=socket.create_connection(("127.0.0.1", 24083), 10); s.settimeout(1)\ns.sendall(b"GET / HTTP/1.1\\r\\nHost: native-http.test\\r\\nConnection: close\\r\\n\\r\\n")\ndata=b""; deadline=time.monotonic()+10\nwhile b"native-http-e2e" not in data and time.monotonic() < deadline:\n    try: data += s.recv(65536)\n    except socket.timeout: pass\nassert b"native-http-e2e" in data\ns.close()'; then
      http_ok=0
      break
    fi
    sleep 1
  done
  [[ "$http_ok" == 0 ]]
  echo "[native-e2e] HTTP native PortForward E2E passed"
  stop_gateways

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TARGET_ROOT/tls.key" -out "$TARGET_ROOT/tls.crt" -days 1 -subj '/CN=native-https.test' >/dev/null 2>&1
  TLS_CERT="$TARGET_ROOT/tls.crt" TLS_KEY="$TARGET_ROOT/tls.key" python3 -u -c $'import os, socketserver, ssl, traceback\ncontext=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(os.environ["TLS_CERT"], os.environ["TLS_KEY"])\nclass Handler(socketserver.BaseRequestHandler):\n    def handle(self):\n        print("ACCEPT", flush=True)\n        try:\n            with context.wrap_socket(self.request, server_side=True) as c:\n                print("HANDSHAKE", flush=True); c.settimeout(5); c.recv(65536); c.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: 17\\r\\nConnection: close\\r\\n\\r\\nnative-https-e2e")\n        except Exception:\n            traceback.print_exc()\nclass Server(socketserver.ThreadingTCPServer):\n    allow_reuse_address=True\nServer(("127.0.0.1", 24084), Handler).serve_forever()' >"$TARGET_ROOT/logs/private-https.log" 2>&1 & PIDS+=("$!")
  for _ in {1..50}; do
    openssl s_client -connect 127.0.0.1:24084 -servername native-https.test </dev/null >/dev/null 2>&1 && break
    sleep 0.1
  done
  openssl s_client -connect 127.0.0.1:24084 -servername native-https.test </dev/null >/dev/null 2>&1
  https_grant="$(create_grant_for_service native-https https 127.0.0.1:24084 native-https.test)"
  start_gateway https "$TARGET_ROOT/gateway-https-credential.json" "$https_grant" 24085
  https_ok=1
  for _ in {1..5}; do
    if python3 -c $'import socket, ssl, time\ncontext=ssl.create_default_context(); context.check_hostname=False; context.verify_mode=ssl.CERT_NONE\nwith context.wrap_socket(socket.create_connection(("127.0.0.1", 24085), 10), server_hostname="native-https.test") as s:\n    s.settimeout(1); s.sendall(b"GET / HTTP/1.1\\r\\nHost: native-https.test\\r\\nConnection: close\\r\\n\\r\\n")\n    data=b""; deadline=time.monotonic()+10\n    while b"native-https-e2e" not in data and time.monotonic() < deadline:\n        try: data += s.recv(65536)\n        except socket.timeout: pass\n    assert b"native-https-e2e" in data'; then
      https_ok=0
      break
    fi
    sleep 1
  done
  [[ "$https_ok" == 0 ]]
  echo "[native-e2e] HTTPS TLS-passthrough native PortForward E2E passed"
  stop_gateways

  live_revoke_grant="$(create_grant_for_service native-live-revoke tcp 127.0.0.1:24080)"
  start_gateway live-revoke "$TARGET_ROOT/gateway-live-revoke-credential.json" "$live_revoke_grant" 24086
  python3 -u -c $'import socket\ns=socket.create_connection(("127.0.0.1", 24086), 10)\ns.sendall(b"native-live-revoke")\nassert s.recv(65536) == b"native-live-revoke"\nprint("connected", flush=True)\nassert s.recv(1) == b""\nprint("closed", flush=True)' >"$TARGET_ROOT/logs/live-revoke-client.log" 2>&1 & PIDS+=("$!")
  for _ in {1..50}; do grep -q '^connected$' "$TARGET_ROOT/logs/live-revoke-client.log" && break; sleep 0.2; done
  grep -q '^connected$' "$TARGET_ROOT/logs/live-revoke-client.log"
  curl --silent --show-error --fail -X POST --header "authorization: Bearer $bearer" "$api/api/v1/tunnel/access-grants/$live_revoke_grant/revoke?tenantId=$tenant_id" >/dev/null
  for _ in {1..50}; do grep -q '^closed$' "$TARGET_ROOT/logs/live-revoke-client.log" && break; sleep 0.2; done
  grep -q '^closed$' "$TARGET_ROOT/logs/live-revoke-client.log"
  echo "[native-e2e] revoked grant closed an established native session"
  stop_gateways

  revoked_grant="$(create_grant_for_service native-revoked tcp 127.0.0.1:24080)"
  curl --silent --show-error --fail -X POST --header "authorization: Bearer $bearer" "$api/api/v1/tunnel/access-grants/$revoked_grant/revoke?tenantId=$tenant_id" >/dev/null
  if start_gateway revoked "$TARGET_ROOT/gateway-revoked-credential.json" "$revoked_grant" 24087; then
    echo 'revoked grant unexpectedly opened a native Gateway listener' >&2
    exit 1
  fi
  echo "[native-e2e] revoked grant rejected before native listener startup"
  stop_gateways
fi

utc_finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg result passed \
  --arg matrix "$MATRIX" \
  --arg transport "$TRANSPORT" \
  --arg finished_at "$utc_finished_at" \
  --arg target_root "$TARGET_ROOT" \
  '{result:$result,matrix:$matrix,transport:$transport,finishedAt:$finished_at,targetRoot:$target_root,logs:[($target_root + "/logs/control-plane.log"),($target_root + "/logs/hbbs.log"),($target_root + "/logs/hbbr.log")]}' \
  >"$TARGET_ROOT/result.json"
echo "[native-e2e] smoke passed; logs and pid scope: $TARGET_ROOT"
