#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="$repo_root/apps/apple/rishi/rishi"

# Tests may use explicit fixture URLs, but production Apple code must use only
# the compiled canonical production endpoint configuration.
violations="$(rg -n \
  --glob '*.swift' \
  --glob '!**/rishiTests/**' \
  --glob '!**/*Tests.swift' \
  'URL\(string:\s*"(https://api|wss://sharing)\.fidexa\.org"|ProcessInfo\.processInfo\.environment\["RISHI_(API|SHARING|WEBSOCKET)[^"]*URL"\]' \
  "$apple_root" \
  | rg -v '/Networking/RishiAPIEnvironment\.swift:' || true)"

if [[ -n "$violations" ]]; then
  printf '%s\n' "Apple Worker endpoint fallback detected:" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

printf '%s\n' "Apple Worker endpoint audit passed"
