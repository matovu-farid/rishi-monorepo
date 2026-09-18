#!/bin/zsh

set -u

script_dir=${0:A:h}
wrapper="$script_dir/validate-shared-reading.sh"
repo_root=${script_dir:h:h:h}
package_path="$repo_root/apps/apple/rishi-e2e-host"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/validate-shared-reading-tests.XXXXXX") || exit 1
trap 'rm -rf -- "$test_root"' EXIT INT TERM HUP

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/swift" <<'FAKE_SWIFT'
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
chmod +x "$fake_bin/swift"

failures=0
checks=0

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
  mkdir -p "$case_dir"
  fake_log="$case_dir/calls.log"
  fake_count="$case_dir/count"
  stdout_path="$case_dir/stdout"
  stderr_path="$case_dir/stderr"
  : > "$fake_log"
}

run_wrapper() {
  env -i \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FAKE_SWIFT_LOG="$fake_log" \
    FAKE_SWIFT_COUNT="$fake_count" \
    FAKE_SWIFT_STATUS_1="${FAKE_SWIFT_STATUS_1-0}" \
    FAKE_SWIFT_STATUS_2="${FAKE_SWIFT_STATUS_2-0}" \
    RISHI_E2E_RUN_LIVE="inherited-but-must-be-removed" \
    RISHI_E2E_ALLOW_NETWORK="${RISHI_E2E_ALLOW_NETWORK-1}" \
    RISHI_E2E_ALLOW_SIMULATOR_RESET="${RISHI_E2E_ALLOW_SIMULATOR_RESET-1}" \
    RISHI_E2E_API_BASE_URL="${RISHI_E2E_API_BASE_URL-https://api.fidexa.org}" \
    RISHI_E2E_TEST_AUTH_SECRET="${RISHI_E2E_TEST_AUTH_SECRET-do-not-print-this-secret}" \
    RISHI_E2E_TEST_DOMAIN="${RISHI_E2E_TEST_DOMAIN-example.test}" \
    RISHI_E2E_IPHONE17_UDID="${RISHI_E2E_IPHONE17_UDID-00000000-0000-0000-0000-000000000000}" \
    RISHI_E2E_PROJECT="${RISHI_E2E_PROJECT-/tmp/rishi.xcodeproj}" \
    RISHI_E2E_FIXTURE="${RISHI_E2E_FIXTURE-/tmp/book.pdf}" \
    /bin/zsh "$wrapper" > "$stdout_path" 2> "$stderr_path"
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

print -r -- "TEST: rejects missing or invalid live configuration before focused test"
for invalid_case in missing_fixture network_ack reset_ack api_url; do
  reset_fake "invalid_$invalid_case"
  unset RISHI_E2E_FIXTURE RISHI_E2E_ALLOW_NETWORK RISHI_E2E_ALLOW_SIMULATOR_RESET RISHI_E2E_API_BASE_URL
  case "$invalid_case" in
    missing_fixture) RISHI_E2E_FIXTURE='' ;;
    network_ack) RISHI_E2E_ALLOW_NETWORK=0 ;;
    reset_ack) RISHI_E2E_ALLOW_SIMULATOR_RESET=yes ;;
    api_url) RISHI_E2E_API_BASE_URL=https://example.invalid ;;
  esac
  FAKE_SWIFT_STATUS_1=0 FAKE_SWIFT_STATUS_2=0 run_wrapper
  exit_status=$?
  assert_equal 2 "$exit_status" "$invalid_case should exit with configuration status 2"
  assert_call_count "$fake_log" 1 "$invalid_case should not invoke the live phase"
  assert_not_contains "$stderr_path" "do-not-print-this-secret" "$invalid_case diagnostics must not print the secret"
done
unset RISHI_E2E_FIXTURE RISHI_E2E_ALLOW_NETWORK RISHI_E2E_ALLOW_SIMULATOR_RESET RISHI_E2E_API_BASE_URL

print -r -- "TEST: preserves focused live test failure and reports the live phase"
reset_fake live_failure
FAKE_SWIFT_STATUS_1=0 FAKE_SWIFT_STATUS_2=37 run_wrapper
exit_status=$?
assert_equal 37 "$exit_status" "focused live failure status should be preserved"
assert_call_count "$fake_log" 2 "focused live failure should happen on the second fake swift call"
assert_contains "$stderr_path" "failed during the focused live XCTest" "live failure should identify its phase"
assert_not_contains "$stderr_path" "do-not-print-this-secret" "live diagnostics must not print the secret"

if (( failures != 0 )); then
  print -u2 -r -- "$failures of $checks checks failed"
  exit 1
fi

print -r -- "PASS: $checks checks; all Swift invocations used the isolated fake"
