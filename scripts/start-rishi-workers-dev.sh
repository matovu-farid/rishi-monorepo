#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIMARY_PORT="${RISHI_PRIMARY_WORKER_PORT:-8787}"
SHARING_PORT="${RISHI_SHARING_WORKER_PORT:-8788}"
STATE_DIR="${RISHI_WORKER_DEV_STATE_DIR:-$REPO_ROOT/.wrangler/rishi-workers-dev}"
PRIMARY_CONFIG="$REPO_ROOT/workers/worker/wrangler.dev.jsonc"
SHARING_CONFIG="$REPO_ROOT/workers/sharing-worker/wrangler.dev.jsonc"
REMOTE=0
PRIMARY_PID=""
SHARING_PID=""
CLEANING_UP=0

usage() {
  cat <<'EOF'
Usage: scripts/start-rishi-workers-dev.sh [--remote --primary-config PATH --sharing-config PATH]

Starts the primary and shared-reading Workers on ports 8787 and 8788, waits
for both health checks, and owns their lifetime until interrupted.

Remote mode is opt-in and requires explicit non-production Wrangler configs.
EOF
}

fail() {
  echo "rishi workers dev: $*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --remote)
      REMOTE=1
      shift
      ;;
    --primary-config)
      (($# >= 2)) || fail "--primary-config requires a path"
      PRIMARY_CONFIG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    --sharing-config)
      (($# >= 2)) || fail "--sharing-config requires a path"
      SHARING_CONFIG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$PRIMARY_CONFIG" ]] || fail "primary config does not exist: $PRIMARY_CONFIG"
[[ -f "$SHARING_CONFIG" ]] || fail "sharing config does not exist: $SHARING_CONFIG"

if ((REMOTE == 1)); then
  [[ "$PRIMARY_CONFIG" != "$REPO_ROOT/workers/worker/wrangler.dev.jsonc" ]] || fail "--remote requires an explicit non-production primary config"
  [[ "$SHARING_CONFIG" != "$REPO_ROOT/workers/sharing-worker/wrangler.dev.jsonc" ]] || fail "--remote requires an explicit non-production sharing config"
fi

for config in "$PRIMARY_CONFIG" "$SHARING_CONFIG"; do
  if rg -q 'api\.fidexa\.org|sharing\.fidexa\.org|970159b7-ca91-49c1-bae8-feb43b24a7e6|"remote"[[:space:]]*:[[:space:]]*true' "$config"; then
    fail "config contains a production domain, production D1 id, or remote binding: $config"
  fi
done

mkdir -p "$STATE_DIR/logs"

port_pid() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true
}

stop_recorded_process() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 0
  local pid
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pid_file"; return 0; }
  local command_line
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *"wrangler dev"* ]] || { rm -f "$pid_file"; return 0; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$pid_file"
}

existing_primary="$(port_pid "$PRIMARY_PORT")"
existing_sharing="$(port_pid "$SHARING_PORT")"
if [[ -n "$existing_primary" || -n "$existing_sharing" ]]; then
  stop_recorded_process "$STATE_DIR/primary.pid"
  stop_recorded_process "$STATE_DIR/sharing.pid"
  existing_primary="$(port_pid "$PRIMARY_PORT")"
  existing_sharing="$(port_pid "$SHARING_PORT")"
  [[ -z "$existing_primary" ]] || fail "port $PRIMARY_PORT is already owned by PID $existing_primary; close it before retrying"
  [[ -z "$existing_sharing" ]] || fail "port $SHARING_PORT is already owned by PID $existing_sharing; close it before retrying"
fi

cleanup() {
  ((CLEANING_UP == 1)) && return 0
  CLEANING_UP=1
  for pid in "$PRIMARY_PID" "$SHARING_PID"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$PRIMARY_PID" "$SHARING_PID"; do
    [[ -n "$pid" ]] || continue
    wait "$pid" 2>/dev/null || true
  done
  rm -f "$STATE_DIR/primary.pid" "$STATE_DIR/sharing.pid"
}
trap cleanup EXIT INT TERM

if ((REMOTE == 1)); then
  (
    cd "$REPO_ROOT/workers/sharing-worker"
    exec bunx wrangler dev --config "$SHARING_CONFIG" --port "$SHARING_PORT" --ip 127.0.0.1 --remote
  ) >"$STATE_DIR/logs/sharing.log" 2>&1 &
else
  (
    cd "$REPO_ROOT/workers/sharing-worker"
    exec bunx wrangler dev --config "$SHARING_CONFIG" --port "$SHARING_PORT" --ip 127.0.0.1
  ) >"$STATE_DIR/logs/sharing.log" 2>&1 &
fi
SHARING_PID=$!
echo "$SHARING_PID" >"$STATE_DIR/sharing.pid"

wait_for_health() {
  local name="$1"
  local url="$2"
  for _ in {1..120}; do
    if curl --silent --show-error --fail --max-time 1 "$url" >/dev/null 2>&1; then
      echo "rishi workers dev: $name healthy at $url"
      return 0
    fi
    sleep 0.25
  done
  echo "rishi workers dev: $name failed health check; see $STATE_DIR/logs/$name.log" >&2
  return 1
}

wait_for_health sharing "http://127.0.0.1:$SHARING_PORT/health"

if ((REMOTE == 1)); then
  (
    cd "$REPO_ROOT/workers/worker"
    exec bunx wrangler dev --config "$PRIMARY_CONFIG" --port "$PRIMARY_PORT" --ip 127.0.0.1 --remote
  ) >"$STATE_DIR/logs/primary.log" 2>&1 &
else
  (
    cd "$REPO_ROOT/workers/worker"
    exec bunx wrangler dev --config "$PRIMARY_CONFIG" --port "$PRIMARY_PORT" --ip 127.0.0.1
  ) >"$STATE_DIR/logs/primary.log" 2>&1 &
fi
PRIMARY_PID=$!
echo "$PRIMARY_PID" >"$STATE_DIR/primary.pid"

wait_for_health primary "http://127.0.0.1:$PRIMARY_PORT/health"

echo "rishi workers dev: primary PID=$PRIMARY_PID http://127.0.0.1:$PRIMARY_PORT"
echo "rishi workers dev: sharing PID=$SHARING_PID ws://127.0.0.1:$SHARING_PORT"
echo "rishi workers dev: logs=$STATE_DIR/logs"
echo "rishi workers dev: press Ctrl-C to stop both Workers"

wait "$PRIMARY_PID"
