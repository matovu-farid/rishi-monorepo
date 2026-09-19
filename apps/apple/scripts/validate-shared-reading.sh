#!/bin/zsh

set -u

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}
package_path="$repo_root/apps/apple/rishi-e2e-host"
api_origin="https://api-e2e.fidexa.org"
sharing_origin="wss://sharing-e2e.fidexa.org"

fail_configuration() {
  print -u2 -r -- "$1"
  exit 2
}

require_setting() {
  local key=$1
  if (( ! ${+parameters[$key]} )) || [[ -z "${(P)key}" ]]; then
    fail_configuration "Missing required shared-reading setting: $key"
  fi
}

require_e2e_api_origin() {
  require_setting RISHI_E2E_API_BASE_URL
  [[ "$RISHI_E2E_API_BASE_URL" == "$api_origin" ]] || \
    fail_configuration "RISHI_E2E_API_BASE_URL must equal $api_origin."
}

require_e2e_sharing_origin() {
  require_setting RISHI_E2E_SHARING_WS_URL
  [[ "$RISHI_E2E_SHARING_WS_URL" == "$sharing_origin" ]] || \
    fail_configuration "RISHI_E2E_SHARING_WS_URL must equal $sharing_origin."
}

require_live_configuration() {
  local key
  local -a required=(
    RISHI_E2E_ALLOW_NETWORK
    RISHI_E2E_ALLOW_SIMULATOR_RESET
    RISHI_E2E_TEST_AUTH_SECRET
    RISHI_E2E_TEST_DOMAIN
    RISHI_E2E_IPHONE17_UDID
    RISHI_E2E_PROJECT
    RISHI_E2E_FIXTURE
  )

  for key in $required; do
    require_setting "$key"
  done
  [[ "$RISHI_E2E_ALLOW_NETWORK" == 1 ]] || \
    fail_configuration "RISHI_E2E_ALLOW_NETWORK must equal 1."
  [[ "$RISHI_E2E_ALLOW_SIMULATOR_RESET" == 1 ]] || \
    fail_configuration "RISHI_E2E_ALLOW_SIMULATOR_RESET must equal 1."
  require_e2e_api_origin
  require_e2e_sharing_origin
}

require_recovery_configuration() {
  local key
  local -a required=(
    RISHI_E2E_ALLOW_NETWORK
    RISHI_E2E_TEST_AUTH_SECRET
    RISHI_E2E_TEST_DOMAIN
  )

  for key in $required; do
    require_setting "$key"
  done
  [[ "$RISHI_E2E_ALLOW_NETWORK" == 1 ]] || \
    fail_configuration "RISHI_E2E_ALLOW_NETWORK must equal 1."
  require_e2e_api_origin
}

if (( $# == 1 )) && [[ "$1" == --cleanup-manifest=* ]]; then
  require_recovery_configuration
  swift run --package-path "$package_path" --jobs 1 rishi-e2e-host "$1"
  exit $?
fi

if (( $# != 0 )); then
  fail_configuration "Usage: validate-shared-reading.sh [--cleanup-manifest=/absolute/path/to/recovery.json]"
fi

# Validate all live inputs before even the deterministic phase. This prevents a
# malformed or production endpoint from causing an accidental Swift invocation.
require_live_configuration

env -u RISHI_E2E_RUN_LIVE swift test --package-path "$package_path" --jobs 1
phase_status=$?
if (( phase_status != 0 )); then
  print -u2 -r -- "Shared-reading validation failed during deterministic package tests."
  exit "$phase_status"
fi

RISHI_E2E_RUN_LIVE=1 swift test --package-path "$package_path" --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
phase_status=$?
if (( phase_status != 0 )); then
  print -u2 -r -- "Shared-reading validation failed during the focused live XCTest."
fi
exit "$phase_status"
