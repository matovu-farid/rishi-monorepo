#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEVELOPER_DIR="${RISHI_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
SIMCTL="$DEVELOPER_DIR/usr/bin/simctl"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
UDID="${RISHI_SIMULATOR_UDID:-}"
OUTPUT="${RISHI_SIMULATOR_OUTPUT:-/private/tmp/rishi-iphone-simulator.png}"
WAIT_SECONDS="${RISHI_SIMULATOR_WAIT_SECONDS:-8}"
RECORD_SECONDS="${RISHI_RECORD_SECONDS:-0}"
RECORD_PID=""
BUILD_LOCK="${RISHI_APPLE_XCODE_BUILD_LOCK_PATH:-/private/tmp/rishi-apple-xcode-build.lock}"
BUILD_LOCK_TOKEN=""
BUILD_ROOT=""
LOCK_ACQUIRED=0
fail() { printf 'capture_simulator.sh: %s\n' "$1" >&2; exit 1; }
[[ -x "$SIMCTL" ]] || fail "simctl not found under $DEVELOPER_DIR"
[[ -x "$XCODEBUILD" ]] || fail "xcodebuild not found under $DEVELOPER_DIR"

minimum_gigabytes() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value > fallback )); then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

require_resources() {
  local min_disk_gb min_memory_gb disk_kb min_disk_kb vm page_size pages memory_bytes
  min_disk_gb="$(minimum_gigabytes "${RISHI_E2E_MIN_FREE_DISK_GB:-}" 20)"
  min_memory_gb="$(minimum_gigabytes "${RISHI_E2E_MIN_FREE_MEMORY_GB:-}" 6)"
  disk_kb="$(df -Pk / | awk 'NR == 2 { print $4 }')"
  min_disk_kb=$((min_disk_gb * 1024 * 1024))
  [[ "$disk_kb" =~ ^[0-9]+$ ]] || fail "could not determine free disk"
  (( disk_kb >= min_disk_kb )) || fail "insufficient free disk: ${disk_kb} KiB available, ${min_disk_kb} KiB required"

  vm="$(vm_stat 2>/dev/null)" || fail "could not inspect available memory"
  page_size="$(printf '%s\n' "$vm" | awk '/page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { print $(i + 1); exit } }')"
  pages="$(printf '%s\n' "$vm" | awk -F: '/Pages (free|inactive|speculative):/ { gsub(/[^0-9]/, "", $2); total += $2 } END { print total + 0 }')"
  [[ "$page_size" =~ ^[0-9]+$ && "$pages" =~ ^[0-9]+$ ]] || fail "could not parse available memory"
  memory_bytes=$((pages * page_size))
  (( memory_bytes >= min_memory_gb * 1024 * 1024 * 1024 )) || fail "insufficient available memory: ${memory_bytes} bytes available"
}

cleanup() {
  if [[ -n "$RECORD_PID" ]]; then
    kill -INT "$RECORD_PID" 2>/dev/null || true
    wait "$RECORD_PID" 2>/dev/null || true
  fi
  if [[ -n "$BUILD_ROOT" ]]; then
    rm -rf -- "$BUILD_ROOT"
  fi
  if (( LOCK_ACQUIRED == 1 )); then
    current_token="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$BUILD_LOCK/owner.json" 2>/dev/null || true)"
    if [[ -n "$BUILD_LOCK_TOKEN" && "$current_token" == "$BUILD_LOCK_TOKEN" ]]; then
      rm -f -- "$BUILD_LOCK/owner.json"
      rmdir -- "$BUILD_LOCK" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT INT TERM

require_resources
if ! mkdir -- "$BUILD_LOCK" 2>/dev/null; then
  fail "another Apple build is using the shared build lock: $BUILD_LOCK"
fi
LOCK_ACQUIRED=1
BUILD_LOCK_TOKEN="$(/usr/bin/python3 -c 'import uuid; print(uuid.uuid4())')"
printf '{"pid":%s,"token":"%s"}\n' "$$" "$BUILD_LOCK_TOKEN" > "$BUILD_LOCK/owner.json"

cleanup_stale_builds() {
  local dir pid command
  while IFS= read -r -d '' dir; do
    pid=""
    [[ -f "$dir/.rishi-active.pid" ]] && pid="$(<"$dir/.rishi-active.pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$command" == *capture_simulator.sh* ]] && continue
      # If process inspection is denied, do not guess that a live build is
      # stale merely because its directory is old.
      [[ -z "$command" ]] && continue
    fi
    rm -rf -- "$dir"
  done < <(find /private/tmp -maxdepth 1 -type d -name 'rishi-iphone-preview-xcode.*' -mmin +120 -print0)
}
cleanup_stale_builds

if [[ -z "$UDID" ]]; then
  DEVICES_JSON="$("$SIMCTL" list devices available --json 2>&1)" || fail "$DEVICES_JSON"
  UDID="$(printf '%s' "$DEVICES_JSON" | /usr/bin/python3 -c 'import json,sys
data=json.load(sys.stdin)
for runtime in data.get("devices", {}).values():
    for device in runtime:
        if device.get("isAvailable") and device.get("name") == "iPhone 17 Pro":
            print(device["udid"])
            raise SystemExit
')"
fi
[[ -n "$UDID" ]] || fail "no available iPhone 17 Pro; set RISHI_SIMULATOR_UDID"

BUILD_ROOT="$(mktemp -d /private/tmp/rishi-iphone-preview-xcode.XXXXXX)"
printf '%s\n' "$$" > "$BUILD_ROOT/.rishi-active.pid"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
SOURCE_PACKAGES="$BUILD_ROOT/SourcePackages"

XCODE_ARGS=(
  -project "$SCRIPT_DIR/../../rishi/rishi.xcodeproj"
  -scheme rishi
  -configuration Debug
  -destination "platform=iOS Simulator,id=$UDID"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
)
"$XCODEBUILD" -resolvePackageDependencies "${XCODE_ARGS[@]}"
# Package resolution can consume substantial memory and disk space. Recheck
# before the compiled build so a successful resolve cannot push the machine
# into a resource-starved build.
require_resources
"$XCODEBUILD" build "${XCODE_ARGS[@]}"
require_resources
"$SIMCTL" boot "$UDID" 2>/dev/null || true
"$SIMCTL" bootstatus "$UDID" -b
APP_PATH="$(find "$DERIVED_DATA/Build/Products" -type d -name 'rishi.app' -print -quit)"
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "built rishi.app not found"
"$SIMCTL" install "$UDID" "$APP_PATH"
SIMCTL_CHILD_RISHI_UITEST=1 "$SIMCTL" launch "$UDID" org.fidexa.rishi >/dev/null
sleep "$WAIT_SECONDS"
mkdir -p "$(dirname "$OUTPUT")"
"$SIMCTL" io "$UDID" screenshot "$OUTPUT"

if [[ "$RECORD_SECONDS" != "0" ]]; then
  VIDEO_OUTPUT="${RISHI_SIMULATOR_VIDEO:-/private/tmp/rishi-iphone-simulator.mov}"
  "$SIMCTL" io "$UDID" recordVideo --codec=h264 "$VIDEO_OUTPUT" &
  RECORD_PID=$!
  sleep "$RECORD_SECONDS"
  kill -INT "$RECORD_PID" 2>/dev/null || true
  wait "$RECORD_PID" 2>/dev/null || true
  RECORD_PID=""
  printf 'video=%s\n' "$VIDEO_OUTPUT"
fi
printf 'screenshot=%s\n' "$OUTPUT"
