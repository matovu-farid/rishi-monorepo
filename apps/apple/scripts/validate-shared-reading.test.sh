#!/bin/zsh

set -u

setup_error() {
  print -u2 -r -- "Harness setup failed: $1"
  exit 1
}

script_dir=${0:A:h}
wrapper="$script_dir/validate-shared-reading.sh"
repo_root=${script_dir:h:h:h}
package_path="$repo_root/apps/apple/rishi-e2e-host"
[[ -f "$wrapper" && ! -L "$wrapper" ]] || setup_error "validator wrapper is not a regular file"
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/validate-shared-reading-tests.XXXXXX") || setup_error "mktemp"
[[ -d "$test_root" && ! -L "$test_root" ]] || setup_error "mktemp did not create a directory"
trap '/bin/rm -rf -- "$test_root"' EXIT INT TERM HUP || setup_error "cleanup trap"

fake_bin="$test_root/bin"
utility_bin="$test_root/utilities"
/bin/mkdir -p "$fake_bin" "$utility_bin" || setup_error "temporary utility directories"
/bin/ln -s /usr/bin/env "$utility_bin/env" || setup_error "controlled env utility"
[[ -x "$utility_bin/env" && ! -e "$utility_bin/swift" ]] || setup_error "controlled utility directory validation"
harness_path="$fake_bin:$utility_bin"
fake_swift="$fake_bin/swift"

if ! /bin/cat > "$fake_swift" <<'FAKE_SWIFT'
#!/bin/zsh
set -u

count=0
if [[ -r "$FAKE_SWIFT_COUNT" ]]; then
  IFS= read -r count < "$FAKE_SWIFT_COUNT"
fi
(( count += 1 ))
print -r -- "$count" > "$FAKE_SWIFT_COUNT"

{
  print -r -- "BEGIN"
  print -r -- "LIVE=${RISHI_E2E_RUN_LIVE-<unset>}"
  for argument in "$@"; do
    print -r -- "ARG=$argument"
  done
  print -r -- "END"
} >> "$FAKE_SWIFT_LOG"

status_key="FAKE_SWIFT_STATUS_$count"
exit_code=0
if (( ${+parameters[$status_key]} )); then
  exit_code=${(P)status_key}
fi
exit "$exit_code"
FAKE_SWIFT
then
  setup_error "fake swift file write"
fi
/bin/chmod 700 "$fake_swift" || setup_error "fake swift chmod"
[[ -f "$fake_swift" && ! -L "$fake_swift" && -x "$fake_swift" ]] || setup_error "fake swift validation"

failures=0
checks=0
typeset -a wrapper_args=()

fail() {
  print -u2 -r -- "FAIL: $1"
  (( failures += 1 ))
}

assert_equal() {
  local expected=$1
  local actual=$2
  local message=$3
  (( checks += 1 ))
  if [[ "$actual" != "$expected" ]]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local path=$1
  local expected=$2
  local message=$3
  (( checks += 1 ))
  if ! /usr/bin/grep -Fq -- "$expected" "$path"; then
    fail "$message"
  fi
}

assert_not_contains() {
  local path=$1
  local forbidden=$2
  local message=$3
  (( checks += 1 ))
  if /usr/bin/grep -Fq -- "$forbidden" "$path"; then
    fail "$message"
  fi
}

assert_call_count() {
  local path=$1
  local expected=$2
  local message=$3
  local actual=0
  if [[ -f "$path" ]]; then
    actual=$(/usr/bin/grep -c '^BEGIN$' "$path")
  fi
  assert_equal "$expected" "$actual" "$message"
}

reset_fake() {
  local case_name=$1
  case_dir="$test_root/$case_name"
  /bin/mkdir -p "$case_dir" || setup_error "case directory: $case_name"
  fake_log="$case_dir/calls.log"
  fake_count="$case_dir/count"
  stdout_path="$case_dir/stdout"
  stderr_path="$case_dir/stderr"
  : > "$fake_log" || setup_error "case log: $case_name"
  print -r -- 0 > "$fake_count" || setup_error "case counter: $case_name"
  : > "$stdout_path" || setup_error "case stdout capture: $case_name"
  : > "$stderr_path" || setup_error "case stderr capture: $case_name"
}

require_fake_swift() {
  if [[ ! -f "$fake_swift" || -L "$fake_swift" || ! -x "$fake_swift" ]]; then
    print -u2 -r -- "Harness setup failed: fake swift is not a regular executable"
    return 125
  fi

  local resolved
  resolved=$(PATH="$harness_path" /bin/zsh -c 'command -v swift') || {
    print -u2 -r -- "Harness setup failed: fake swift is not resolvable"
    return 125
  }
  if [[ "$resolved" != "$fake_swift" ]]; then
    print -u2 -r -- "Harness setup failed: swift resolved outside the fake tool directory"
    return 125
  fi
}

run_wrapper() {
  require_fake_swift 2> "$stderr_path" || return 125
  /usr/bin/env -i \
    PATH="$harness_path" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FAKE_SWIFT_LOG="$fake_log" \
    FAKE_SWIFT_COUNT="$fake_count" \
    FAKE_SWIFT_STATUS_1="${FAKE_SWIFT_STATUS_1-0}" \
    FAKE_SWIFT_STATUS_2="${FAKE_SWIFT_STATUS_2-0}" \
    PROBE_WRAPPER_MARKER="${PROBE_WRAPPER_MARKER-}" \
    RISHI_E2E_RUN_LIVE="inherited-but-must-be-removed" \
    RISHI_E2E_ALLOW_NETWORK="${RISHI_E2E_ALLOW_NETWORK-1}" \
    RISHI_E2E_ALLOW_SIMULATOR_RESET="${RISHI_E2E_ALLOW_SIMULATOR_RESET-1}" \
    RISHI_E2E_API_BASE_URL="${RISHI_E2E_API_BASE_URL-https://api-e2e.fidexa.org}" \
    RISHI_E2E_SHARING_WS_URL="${RISHI_E2E_SHARING_WS_URL-wss://sharing-e2e.fidexa.org}" \
    RISHI_E2E_TEST_AUTH_SECRET="${RISHI_E2E_TEST_AUTH_SECRET-do-not-print-this-secret}" \
    RISHI_E2E_TEST_DOMAIN="${RISHI_E2E_TEST_DOMAIN-example.test}" \
    RISHI_E2E_IPHONE17_UDID="${RISHI_E2E_IPHONE17_UDID-00000000-0000-0000-0000-000000000000}" \
    RISHI_E2E_PROJECT="${RISHI_E2E_PROJECT-/tmp/rishi.xcodeproj}" \
    RISHI_E2E_FIXTURE="${RISHI_E2E_FIXTURE-/tmp/book.pdf}" \
    /bin/zsh "$wrapper" "${wrapper_args[@]}" > "$stdout_path" 2> "$stderr_path"
}

print -r -- "TEST: runs deterministic suite with live mode off, then focused test with live mode on"
reset_fake success
FAKE_SWIFT_STATUS_1=0 FAKE_SWIFT_STATUS_2=0 run_wrapper
exit_status=$?
assert_equal 0 "$exit_status" "successful validation should exit zero"
assert_call_count "$fake_log" 2 "successful validation should invoke fake swift twice"
expected_log="BEGIN
LIVE=<unset>
ARG=test
ARG=--package-path
ARG=$package_path
ARG=--jobs
ARG=1
END
BEGIN
LIVE=1
ARG=test
ARG=--package-path
ARG=$package_path
ARG=--jobs
ARG=1
ARG=--filter
ARG=SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
END"
actual_log=$(<"$fake_log")
assert_equal "$expected_log" "$actual_log" "wrapper should issue the exact deterministic and focused commands"

print -r -- "TEST: preserves deterministic suite failure and does not start live phase"
reset_fake deterministic_failure
FAKE_SWIFT_STATUS_1=23 FAKE_SWIFT_STATUS_2=0 run_wrapper
exit_status=$?
assert_equal 23 "$exit_status" "deterministic failure status should be preserved"
assert_call_count "$fake_log" 1 "deterministic failure should stop before the live phase"
assert_contains "$stderr_path" "failed during deterministic package tests" "deterministic failure should identify its phase"

print -r -- "TEST: rejects missing, production, or malformed live endpoints before any Swift invocation"
for invalid_case in missing_api missing_wss production_api production_wss malformed_api malformed_wss; do
  reset_fake "invalid_$invalid_case"
  unset RISHI_E2E_API_BASE_URL RISHI_E2E_SHARING_WS_URL
  case "$invalid_case" in
    missing_api) RISHI_E2E_API_BASE_URL='' ;;
    missing_wss) RISHI_E2E_SHARING_WS_URL='' ;;
    production_api) RISHI_E2E_API_BASE_URL=https://api.fidexa.org ;;
    production_wss) RISHI_E2E_SHARING_WS_URL=wss://sharing.fidexa.org ;;
    malformed_api) RISHI_E2E_API_BASE_URL=https://api-e2e.fidexa.org/ ;;
    malformed_wss) RISHI_E2E_SHARING_WS_URL=wss://attacker@sharing-e2e.fidexa.org ;;
  esac
  FAKE_SWIFT_STATUS_1=0 FAKE_SWIFT_STATUS_2=0 run_wrapper
  exit_status=$?
  assert_equal 2 "$exit_status" "$invalid_case should exit with configuration status 2"
  assert_call_count "$fake_log" 0 "$invalid_case should reject before any Swift invocation"
  assert_not_contains "$stderr_path" "do-not-print-this-secret" "$invalid_case diagnostics must not print the secret"
done
unset RISHI_E2E_API_BASE_URL RISHI_E2E_SHARING_WS_URL

print -r -- "TEST: recovery is API-only and does not require a sharing URL or simulator reset acknowledgement"
reset_fake recovery
unset RISHI_E2E_SHARING_WS_URL RISHI_E2E_ALLOW_SIMULATOR_RESET
recovery_manifest="$test_root/recovery.json"
print -r -- '{}' > "$recovery_manifest" || setup_error "recovery manifest"
wrapper_args=("--cleanup-manifest=$recovery_manifest")
FAKE_SWIFT_STATUS_1=0 run_wrapper
exit_status=$?
assert_equal 0 "$exit_status" "API-only recovery should exit zero"
assert_call_count "$fake_log" 1 "API-only recovery should invoke Swift once"
assert_contains "$fake_log" "ARG=run" "recovery should run the host executable"
assert_contains "$fake_log" "ARG=--cleanup-manifest=$recovery_manifest" "recovery should pass through the exact manifest"
wrapper_args=()
unset RISHI_E2E_SHARING_WS_URL RISHI_E2E_ALLOW_SIMULATOR_RESET

print -r -- "TEST: preserves focused live test failure and reports the live phase"
reset_fake live_failure
FAKE_SWIFT_STATUS_1=0 FAKE_SWIFT_STATUS_2=37 run_wrapper
exit_status=$?
assert_equal 37 "$exit_status" "focused live failure status should be preserved"
assert_call_count "$fake_log" 2 "focused live failure should happen on the second fake swift call"
assert_contains "$stderr_path" "failed during the focused live XCTest" "live failure should identify its phase"
assert_not_contains "$stderr_path" "do-not-print-this-secret" "live diagnostics must not print the secret"

print -r -- "TEST: missing or nonexecutable fake swift fails before wrapper invocation"
probe_wrapper="$test_root/probe-wrapper.zsh"
probe_marker="$test_root/probe-wrapper-invoked"
if ! /bin/cat > "$probe_wrapper" <<'PROBE_WRAPPER'
#!/bin/zsh
print -r -- invoked > "$PROBE_WRAPPER_MARKER"
exit 99
PROBE_WRAPPER
then
  setup_error "probe wrapper file write"
fi
/bin/chmod 700 "$probe_wrapper" || setup_error "probe wrapper chmod"
[[ -f "$probe_wrapper" && ! -L "$probe_wrapper" && -x "$probe_wrapper" ]] || setup_error "probe wrapper validation"
original_wrapper=$wrapper
wrapper=$probe_wrapper

for fake_mode in missing nonexecutable; do
  reset_fake "unsafe_fake_$fake_mode"
  saved_fake="$test_root/swift.saved.$fake_mode"
  if [[ "$fake_mode" == missing ]]; then
    /bin/mv "$fake_swift" "$saved_fake" || setup_error "hide fake swift"
  else
    /bin/chmod 600 "$fake_swift" || setup_error "make fake swift nonexecutable"
  fi

  (( checks += 1 ))
  if /usr/bin/env -i PATH="$harness_path" /bin/zsh -c 'command -v swift >/dev/null 2>&1'; then
    fail "$fake_mode fake allows PATH to resolve a real swift; refusing unsafe wrapper invocation"
  else
    PROBE_WRAPPER_MARKER="$probe_marker" run_wrapper
    exit_status=$?
    assert_equal 125 "$exit_status" "$fake_mode fake should fail with harness setup status"
    assert_contains "$stderr_path" "fake swift is not a regular executable" "$fake_mode fake should report the setup failure"
    (( checks += 1 ))
    [[ ! -e "$probe_marker" ]] || fail "$fake_mode fake must fail before invoking the wrapper"
    assert_call_count "$fake_log" 0 "$fake_mode fake must not invoke swift"
  fi

  if [[ "$fake_mode" == missing ]]; then
    /bin/mv "$saved_fake" "$fake_swift" || setup_error "restore fake swift"
  else
    /bin/chmod 700 "$fake_swift" || setup_error "restore fake swift mode"
  fi
  [[ -f "$fake_swift" && ! -L "$fake_swift" && -x "$fake_swift" ]] || setup_error "restored fake swift validation"
done
wrapper=$original_wrapper

if (( failures != 0 )); then
  print -u2 -r -- "$failures of $checks checks failed"
  exit 1
fi

print -r -- "PASS: $checks checks; all Swift invocations used the isolated fake"
