# Rishi native shared-reading E2E host

This macOS Swift package owns the disposable-account, real-book fixture, rendezvous, and two-peer XCTest coordination seams for the Apple shared-reading E2E run.

Book contents are never checked in. Supply local inputs through:

- RISHI_E2E_FIXTURE — one explicit .pdf or .epub path (preferred when both
  books are available)
- RISHI_E2E_FIXTURE_FORMAT — pdf or epub when selecting one of the
  format-specific variables below
- RISHI_E2E_PDF_FIXTURE — a regular .pdf file beginning with %PDF-
- RISHI_E2E_EPUB_FIXTURE — a regular .epub ZIP file

If both format-specific variables are set, selection is intentionally rejected
unless RISHI_E2E_FIXTURE_FORMAT is also set. This prevents a run from using a
different real book than the operator intended.

The host accepts only the canonical production API URL
https://api.fidexa.org; it does not launch or target a local Worker.
The production deployment currently leaves the gated test-auth route disabled.
Therefore a live run is expected to stop during account-service preflight until
an approved, controlled provisioning configuration is enabled on this same API
data plane. Do not point the Apple app at a local Worker or enable the route on
production without that operational approval.
The host and Swift MCP also share an atomic build lock. Set
RISHI_APPLE_XCODE_BUILD_LOCK_PATH to choose its location; an existing lock is
never removed automatically.

If an interrupted run preserves its `manifest.json`, recover the account
cleanup without building the Apple app or launching a simulator:

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
swift run --jobs 1 rishi-e2e-host \
  --cleanup-manifest="/private/tmp/rishi-shared-reading-.../manifest.json"
```

The recovery command accepts only emails in the configured generated
`rishi-e2e-*` namespace and attempts both accounts independently.

The resolver records only role, format, basename, SHA-256, and byte size in its redacted manifest. Account passwords and invite tokens are passed only to the corresponding short-lived XCTest process; bearer tokens remain in the host process. In a live host run, the Catalyst owner publishes its invite to the authorized loopback relay, which keeps it in memory; the file rendezvous remains a fallback for standalone peer execution. Participant readiness/progress/playback events also use the relay because the iPhone Simulator cannot read host filesystem paths. Secrets are not included in redacted output or process diagnostics.
If account provisioning loses its response after the server may have created an
account, the client attempts the gated email-based teardown route and fails
closed if that compensation fails.
Provisioning is create-only: an existing normalized email is rejected rather
than signed in, protecting unrelated accounts from teardown.
Cleanup calls the canonical authenticated `DELETE /api/user` route and requires
its explicit `ok: true` response before treating deletion as successful. It
falls back to the gated email teardown route if the authenticated request loses
its session or response, then verifies that the same credentials can no longer
access the account; failed deletion or verification preserves the run artifacts
for recovery.

Run the focused unit tests with:

```sh
swift test --jobs 1
RISHI_E2E_FIXTURE="/path/to/book.pdf" \
swift test --jobs 1 --filter RealBookFixturesTests
```

Before a live run, validate the external inputs independently with `pdfinfo` (or the platform equivalent) and `unzip -t`. Unit tests use fake transports and fake process/account collaborators; they do not call an API, launch `xcodebuild`, or launch a simulator.

To validate the complete local environment without creating accounts, retaining
build artifacts, or erasing a simulator, append `--preflight` to the Swift
command:

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
RISHI_E2E_IPHONE17_UDID="..." \
RISHI_E2E_PROJECT="/absolute/path/to/rishi.xcodeproj" \
RISHI_E2E_FIXTURE="/absolute/path/to/book.pdf" \
swift run --skip-build --jobs 1 rishi-e2e-host --preflight
```

## Live two-peer run

The live host requires an explicitly enabled test environment and a dedicated
iPhone 17 Pro simulator UDID. It erases only that simulator when
`RISHI_E2E_ALLOW_SIMULATOR_RESET=1`; omit that setting to fail closed.

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_API_BASE_URL="https://api.fidexa.org" \
RISHI_E2E_TEST_AUTH_SECRET="..." \
RISHI_E2E_TEST_DOMAIN="example.test" \
RISHI_E2E_IPHONE17_UDID="..." \
RISHI_E2E_PROJECT="/absolute/path/to/rishi.xcodeproj" \
RISHI_E2E_FIXTURE="/absolute/path/to/book.pdf" \
RISHI_E2E_ALLOW_SIMULATOR_RESET=1 \
swift run --jobs 1 rishi-e2e-host
```

The host starts a bounded loopback relay, resolves packages and builds Catalyst and iPhone sequentially into
separate derived-data directories, then starts the two already-built XCTest
peers. After
the owner peer imports the book through the normal app path, the host polls the
authenticated sync changes endpoint until the expected fixture hash has a
non-empty server object and size; only then is the participant peer launched.
The host checks free disk before any Xcode process starts and every five seconds
while the peers are active. If disk falls below the configured floor, it cancels
the run and enters the same account/process cleanup path. The manifest stays
restrictive, and both accounts are deleted and verified in cleanup even if
either peer fails. Set `RISHI_E2E_KEEP_ARTIFACTS=1` only when you intentionally
need the result bundles for diagnosis.

Before any Xcode process starts, the host requires at least 20 GiB of free
disk. This floor can only be raised with `RISHI_E2E_MIN_FREE_DISK_GB`.
The host does not inspect available memory for admission or cancellation.
Incomplete runs are preserved for recovery, but the host refuses to start when
the temporary root already contains three retained `rishi-shared-reading-*`
directories. Set `RISHI_E2E_MAX_RETAINED_RUNS` only when an operator has an
explicit retention policy; the host never deletes old failed-run artifacts
automatically.

When preflight fails, it creates no relay or retained run directory. Package
resolution uses a unique temporary directory and the shared build lock, and
removes that temporary state only after both Xcode processes have stopped.
The lock is retained if ownership cleanup cannot be proven.
Before retrying, first confirm that
`/private/tmp/rishi-apple-xcode-build.lock` is absent and that no Xcode or
simulator process is running. Remove only the specific stale
`rishi-shared-reading-*` directory or result bundle you have identified as no
longer needed; never use a broad `/private/tmp` recursive deletion while an
Apple process may still be alive.
