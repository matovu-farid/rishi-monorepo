# Shared-Reading Repeatable Local End-to-End Test Design

## Goal

Add a repeatable Swift/XCTest regression test proving that native Apple shared reading works end to end with two real, disposable accounts. A Catalyst owner creates and starts a session, an iPhone 17 Pro participant joins it, and the participant observes the owner's reading progress.

The test is intended for local full-validation runs now and for future feature work. It is not a required GitHub check because it depends on local Apple simulators. This work does not use or modify the Rishi MCP server. Electron and Worker implementation changes are out of scope.

## Existing seam

The repository already contains the production-facing native harness:

- `SharedReadingHost` provisions two uniquely named disposable accounts, prepares Catalyst and iPhone 17 Pro products, launches both peers, waits for them, and cleans up.
- `SharedReadingOwnerUITests` creates the invite, starts the room, advances the reader, and waits for participant acknowledgement.
- `SharedReadingParticipantUITests` redeems the invite, joins the room, observes owner progress, and publishes the exact observed sequence.
- `SharedReadingTestSupport` coordinates only test rendezvous data. Session creation, join, authentication, and progress synchronization use the real app and canonical backend.
- `TestAccountClient` creates accounts in a restricted test namespace, deletes each through the canonical account-deletion path, falls back to gated recovery cleanup, and verifies that deleted credentials no longer work.

The new XCTest makes this distributed scenario an explicit and discoverable acceptance boundary. A thin local runner provides one convenient command for the deterministic suite and the live test; it contains no test behavior.

## Canonical Swift test

Add `SharedReadingLiveEndToEndTests.swift` to `RishiE2EHostTests` with one test:

`testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress`

The XCTest will:

1. Skip only when `RISHI_E2E_RUN_LIVE=1` is absent, keeping ordinary package tests deterministic and non-destructive. A skip is never accepted as live-test evidence.
2. When `RISHI_E2E_RUN_LIVE=1` is present, require `RISHI_E2E_ALLOW_NETWORK=1`, `RISHI_E2E_ALLOW_SIMULATOR_RESET=1`, the canonical `https://api.fidexa.org` URL, approved test-auth credentials, an exact iPhone 17 Pro template UDID, the Apple project path, and a validated local EPUB or PDF fixture. The template supplies the installed device type/runtime only; the run creates and owns a disposable simulator with the same type/runtime. Any missing or invalid prerequisite fails the test with a precise configuration error.
3. Run account-service and read-only Apple template preflights before creating accounts, starting a relay, taking a build lock, or creating a disposable simulator. Never boot, reset, launch on, or otherwise mutate the configured template simulator.
4. Create a unique run ID, run directory, result-bundle directory, and an atomic redacted recovery journal. Before each account-provisioning network request, record that generated address in the journal; as processes and the build lock are acquired, record only their stable process identities plus the lock path and ownership token/generation. Catalyst runner ownership is recorded through the relay's bounded newline-delimited JSON protocol using its existing shared secret plus a distinct host-reserved runner nonce. Catalyst app ownership must be proven by a separate host-reserved, single-use launch nonce callback made by the app itself during `rishiApp.init`; inject the app nonce only through `UITargetAppEnvironmentVariables`, never the runner environment, and the UI test must not submit an app PID. Require the existing relay-secret guard plus exact operation/kind/reserved metadata, validate the callback PID's current stable identity and app bundle, journal it before acknowledgement, and block app startup until that acknowledgement. Never persist a password, registration nonce, relay secret, bearer token, invite token, or book content.
5. Start the authenticated loopback rendezvous relay and pass its returned environment to `XCTestPeerProcessRunner`. The relay is always stopped during teardown.
6. Construct the real `TestAccountClient`, `FixtureBookProvisioner`, `XCTestPeerProcessRunner`, and `SharedReadingHost`; no fake account, peer, rendezvous, transport, or progress implementation is permitted.
7. Run Catalyst as owner and the run-owned disposable iPhone 17 Pro with the configured template's exact device type/runtime as participant. Catalyst launches exactly once with the existing reset behavior applied before sign-in; teardown must not relaunch it with a consumed registration nonce. The participant retains its intentional in-scenario restart/rejoin assertion but removes the deferred cleanup relaunch because deleting the disposable simulator is authoritative cleanup.
8. Assert that the host report has neither a primary failure nor a cleanup failure.
9. Stop and verify peer command groups and exact registered Catalyst processes, then delete and verify the disposable simulator, and only then delete the accounts. Remove every secret-bearing `.xctestrun` clone on all exit paths before retaining redacted diagnostics. Remove successful temporary artifacts unless retention is explicitly requested.

The XCTest is the source of truth. From the repository root it can be run directly with `RISHI_E2E_RUN_LIVE=1 swift test --package-path apps/apple/rishi-e2e-host --filter SharedReadingLiveEndToEndTests`. A helper or extracted composition root may be shared with the existing CLI so configuration and lifecycle logic are not duplicated.

## Repeatable local validation command

Add `apps/apple/scripts/validate-shared-reading.sh` as a thin convenience runner. It will:

1. Run the deterministic `rishi-e2e-host` package tests with one job and without `RISHI_E2E_RUN_LIVE`, so the live test is reported as skipped.
2. Validate that the caller explicitly supplied the network and simulator-reset acknowledgements and all required configuration, then run the focused live XCTest with `RISHI_E2E_RUN_LIVE=1` and one job.
3. Preserve the first non-zero exit status and print the exact failed phase.

The script must not contain session assertions, embed secrets, infer a simulator, silently enable network or simulator-reset access, or convert a failed/skipped live test into success. Setting `RISHI_E2E_RUN_LIVE=1` is safe only after the caller has supplied both destructive-operation acknowledgements. The script is documented as the local full shared-reading validation entry point, but it is not added to GitHub Actions or made a required PR check.

## Behavioral proof

The live XCTest is green only when all of these observable events occur in one run:

- Two different disposable accounts authenticate.
- The owner imports or receives the validated real fixture.
- The owner creates an invite and starts a shared-reading session.
- The participant redeems that invite and sees the same active room.
- The room contains both peers.
- The owner advances the shared-reader sequence.
- The participant observes sequence `>= 2` and acknowledges that exact observed sequence.
- Both UI peer processes exit successfully.
- Both disposable accounts are deleted and independently verified absent.
- The relay, recovery journal, manifest, staged fixture, build lock, and owned app/XCTest/build processes are cleaned up.

Existing playback and rejoin assertions may continue as part of the peer scenario, but they do not replace the required join-and-progress proof.

## Idempotency and recovery

Every run uses a new UUID-backed run ID and account addresses in the restricted `rishi-e2e-*` namespace. A run therefore cannot adopt or delete unrelated accounts or collide with prior session data. Unique naming alone is not sufficient cleanup: before creating either account, live-test preflight scans the configured temporary root for any retained recovery journal or `rishi-shared-reading-*/manifest.json`. If one exists, the new run fails closed and prints a recovery invocation containing the exact artifact path while referring only to already-configured environment variables; it never prints secret values. The operator must complete verified recovery before another live run can create accounts.

The recovery journal closes the failure window before the host manifest exists. `TestAccountClient` generates each address, atomically records it, and only then sends the provisioning request. The address remains recorded through lost responses, failed compensating deletion, host-manifest creation, and the complete peer run. An address is removed from recovery state only after authoritative deletion verification. Each launched peer or build process is recorded with a stable identity that distinguishes PID reuse, and the lock path plus ownership token/generation are recorded when acquired. The final recovery artifact is removed only after all generated addresses are verified absent, all recorded process identities are absent, and any retained build lock is safely reconciled. A crash at any point therefore leaves enough non-secret information to recover without permitting a later run to create more accounts.

Cleanup executes after success, assertion failure, timeout, thrown error, signal cancellation, or peer failure:

1. Stop each owned peer before deleting its account.
2. Delete owner and participant independently so one cleanup failure does not suppress the other.
3. Verify each deleted account can no longer authenticate.
4. Remove the rendezvous manifest and recovery journal only after both accounts are verified absent.
5. Stop the relay, remove the staged fixture, and release the build lock only after owned processes have stopped.

If cleanup cannot be proven, the XCTest fails and preserves the redacted recovery artifacts and diagnostics. The existing `--cleanup-manifest` command is strengthened to accept either the early recovery-journal shape or the later host-manifest shape, retry deletion using only addresses in the generated test namespace, and then independently verify absence through `DELETE /test/users/:email`. Recovery performs a second request for each generated address and accepts absence only when the response is `404` JSON whose decoded body is exactly `{ "error": "user not found" }`. A plain-text `404 Not Found` indicates a disabled or rejected test-auth gate and fails recovery; a generic `2xx` response is also insufficient verification.

Recovery also checks every journaled process identity, terminating only a still-matching owned identity and waiting for its confirmed exit; PID-only or broad name-based killing is forbidden. It reconciles a retained build lock only after the recorded owner and descendants are confirmed absent and the current lock metadata still has the journaled ownership token/generation. A missing or mismatched token means a newer owner may hold the path, so recovery must leave the lock untouched, retain artifacts, and fail. Recovery attempts every account and process independently, retains the recovery artifacts and lock, and returns non-zero if any absence or ownership check cannot be proved. Only after every recorded account and process is verified absent may it release the same-generation retained lock, remove the recovery artifacts, and unblock subsequent live runs. Credentials, bearer tokens, invite tokens, and book contents must never appear in XCTest output, recovery instructions, or persisted artifacts.

## Completion checks

Implementation is complete only when all of the following are demonstrated:

1. `SharedReadingLiveEndToEndTests.swift` exists in `RishiE2EHostTests`, and the live test contains no fake account, peer, rendezvous, transport, or progress dependency.
2. A red-phase result is recorded before supporting harness code is changed, if the new XCTest exposes a missing seam.
3. With `RISHI_E2E_RUN_LIVE` absent, `swift test --package-path apps/apple/rishi-e2e-host --jobs 1` passes for the deterministic package suite, reports the live XCTest as skipped, and neither contacts the network nor resets a simulator.
4. Approved test-auth provisioning is available on the canonical API data plane, and the account-service preflight succeeds. A skipped test or disabled-route response is not successful evidence.
5. `apps/apple/scripts/validate-shared-reading.sh` runs the deterministic suite and then the focused live XCTest, returning non-zero when either phase fails.
6. One focused live run succeeds with explicit local configuration:

   ```sh
   RISHI_E2E_ALLOW_NETWORK=1 \
   RISHI_E2E_ALLOW_SIMULATOR_RESET=1 \
   RISHI_E2E_API_BASE_URL=https://api.fidexa.org \
   RISHI_E2E_TEST_AUTH_SECRET=... \
   RISHI_E2E_TEST_DOMAIN=... \
   RISHI_E2E_IPHONE17_UDID=... \
   RISHI_E2E_PROJECT=/absolute/path/to/rishi.xcodeproj \
   RISHI_E2E_FIXTURE=/absolute/path/to/book.epub \
   apps/apple/scripts/validate-shared-reading.sh
   ```

7. The command is run a second consecutive time with the same configuration and also succeeds, proving cleanup and rerun safety rather than merely unique naming.
8. Evidence from each run identifies its run ID and confirms the same-session lifecycle, participant-observed progress sequence `>= 2`, and verified deletion of both generated accounts.
9. Post-run process inspection shows no owned `rishi`, `xcodebuild`, XCTest runner, relay, or E2E-host process remains, and no successful-run recovery journal, manifest, or staged fixture remains.
10. Failure-path tests cover a lost provisioning response plus failed compensation before host-manifest creation, atomic recovery-journal persistence, independent account cleanup, authoritative recovery deletion verification, PID-reuse-safe process recovery, same-generation retained build-lock reconciliation, refusal to release a replacement-owner lock, refusal to start while any unresolved recovery artifact or owned process exists, relay shutdown, recovery-artifact retention/removal rules, and non-zero wrapper exit behavior.
11. No MCP, Electron, Worker, or GitHub workflow files are changed by this work.

## Non-goals

- Repairing or extending MCP automation.
- Changing Electron, Worker, or GitHub Actions code.
- Making the live test part of ordinary fast package-test execution.
- Replacing the existing native E2E host or peer UI tests.
- Calling a mock-only coordinator test end to end.
- Changing shared-reading product behavior before the live test exposes a concrete failure.
