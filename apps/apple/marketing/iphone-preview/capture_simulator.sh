#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEVELOPER_DIR="${RISHI_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
SIMCTL="$DEVELOPER_DIR/usr/bin/simctl"
XCODEBUILD="$(command -v xcodebuild || true)"
UDID="${RISHI_SIMULATOR_UDID:-}"
OUTPUT="${RISHI_SIMULATOR_OUTPUT:-/private/tmp/rishi-iphone-simulator.png}"
WAIT_SECONDS="${RISHI_SIMULATOR_WAIT_SECONDS:-8}"
RECORD_SECONDS="${RISHI_RECORD_SECONDS:-0}"
RECORD_PID=""
fail() { printf 'capture_simulator.sh: %s\n' "$1" >&2; exit 1; }
[[ -x "$SIMCTL" ]] || fail "simctl not found under $DEVELOPER_DIR"
[[ -n "$XCODEBUILD" ]] || fail "xcodebuild is not available"

cleanup_stale_builds() {
  local dir pid command
  while IFS= read -r -d '' dir; do
    pid=""
    [[ -f "$dir/.rishi-active.pid" ]] && pid="$(<"$dir/.rishi-active.pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$command" == *capture_simulator.sh* ]] && continue
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
cleanup() {
  if [[ -n "$RECORD_PID" ]]; then
    kill -INT "$RECORD_PID" 2>/dev/null || true
    wait "$RECORD_PID" 2>/dev/null || true
  fi
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM
DERIVED_DATA="$BUILD_ROOT/DerivedData"
SOURCE_PACKAGES="$BUILD_ROOT/SourcePackages"

"$SIMCTL" boot "$UDID" 2>/dev/null || true
"$SIMCTL" bootstatus "$UDID" -b
"$XCODEBUILD" -project "$SCRIPT_DIR/../../rishi/rishi.xcodeproj" -scheme rishi -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" build
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
