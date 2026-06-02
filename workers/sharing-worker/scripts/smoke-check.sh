#!/usr/bin/env bash
set -euo pipefail

WORKER_URL="${1:-}"
if [[ -z "$WORKER_URL" ]]; then
  echo "Usage: $0 <worker-url>"
  echo "Example: $0 https://rishi-sharing-worker.abc.workers.dev"
  exit 1
fi

echo "=== /health ==="
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${WORKER_URL}/health")
if [[ "$STATUS" != "200" ]]; then
  echo "FAIL: /health returned $STATUS"
  exit 1
fi
echo "PASS: /health → 200"

echo ""
echo "=== POST /v1/sessions (no auth — expect 401) ==="
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${WORKER_URL}/v1/sessions" \
  -H "Content-Type: application/json" \
  -d '{"bookContext":{},"requiresApproval":false}')
if [[ "$STATUS" != "401" ]]; then
  echo "FAIL: /v1/sessions without auth returned $STATUS (expected 401)"
  exit 1
fi
echo "PASS: /v1/sessions without auth → 401"

echo ""
echo "All smoke checks passed."
