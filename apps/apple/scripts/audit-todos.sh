#!/usr/bin/env bash
set -euo pipefail

# Phase 15 plan 15-09: Production Swift code must not contain TODO / FIXME / XXX
# comments referencing work that should be completed by Phase 15.
#
# Banned patterns (case-insensitive): "wait for worker", "deferred", "stub",
# "/api/auth/apple". Test code under Tests/ is exempt — only production sources
# under Packages/*/Sources and the app target rishi/rishi/ are audited.
#
# Exits 1 with file:line context on the first occurrence; exits 0 when clean.

ROOT="${1:-apps/apple}"

if [[ ! -d "$ROOT" ]]; then
  echo "FAIL: audit root '$ROOT' does not exist" >&2
  exit 1
fi

BANNED='wait for worker|deferred|stub|/api/auth/apple'

SEARCH_PATHS=(
  "$ROOT/Packages/RishiAPI/Sources/"
  "$ROOT/Packages/RishiAuth/Sources/"
  "$ROOT/Packages/RishiBilling/Sources/"
  "$ROOT/Packages/RishiSync/Sources/"
  "$ROOT/Packages/RishiCore/Sources/"
  "$ROOT/rishi/rishi/"
)

EXISTING_PATHS=()
for path in "${SEARCH_PATHS[@]}"; do
  if [[ -d "$path" ]]; then
    EXISTING_PATHS+=("$path")
  fi
done

if [[ ${#EXISTING_PATHS[@]} -eq 0 ]]; then
  echo "FAIL: no production source roots found under '$ROOT'" >&2
  exit 1
fi

HITS=$(grep -rn -E "TODO|FIXME|XXX" \
  "${EXISTING_PATHS[@]}" \
  --include='*.swift' 2>/dev/null \
  | grep -iE "$BANNED" || true)

if [[ -n "$HITS" ]]; then
  echo "FAIL: banned production TODO / FIXME / XXX references found:" >&2
  echo "$HITS" >&2
  exit 1
fi

echo "PASS: no banned production TODOs"
exit 0
