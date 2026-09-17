# Shared-Reading Live End-to-End Test Design

## Goal

Add one opt-in XCTest that proves the native Apple shared-reading behavior works end to end with two real accounts: a Catalyst owner creates and starts a session, an iPhone 17 Pro participant joins it, and reading progress from the owner is observed by the participant.

This work does not use, modify, or validate the Rishi MCP server. Electron and Worker implementation changes are out of scope.

## Existing seam

The repository already contains the correct production-facing test harness:

- `SharedReadingHost` provisions two disposable accounts, prepares Catalyst and iPhone 17 Pro products, launches both peers, waits for both processes, and cleans up.
- `SharedReadingOwnerUITests` creates the invite, starts the room, advances the shared reader, and waits for participant acknowledgement.
- `SharedReadingParticipantUITests` redeems the invite, joins the room, observes the owner's progress, and publishes the observed sequence.
- `SharedReadingTestSupport` coordinates only test rendezvous data; session creation, join, and progress synchronization still use the real app and backend.

The new test will make that distributed scenario an explicit, discoverable XCTest acceptance boundary rather than introducing another automation mechanism.

## Test design

Add `SharedReadingLiveEndToEndTests.swift` to `RishiE2EHostTests` with one test named to describe the user-visible behavior, for example:

`testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress`

The test will:

1. Require the same explicit safety gates as the native E2E CLI before any external action: `RISHI_E2E_ALLOW_NETWORK=1`, the canonical `https://api.fidexa.org` URL, and `RISHI_E2E_ALLOW_SIMULATOR_RESET=1`. Read the test-account secret/domain, Apple project path, exact iPhone 17 Pro UDID, and EPUB fixture path/manifest only after those gates pass.
2. Skip with a precise message when the live gates, credentials, approved canonical test-auth provisioning, or destinations are not configured; ordinary package unit tests therefore remain deterministic. A skip or failed account-service preflight is not successful end-to-end evidence.
3. Create an isolated run directory and result-bundle directory.
4. Start the authenticated rendezvous relay and always stop it with teardown that runs on success, failure, throw, or cancellation.
5. Construct the existing real `TestAccountClient`, `FixtureBookProvisioner`, `XCTestPeerProcessRunner`, and `SharedReadingHost`. Pass the relay's returned `rendezvousEnvironment` into `XCTestPeerProcessRunner.Configuration`; file rendezvous is not accepted for the iPhone participant.
6. Run the host once with Catalyst as owner and iPhone 17 Pro as participant.
7. Assert the run report has no primary failure and no cleanup failure.
8. Preserve result bundles and stage logs on failure, while removing successful run artifacts unless explicitly configured to retain them.

No mocked account, peer, rendezvous, transport, or progress implementation is permitted in this test.

## Behavioral proof

The test is green only when all of these observable events occur:

- Two different disposable accounts authenticate.
- The owner imports or receives the validated EPUB fixture.
- The owner creates an invite and starts a shared-reading session.
- The participant redeems that invite and sees an active room.
- The room contains both peers.
- The owner advances the shared-reader sequence.
- The participant observes sequence `>= 2` and acknowledges that exact observed sequence.
- Both UI peer processes exit successfully.
- Both disposable accounts and run coordination artifacts are cleaned up.

The existing playback and rejoin assertions may continue to run as part of the peer scenario, but they are not substitutes for the required join-and-progress assertions above.

## Failure reporting

The XCTest failure must identify the failed role and preserve the existing bounded peer diagnostics, `.xcresult` bundle, and fixed-literal stage log. Credentials, bearer tokens, invite tokens, and book contents must not appear in XCTest output.

## Completion checks

Implementation is complete only when:

1. The new live test is present and contains no fake peer/account/transport dependencies.
2. A red-phase run is recorded before any supporting test-harness change, if a harness change is required.
3. `swift test --package-path apps/apple/rishi-e2e-host --jobs 1` passes for the deterministic package suite.
4. Approved test-auth provisioning is enabled on the canonical API data plane, and the focused test's account-service preflight succeeds. Neither a skipped test nor a disabled-route failure satisfies this check.
5. The focused live command runs with explicit network and simulator-reset authorization, configured secrets, and exits successfully:

   ```sh
   RISHI_E2E_ALLOW_NETWORK=1 \
   RISHI_E2E_ALLOW_SIMULATOR_RESET=1 \
   RISHI_E2E_API_BASE_URL=https://api.fidexa.org \
   RISHI_E2E_TEST_AUTH_SECRET=... \
   RISHI_E2E_TEST_DOMAIN=... \
   RISHI_E2E_IPHONE17_UDID=... \
   RISHI_E2E_PROJECT=/absolute/path/to/rishi.xcodeproj \
   RISHI_E2E_FIXTURE=/absolute/path/to/alice.epub \
   swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
     --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
   ```

6. The focused run produces evidence for the same session lifecycle on Catalyst and iPhone 17 Pro and confirms participant-observed progress sequence `>= 2`.
7. Process inspection after the run shows no owned `rishi`, `xcodebuild`, XCTest runner, relay, or E2E-host process remains.
8. No MCP, Electron, or Worker files are changed by this test work.

## Non-goals

- Repairing or extending MCP automation.
- Replacing the existing native E2E host.
- Adding a mock-only coordinator test and calling it end to end.
- Changing shared-reading product behavior before this test exposes a concrete failure.
