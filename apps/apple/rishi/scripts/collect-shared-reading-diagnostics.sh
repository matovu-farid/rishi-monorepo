#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: collect-shared-reading-diagnostics.sh \
  --iphone-udid <simulator-udid> \
  --catalyst-dump <explicit-catalyst-rishi-dump-directory> \
  --output <output-directory>

Collects only DEBUG shared-reading NDJSON from the named iPhone Simulator and
the explicitly supplied Catalyst Application Support dump. It never guesses a
booted device, Catalyst sandbox, or output location.
USAGE
}

iphone_udid=""
catalyst_dump=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iphone-udid) iphone_udid="${2:-}"; shift 2 ;;
    --catalyst-dump) catalyst_dump="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -z "$iphone_udid" || -z "$catalyst_dump" || -z "$output_dir" ]]; then
  echo "--iphone-udid, --catalyst-dump, and --output are all required." >&2
  usage >&2
  exit 64
fi

if [[ ! "$iphone_udid" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
  echo "--iphone-udid must be an explicit simulator UUID." >&2
  exit 64
fi

for supplied_path in "$catalyst_dump" "$output_dir"; do
  if [[ "$supplied_path" == *".."* ]]; then
    echo "Path traversal is not allowed: $supplied_path" >&2
    exit 64
  fi
done

if [[ ! -d "$catalyst_dump" ]]; then
  echo "Catalyst dump directory does not exist: $catalyst_dump" >&2
  exit 66
fi
catalyst_dump="$(cd "$catalyst_dump" && pwd -P)"
catalyst_source="$catalyst_dump/shared-reading.ndjson"
if [[ ! -f "$catalyst_source" ]]; then
  echo "Catalyst shared-reading log is missing: $catalyst_source" >&2
  exit 66
fi

iphone_container="$(xcrun simctl get_app_container "$iphone_udid" org.fidexa.rishi data)" || {
  echo "Could not resolve app container for iPhone Simulator $iphone_udid." >&2
  exit 69
}
iphone_source="$iphone_container/tmp/rishi-dump/shared-reading.ndjson"
if [[ ! -f "$iphone_source" ]]; then
  echo "iPhone shared-reading log is missing: $iphone_source" >&2
  exit 66
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
merged="$output_dir/shared-reading.ndjson"
manifest="$output_dir/manifest.json"
iphone_copy="$output_dir/iphone-shared-reading.ndjson"
catalyst_copy="$output_dir/catalyst-shared-reading.ndjson"

for destination in "$merged" "$manifest" "$iphone_copy" "$catalyst_copy"; do
  if [[ -e "$destination" ]]; then
    echo "Refusing to overwrite existing diagnostic artifact: $destination" >&2
    exit 73
  fi
done

cp "$iphone_source" "$iphone_copy"
cp "$catalyst_source" "$catalyst_copy"

# The collector does not inspect or extract values from events. It only wraps
# complete JSON-object lines with their explicit source label for correlation.
append_labeled() {
  local source="$1"
  local file="$2"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" != \{*\} ]]; then
      echo "Malformed NDJSON in $file; refusing to produce a partial report." >&2
      exit 65
    fi
    printf '{"source":"%s","event":%s}\n' "$source" "$line" >> "$merged"
  done < "$file"
}

: > "$merged"
append_labeled "iphone-simulator" "$iphone_copy"
append_labeled "catalyst" "$catalyst_copy"

iphone_events="$(wc -l < "$iphone_copy" | tr -d ' ')"
catalyst_events="$(wc -l < "$catalyst_copy" | tr -d ' ')"
cat > "$manifest" <<MANIFEST
{
  "format": "rishi.shared-reading.diagnostics.v1",
  "iphoneSimulatorUDID": "$iphone_udid",
  "sources": [
    { "name": "iphone-simulator", "events": $iphone_events, "artifact": "iphone-shared-reading.ndjson" },
    { "name": "catalyst", "events": $catalyst_events, "artifact": "catalyst-shared-reading.ndjson" }
  ],
  "mergedArtifact": "shared-reading.ndjson"
}
MANIFEST

echo "Collected shared-reading diagnostics in: $output_dir"
