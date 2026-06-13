#!/usr/bin/env bash
# Prints the absolute path of the currently-running app's rishi-dump directory.
#
# The dump is populated by `SimulatorDumpSink` (DEBUG simulator builds only)
# and lives at `<APP_DATA_CONTAINER>/tmp/rishi-dump/`. Inside that directory
# you'll find:
#
#   all.log        — every event (NDJSON, one JSON object per line)
#   errors.log     — events at level error / fatal
#   warnings.log   — events at level warning
#   events.log     — every event (mirror of all.log; matches apps/main split)
#   network.log    — events for api.*, worker.*, sync.*, auth.siwa.*,
#                    billing.entitlement.*
#   path.txt       — same absolute path this script prints, for reference
#
# Usage:
#   tail -f "$(apps/apple/scripts/rishi-dump-path.sh)/all.log"
#   cat "$(apps/apple/scripts/rishi-dump-path.sh)/errors.log"
#
# Exits non-zero with a clear message if no booted sim has the app installed
# or the app hasn't launched yet (so the dump dir hasn't been created).

set -euo pipefail

BUNDLE_ID="org.fidexa.rishi"

DATA_DIR=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null) \
  || { echo "no booted simulator has $BUNDLE_ID installed" >&2; exit 1; }

DUMP_DIR="$DATA_DIR/tmp/rishi-dump"
if [[ ! -d "$DUMP_DIR" ]]; then
  echo "dump dir not found at $DUMP_DIR — has the app launched yet?" >&2
  exit 2
fi

echo "$DUMP_DIR"
