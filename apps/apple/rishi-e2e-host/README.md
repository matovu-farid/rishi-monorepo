# Rishi native shared-reading E2E host

This macOS Swift package owns the disposable accounts, real-book fixture,
disposable simulator, process identities, rendezvous relay, and two XCTest peers
used by the Apple shared-reading acceptance run. Unit tests use injected
collaborators; they do not call the API, run Xcode, boot a simulator, or launch
an app.

The live test is intentionally local-only and is not run by GitHub Actions or
other CI. It mutates real external state: it creates two disposable accounts,
clones the configured iPhone 17 Pro simulator as `rishi-e2e-<runID>`, erases
that disposable clone, and deletes and verifies both accounts during cleanup.
Use only dedicated test credentials, a dedicated source simulator, and a book
fixture that is safe to upload to the production data plane.

## Deterministic tests

The ordinary package suite leaves live mode unset, so the canonical acceptance
test is skipped:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

The local validator always runs that complete deterministic suite first with
`RISHI_E2E_RUN_LIVE` removed from its environment. It starts the one focused
live XCTest only when the deterministic phase succeeds and all live settings
below are valid.

## Local live validation

From the repository root, run:

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_ALLOW_SIMULATOR_RESET=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
RISHI_E2E_IPHONE17_UDID="..." \
RISHI_E2E_PROJECT="/absolute/path/to/rishi.xcodeproj" \
RISHI_E2E_FIXTURE="/absolute/path/to/book.pdf" \
apps/apple/scripts/validate-shared-reading.sh
```

Both acknowledgement variables must be exactly `1`, and the API URL must be
exactly `https://api.fidexa.org`. The production deployment currently leaves
the gated test-auth route disabled, so account-service preflight will fail until
an approved controlled provisioning configuration is enabled on that same API
data plane. Do not redirect this test to a local Worker or enable the route on
production without operational approval.

Book contents are never checked in. `RISHI_E2E_FIXTURE` must identify one
explicit regular PDF or EPUB. Validate it independently with `pdfinfo` or
`unzip -t` before the run. The host also supports
`RISHI_E2E_PDF_FIXTURE`/`RISHI_E2E_EPUB_FIXTURE` with an explicit
`RISHI_E2E_FIXTURE_FORMAT`, but the validator deliberately requires the single
unambiguous `RISHI_E2E_FIXTURE` setting.

The exact focused command run by the wrapper is:

```sh
RISHI_E2E_RUN_LIVE=1 \
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
```

All other required environment variables from the wrapper invocation must
remain set for that direct command. `RISHI_E2E_RUN_LIVE=1` alone is not an
authorization to use the network or reset a simulator.

Acceptance requires two consecutive successful validator runs. Each run must
report a participant progress sequence of at least 2, exactly two verified
account deletions, complete owned-process/simulator cleanup, release of the
exact build lock, and no retained recovery artifact or run directory.

The focused XCTest writes one redacted, sorted JSON line prefixed with
`RISHI_E2E_EVIDENCE`. It contains only the run ID, participant progress
sequence, and deleted-account count. Set `RISHI_E2E_EVIDENCE_PATH` to an
absolute local path to additionally retain that JSON as a mode `0600` file.
Never publish credentials, relay secrets, or raw process diagnostics as
evidence.

## Preflight

To validate configuration and package/build prerequisites without creating
accounts, launching an app, or erasing a simulator, use the same environment
except that reset acknowledgement is not required:

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
RISHI_E2E_IPHONE17_UDID="..." \
RISHI_E2E_PROJECT="/absolute/path/to/rishi.xcodeproj" \
RISHI_E2E_FIXTURE="/absolute/path/to/book.pdf" \
swift run --package-path apps/apple/rishi-e2e-host --jobs 1 \
  rishi-e2e-host --preflight
```

## Interrupted-run recovery

An incomplete run retains an exact `recovery.json` ownership artifact and, when
cleanup cannot be proven, its exact build lock. Recover only that artifact:

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
RISHI_E2E_TEMP_ROOT="/private/tmp" \
RISHI_APPLE_XCODE_BUILD_LOCK_PATH="/private/tmp/rishi-apple-xcode-build.lock" \
swift run --package-path apps/apple/rishi-e2e-host --jobs 1 \
  rishi-e2e-host \
  --cleanup-manifest="/private/tmp/rishi-shared-reading-<runID>/recovery.json"
```

Recovery verifies recorded process birth identities, disposable simulator and
secret-clone contracts, both accounts independently, exact lock ownership, and
descriptor-anchored run artifacts before removing anything. Any unproven step
fails closed and retains or restores the recovery artifact and lock for another
attempt. It never searches by process name, command line, bundle ID, or
environment and never guesses ownership.

Legacy `manifest.json` artifacts are recognized for compatibility, but
production recovery may safely refuse them because Darwin cannot prove exact
run-ID process absence without forbidden command-line/environment inspection.
An exact configured lock that cannot be tied to recorded ownership also blocks
legacy cleanup. Preserve the artifact and investigate; do not broadly delete
`/private/tmp`, kill processes by name, or remove a lock while Apple processes
may still be alive.

The host starts a bounded loopback relay, resolves packages, and builds Catalyst
and iPhone products sequentially into separate run-owned derived-data trees.
It checks free disk before Xcode starts and periodically while peers are active;
the default floor is 20 GiB (`RISHI_E2E_MIN_FREE_DISK_GB` can override it).
`RISHI_E2E_KEEP_ARTIFACTS=1` retains diagnostics intentionally. Otherwise,
successful cleanup removes all owned resources. Failed runs count against the
retained-run limit and are never deleted automatically.
