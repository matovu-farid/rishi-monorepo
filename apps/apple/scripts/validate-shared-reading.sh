#!/bin/zsh

set -u

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}
package_path="$repo_root/apps/apple/rishi-e2e-host"

env -u RISHI_E2E_RUN_LIVE swift test --package-path "$package_path" --jobs 1
phase_status=$?
if (( phase_status != 0 )); then
  print -u2 -r -- "Shared-reading validation failed during deterministic package tests."
  exit "$phase_status"
fi

required=(
  RISHI_E2E_ALLOW_NETWORK
  RISHI_E2E_ALLOW_SIMULATOR_RESET
  RISHI_E2E_API_BASE_URL
  RISHI_E2E_TEST_AUTH_SECRET
  RISHI_E2E_TEST_DOMAIN
  RISHI_E2E_IPHONE17_UDID
  RISHI_E2E_PROJECT
  RISHI_E2E_FIXTURE
)

for key in $required; do
  if (( ! ${+parameters[$key]} )) || [[ -z "${(P)key}" ]]; then
    print -u2 -r -- "Missing required shared-reading setting: $key"
    exit 2
  fi
done

if [[ "$RISHI_E2E_ALLOW_NETWORK" != 1 ]]; then
  print -u2 -r -- "RISHI_E2E_ALLOW_NETWORK must equal 1."
  exit 2
fi

if [[ "$RISHI_E2E_ALLOW_SIMULATOR_RESET" != 1 ]]; then
  print -u2 -r -- "RISHI_E2E_ALLOW_SIMULATOR_RESET must equal 1."
  exit 2
fi

if [[ "$RISHI_E2E_API_BASE_URL" != "https://api.fidexa.org" ]]; then
  print -u2 -r -- "RISHI_E2E_API_BASE_URL must be the canonical production API URL."
  exit 2
fi

RISHI_E2E_RUN_LIVE=1 swift test --package-path "$package_path" --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
phase_status=$?
if (( phase_status != 0 )); then
  print -u2 -r -- "Shared-reading validation failed during the focused live XCTest."
fi
exit "$phase_status"
