#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/start-rishi-workers-dev.sh"
ENDPOINT_AUDIT="$REPO_ROOT/scripts/check-apple-worker-endpoints.sh"
PRIMARY_CONFIG="$REPO_ROOT/workers/worker/wrangler.dev.jsonc"
SHARING_CONFIG="$REPO_ROOT/workers/sharing-worker/wrangler.dev.jsonc"

bash -n "$LAUNCHER"
bash -n "$ENDPOINT_AUDIT"
[[ -x "$ENDPOINT_AUDIT" ]]
! rg -q 'api\.fidexa\.org|sharing\.fidexa\.org|970159b7-ca91-49c1-bae8-feb43b24a7e6|"remote"[[:space:]]*:[[:space:]]*true' "$PRIMARY_CONFIG" "$SHARING_CONFIG"

if "$LAUNCHER" --remote >/dev/null 2>&1; then
  echo "expected --remote without explicit configs to fail" >&2
  exit 1
fi

"$ENDPOINT_AUDIT" >/dev/null

help_output="$($LAUNCHER --help)"
[[ "$help_output" == *"Starts the primary and shared-reading Workers"* ]]
[[ "$help_output" == *"Remote mode is opt-in"* ]]

echo "start-rishi-workers-dev safety checks passed"
