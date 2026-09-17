# Shared Reading Runtime Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` to implement this plan task-by-task. Each implementation task receives an independent specification review followed by an independent code-quality review. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** Adversarial review loop complete — **PASS** (6 rounds, 0 open issues).

**Goal:** Make the Swift Apple MCP reliably launch, inspect, and control exactly one Mac Catalyst Rishi app and one iPhone 17 Pro Rishi app, expose explicit authentication state, and prove the real two-account shared-reading workflow end to end.

**Architecture:** Keep the MCP server outside the production app. An XCTest UI-test bridge owns one long-lived `XCUIApplication` handle per target after external launch, exposes bounded semantic state instead of an unbounded accessibility dump, and never retries app launch while cleaning up a failed launch. Target-specific loopback ports remain an explicit bridge transport contract only if the UI-test runner cannot receive a dynamic endpoint; an absent MCP listener must make an ordinary focused UI-test run skip cleanly rather than fail or hang.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest/XCUI, Xcode 27, CoreSimulator, Mac Catalyst, stdio MCP JSON-RPC, Codex MCP client.

---

## Relationship to earlier plans

This plan supersedes only the runtime-launch, memory-gating, semantic-inspection, and live-acceptance portions of:

- `apps/apple/docs/superpowers/plans/2026-09-17-shared-reading-completion.md`
- `apps/apple/docs/superpowers/plans/2026-09-15-shared-reading-mcp-live-acceptance.md`

The user explicitly removed the memory gate. Available-memory values remain telemetry and must never block launch, inspection, or acceptance. The disk-space guard remains. The Electron app is excluded. Existing Worker behavior is treated as an external dependency unless live evidence identifies a server defect required for this Apple workflow.

## Current evidence and open defects

| ID | Evidence | Classification | Completion proof |
|---|---|---|---|
| R1 | Catalyst `start_app` succeeds, but `inspect_app_state` reaches the 30-second bridge deadline. | MCP/XCTest harness defect | Five consecutive `ping → inspect → semantic action → inspect` cycles return before 10 seconds each on Catalyst. |
| R2 | iPhone bridge connects, then external `simctl launch` fails with `FBSOpenApplicationServiceErrorDomain` code 4. Direct `simctl install` plus `simctl launch` succeeds on the same booted iPhone 17 Pro. | MCP lifecycle defect; exact simulator-side trigger still to be instrumented | MCP starts the same iPhone target twice in separate clean cycles with no FBS failure and no manual launch. |
| R3 | When first external launch fails, cleanup can enter the same pre-dispatch launch path again because `externalLaunch` remains false. | Confirmed MCP state-machine defect | Unit/integration regression proves exactly one launch attempt and cleanup reaches terminal zero state after injected launch failure. |
| R4 | A failed iPhone start returned while its `xcodebuild` child remained alive until manually killed. | MCP process-ownership defect; escape path not yet proven | Injected failure plus live failure test proves no recorded root/descendant remains and ownership/lock release occurs only after that proof. |
| R5 | Creating a fresh `XCUIApplication` for every non-ping operation passes a classifier test but live Catalyst inspection still times out. | Unproven attempted fix | A real bridge integration test proves one post-launch handle survives and serves multiple operations; classifier-only tests are insufficient. |
| R6 | `semanticSnapshot` has session/roster/reader fields but no authentication field. The iPhone was visually signed out while the MCP could not report that directly. | Confirmed observability gap | Signed-out, onboarding, loading, and signed-in fixtures/live states produce explicit, mutually exclusive auth status. |
| R7 | The fixed-port fallback makes `testServer` try to connect when no MCP listener exists, replacing the previous skip behavior. | Confirmed test-harness regression | Focused UI-test invocation without an MCP listener skips only `testServer`; MCP-owned invocation connects and does not skip. |
| R8 | Shared reading has not yet been proven with two real signed-in accounts through the registered MCP. | Feature acceptance gap | Same-run transcript proves create, join, exactly two readers with capacity at least two, synchronized reader state, leave/end, and zero owned processes. |
| R9 | `InstanceRegistry` awaits memory snapshots in list/start/stop, and the TypeScript acceptance executor still requires `configuredMinimumMemoryBytes`. | Confirmed stale memory-gate defect | Injected memory-snapshot failures do not fail lifecycle operations; acceptance records optional telemetry but never compares it with a floor. |

## Non-negotiable scope and safety rules

- Work only under `apps/apple/**` plus the existing Apple-specific acceptance scripts if a verifier must change.
- Do not edit, build, test, move, or delete the deprecated Electron app.
- Do not add test-auth, session injection, fake live results, arbitrary shell MCP tools, or public coordinate actions.
- At runtime, use exactly one Catalyst app and one iPhone 17 Pro app. A failed launch must be cleaned before any retry.
- Preserve simulator/app containers so the user-entered authenticated sessions remain available.
- Do not log, persist, or externally transmit email addresses, passwords, bearer tokens, invite tokens, book content, or full process command lines. An invite token may transit only in memory between the local owner-create and participant-join MCP calls, then must be discarded.
- Host memory is telemetry only. Disk safety may still abort a build or launch.
- Never treat a package/unit test as proof of live shared reading.

## File responsibility map

| File | Responsibility in this repair |
|---|---|
| `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift` | Launch state machine, bridge endpoint, process ownership, request deadlines, target cleanup. |
| `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift` | Deterministic launch-failure, cleanup, bridge, and process-ownership regressions. |
| `apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift` | Lifecycle bookkeeping with optional, non-blocking memory telemetry and duplicate-process evidence. |
| `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift` | Telemetry-failure and duplicate-process lifecycle regressions. |
| `apps/apple/rishi/rishiUITests/MCPControlUITests.swift` | UI-test bridge lifecycle, long-lived application handle, bounded semantic snapshot, auth semantic extraction. |
| `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift` | Public `inspect_app_state` semantic response contract. |
| `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift` | Public semantic response and workflow contract tests. |
| `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift` | Public session-action schemas, including join completion and teardown. |
| `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift` | Exact public tool-schema regression tests. |
| `apps/apple/rishi/rishi/RootView.swift` | Stable accessibility marker for loading/signed-in branches if existing child markers cannot distinguish them. |
| `apps/apple/rishi/rishi/Auth/SignedOutView.swift` | Stable signed-out accessibility marker. |
| `apps/apple/rishi/rishi/Onboarding/OnboardingHost.swift` | Stable marker covering every onboarding stage above the underlying auth branch. |
| `apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh` | One bounded, cleanup-safe live scenario if the current script cannot express the verified sequence. |
| `scripts/test-integrity/run-rishi-mcp-acceptance.ts` | Actual MCP acceptance state machine; memory telemetry is optional and process identity is authoritative. |
| `scripts/test-integrity/run-rishi-mcp-acceptance.test.ts` | Acceptance executor unit tests for memory telemetry, room start, duplicates, and teardown. |
| `scripts/test-integrity/verify-shared-reading-release.ts` | Final evidence schema for the expanded bounded tool contract, optional memory telemetry, and registered-Codex provenance. |
| `scripts/test-integrity/verify-shared-reading-release.test.ts` | Rejects unregistered clients, missing required session actions, duplicate processes, and malformed evidence without requiring memory telemetry. |
| `scripts/test-integrity/run-rishi-codex-acceptance.ts` | Invokes the real Codex CLI against the enabled `rishi-apple` registration and emits a redacted ordered MCP event stream. |
| `scripts/test-integrity/run-rishi-codex-acceptance.test.ts` | Fixture-driven Codex event parser, registration-binding, redaction, timeout, and cleanup tests. |
| `apps/apple/docs/superpowers/reviews/shared-reading-release-required-tests.json` | Required Apple release-gate command, updated to the registered-Codex acceptance path with no binary override. |
| `scripts/test-integrity/run-shared-reading-release.test.ts` | Manifest regression proving the required Apple gate invokes the registered-Codex runner and rejects the removed flags. |

## Completion matrix

| Gate | Command or observation | Pass condition |
|---|---|---|
| Diff boundary | `git diff --name-only origin/main...HEAD` and `git status --short` | No Electron path; every uncommitted path is classified and reviewed. |
| Swift MCP package | `swift test --package-path apps/apple/rishi-mcp --jobs 1` | Exit 0; all discovered tests pass; no hang. |
| Catalyst bridge | Focused `MCPControlUITests` bridge lifecycle tests plus live MCP probe | Five sequential semantic requests succeed; no bridge timeout. |
| iPhone bridge | Two clean MCP start/inspect/stop cycles on exact iPhone 17 Pro UDID | Both cycles pass; no FBS failure; no stale app/XCTest/Xcode process. |
| Auth semantics | Signed-out/onboarding/loading/signed-in test matrix and live inspection | One explicit status is returned; no credential/account value is exposed. |
| Session tool semantics | MCP package tests plus focused bridge tests | Create returns only after owner session presentation; join returns only after participant session presentation; progress sequence/playback are semantic fields; leave/end are explicit actions. |
| Duplicate prevention | Logical instance ledger plus privacy-safe PID/PPID/PGID/executable inventory before each transition | Logical ledger is `[0,1,2,0]`; physical target-process counts are `[0,1,2,0]`; no target has multiple app processes. |
| Shared reading | Registered Codex MCP transcript and two-target screenshots/semantic state | Same session, exactly two readers with capacity at least two, room active on both peers, owner and participant open book, synchronized progress/action, participant leaves, owner ends. |
| Cleanup | `list_app_instances`, exact PID/PPID/PGID/executable inventory, listener/lock checks | Zero owned instances, XCTest/xcodebuild descendants, bridge listeners, and build locks. |
| Reviews | Separate spec then quality reviews per task; final branch review | Zero open Critical/High findings. |

## Implementation order

Tasks are sequential because each later gate depends on the prior runtime contract. Research/review may run in parallel only when scopes are disjoint and read-only.

### Task 1: Make failed launch and cleanup a single terminal state machine

**Files:**
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift`

- [ ] **Step 1: Make memory telemetry non-blocking with red registry tests**

Inject a `MemorySnapshotting` fake that throws during each of `list`, post-launch `start`, and post-stop `stop`. Each lifecycle operation must still succeed based on the driver result and return:

```json
{"memory":{"available":false}}
```

or omit the telemetry field. A telemetry error must never terminate a successfully launched app, lose registry ownership, fail listing, or turn a successful stop into failure. A successful snapshot remains attached as telemetry.

- [ ] **Step 2: Add a red launch-failure sequencing test**

Introduce an injected external-launch closure or a small `ExternalTargetLaunching` seam. The test records events for `ping`, external launch, stop request, owned-process stop, descendant wait, external-target probe, and ownership release. Inject an FBS-shaped launch failure and require:

```swift
XCTAssertEqual(events.filter { $0 == .launchExternalTarget }.count, 1)
XCTAssertTrue(events.contains(.stopOwnedProcess))
XCTAssertTrue(events.contains(.waitForOwnedProcessCleanup))
XCTAssertTrue(events.contains(.releaseOwnership))
```

Before the fix, the test must show a second launch attempt or incomplete cleanup.

- [ ] **Step 3: Replace the Boolean with explicit launch states**

Use an internal state equivalent to:

```swift
enum ExternalLaunchState {
    case notAttempted
    case launching
    case running
    case failed
}
```

Only a normal operational request may transition `notAttempted → launching → running`. A thrown launch error transitions to `failed`. Cleanup never transitions `failed` back to `launching`; it stops the owned XCTest process, verifies target absence, releases ownership, and preserves the original launch error separately from cleanup failure.

- [ ] **Step 4: Add a red orphan-root/descendant test**

The regression must start a managed root with a descendant, inject failure after the bridge connects, call cleanup, and assert every recorded PID/PGID is absent before `releaseOwnership`. Update the existing escaped-descendant test: survival may be accepted only for a process proven never to have been a descendant/owned identity; a recorded owned descendant surviving is failure.

- [ ] **Step 5: Add privacy-safe duplicate-process evidence**

Extend the driver/registry contract so each target instance contains a bounded list of `{pid, ppid, pgid, executable}` identities and an exact process count. Never include command-line arguments. Unit tests feed two Catalyst identities or two iPhone app identities for one logical target and require `INSTANCE_ALREADY_RUNNING`/acceptance failure rather than collapsing them into a `Set`.

- [ ] **Step 6: Run focused tests**

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'XCTestDriverTests/(test.*Launch|test.*Stop|test.*Cleanup|test.*Descendant|test.*Duplicate)|InstanceRegistryTests'
```

Expected: all selected tests pass, and an exact process inventory after the command contains no `RishiAppleMCPTests`, `xcodebuild`, `rishiUITests`, or app process spawned by the test.

- [ ] **Step 7: Independent reviews and commit**

Run specification review, fix/re-review, then code-quality review, fix/re-review. Commit only Task 1 files.

### Task 2: Establish a durable bridge endpoint and one post-launch application handle

**Files:**
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- Modify: `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`

- [ ] **Step 1: Preserve the runtime endpoint evidence**

Add tests documenting both cases: an inherited `RISHI_MCP_BRIDGE_CONFIG` selects its declared port; when XCTest does not inherit that environment, `catalyst` and `iphone17` select distinct loopback-only ports. A missing listener must be distinguishable from an MCP-owned connection attempt.

- [ ] **Step 2: Restore safe no-listener behavior**

In an ordinary focused UI-test run with no MCP listener, `testServer` must call `XCTSkip` promptly with a precise reason. During MCP startup, the MCP driver still times out/fails if the expected listener never connects, so this skip cannot create a false live success.

- [ ] **Step 3: Add a red application-handle lifecycle test**

Extract a small pure state machine proving that no app handle is created before the first request has passed the driver's external-launch gate, exactly one handle is created afterward, and the same handle is reused for `snapshot`, `tap`, `tapText`, `wait`, and `stop`.

- [ ] **Step 4: Replace per-operation handles with one lazy post-launch handle**

Remove the `requiresFreshApplication` classifier. In `testServer`, create and retain one `XCUIApplication(bundleIdentifier:)` only after receiving the first bridge request (which the driver writes only after successful external launch). Reuse it for the loop lifetime.

- [ ] **Step 5: Make snapshot bounded**

Instrument `debugDescription` and semantic extraction separately. If `debugDescription` is the blocking call, remove it from the public snapshot path and return only a bounded semantic envelope plus a bounded list of stable identifiers needed by `inspect_app_state`. Never raise the deadline to hide a blocked query.

- [ ] **Step 6: Prove repeated live Catalyst operations**

With one MCP-owned Catalyst instance, execute five cycles of:

```text
inspect_app_state → click_text/semantic no-op-safe action → inspect_app_state
```

Record monotonic start/end timestamps. Every call must complete in under 10 seconds and the bridge must remain available for the next call.

- [ ] **Step 7: Review and commit**

Run focused package/UI tests, specification review, code-quality review, and re-reviews. Commit only Task 2 files.

### Task 3: Expose explicit, privacy-safe authentication state

**Files:**
- Modify: `apps/apple/rishi/rishi/RootView.swift`
- Modify: `apps/apple/rishi/rishi/Auth/SignedOutView.swift`
- Modify: `apps/apple/rishi/rishi/Onboarding/OnboardingHost.swift`
- Modify: `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`

- [ ] **Step 1: Write the auth-state contract tests**

Define the semantic payload as:

```json
{"authentication":{"status":"onboarding|signedOut|loading|signedIn"}}
```

Tests require exactly one known status. They must reject ambiguous markers and must prove that email, user ID, password, tokens, and account labels are absent.

- [ ] **Step 2: Add stable accessibility markers**

Add one marker to each auth root branch and one marker to `OnboardingHost`, which covers the complete multi-screen flow. Use identifiers, not localized labels. When the onboarding marker is present, semantic extraction must return `onboarding` even if an underlying signed-in/signed-out branch is also mounted. The implementation must not expose credentials or a stable account identifier.

- [ ] **Step 3: Extract and forward semantic auth state**

`MCPControlUITests.semanticSnapshot` derives the status from the root marker. `AppTools.inspect_app_state` returns it as `semanticState.authentication.status` without requiring callers to parse an opaque tree.

- [ ] **Step 4: Verify live transitions**

Test every onboarding stage and prove it takes precedence over background auth markers. On a disposable/signed-out state, observe `onboarding` or `signedOut`; after the user completes onboarding and sign-in, observe `signedIn`. Repeat for Catalyst and iPhone. Do not automate credential entry or retain screenshots containing account data.

- [ ] **Step 5: Review and commit**

Run focused tests, serialized Catalyst/iPhone builds, specification review, code-quality review, and re-reviews. Commit only Task 3 files.

### Task 4: Complete the shared-reading MCP action and observation contract

**Files:**
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift`
- Modify: `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`
- Modify only if stable identifiers are absent: `apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift`
- Modify only if stable identifiers are absent: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`

- [ ] **Step 1: Write red creator-completion tests**

After one new invite is observed, `create_reading_session` must dismiss the composer through its stable `Done` control, then poll until exactly one owner session ID is visible. It returns the invite/token and the owner session ID only after presentation succeeds. A stale invite, multiple invites, failed dismissal, or missing session presentation is a failure.

- [ ] **Step 2: Write red participant-completion tests**

`join_reading_session` may return `submitted: true` only as an intermediate internal value. Its public result must wait for exactly one visible participant session ID, require that it equals the owner session tracked for the token when known, and return `joined: true`. Timeout, onboarding, signed-out state, redemption error, or ambiguous sessions must fail with structured state.

- [ ] **Step 3: Repair the participant-wait schema**

Remove the unused required `text` argument from `wait_for_participant`, or replace it with a validated semantic condition enum that the implementation actually consumes. Tests must prove schema and handler agree. The result continues to require exactly one session ID and one roster signal with `count == 2` and `capacity >= 2` for this acceptance.

- [ ] **Step 4: Add authoritative synchronization semantics**

Parse the DEBUG `shared-reading-progress` accessibility value into `reader.sharedSequence` (`pending` or a positive integer). Parse exactly one `tts-pause`/`tts-play` control into a bounded `reader.playbackControl` value (`pauseAvailable` or `playAvailable`). Do not infer synchronization from a static percentage alone. Add pure extractor tests for missing, unique, malformed, and ambiguous values.

- [ ] **Step 5: Add an explicit room-start tool**

Expose bounded `start_reading_session(app)` for the owner. It presses only `shared-reading-start`, then polls semantic `sessionStatus` until it is `active`. The semantic extractor reads the value of `shared-reading-session-state`. Contract and integration tests require both peers to report the same session ID and `active` before either reader is opened.

- [ ] **Step 6: Add explicit session teardown tools**

Expose bounded `leave_reading_session(app)` and `end_reading_session(app, confirm: true)` tools. Both first press the stable `shared-reading-leave` control; participant leave completes when the session ID disappears. Owner end additionally selects the exact destructive confirmation `Leave and end for everyone` and completes only when the session ID disappears. Tests reject missing confirmation and ambiguous controls.

- [ ] **Step 7: Verify the package contract**

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'AppToolsTests|MCPProtocolTests'
```

Expected: create/join completion, roster, room start, sequence/playback, and teardown tests all pass with no token or account data in failure output.

- [ ] **Step 8: Review and commit**

Run specification review, fix/re-review, then code-quality review, fix/re-review. Commit only Task 4 files.

### Task 5: Prove iPhone MCP launch, inspect, stop, and relaunch

**Files:**
- Modify only if a regression fails: Task 1–4 files
- Evidence only: `/private/tmp/rishi-shared-reading-<run-id>/`

- [ ] **Step 1: Establish zero state without deleting app data**

Stop only MCP-owned processes and terminate the exact `org.fidexa.rishi` process on the recorded iPhone 17 Pro UDID. Do not uninstall the app or erase the simulator. Verify no bridge listener/build lock remains.

- [ ] **Step 2: Run two complete cycles through the MCP**

For each cycle call:

```text
list_app_instances (0) → start_app(iphone17) → inspect_app_state
→ capture_screenshot → stop_app(iphone17) → list_app_instances (0)
```

Each `inspect_app_state` must return explicit auth status. Record only redacted timestamps, tool names, status, target identity, and process IDs/PPIDs/PGIDs/executables.

- [ ] **Step 3: Assert cleanup after each cycle**

The exact iPhone app bundle must not be running, no owned `xcodebuild`/XCTest PID may remain, ports `57421/57422` must not have an unexpected listener, and build locks must be absent.

- [ ] **Step 4: Review evidence**

An independent reviewer must confirm both cycles came from MCP calls, not direct `simctl launch`, and that no manual cleanup was needed.

### Task 6: Run the real two-account shared-reading acceptance

**Files:**
- Modify only if needed: `apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh`
- Modify: `scripts/test-integrity/run-rishi-mcp-acceptance.ts`
- Test: `scripts/test-integrity/run-rishi-mcp-acceptance.test.ts`
- Add: `scripts/test-integrity/run-rishi-codex-acceptance.ts`
- Add: `scripts/test-integrity/run-rishi-codex-acceptance.test.ts`
- Modify: `scripts/test-integrity/verify-shared-reading-release.ts`
- Test: `scripts/test-integrity/verify-shared-reading-release.test.ts`
- Modify: `apps/apple/docs/superpowers/reviews/shared-reading-release-required-tests.json`
- Test: `scripts/test-integrity/run-shared-reading-release.test.ts`
- Modify only if a product defect is reproduced: the smallest Apple shared-reading source/test files that own that defect

- [ ] **Step 1: Remove the stale acceptance memory floor with red tests**

Replace `assertMemory` with a telemetry parser that accepts a non-negative `availableMemoryBytes` when present and records unavailable/malformed telemetry without aborting. Remove `configuredMinimumMemoryBytes` and all low-memory failure assertions. Update the final release verifier so `memory_snapshot` and `cleanup.memoryChecked` are optional telemetry, never required calls or pass conditions. Pass/fail is determined by lifecycle, feature, disk, and process evidence.

- [ ] **Step 2: Make physical process identity authoritative**

The executor records both logical counts and privacy-safe `{pid, ppid, pgid, executable}` identities. Tests make the MCP return one logical Catalyst entry backed by two Catalyst PIDs and require immediate failure/cleanup. The scenario ledger must prove physical counts `[0,1,2,0]`, not only logical list lengths.

- [ ] **Step 3: Bind the run to the enabled Codex registration**

Read `codex mcp get rishi-apple --json`, require an enabled stdio registration, resolve its exact executable and environment, and reject `--mcp-binary`, alternate command, or caller-supplied environment overrides. Record only registration name, executable SHA-256, and environment key names. The wrapper must invoke `codex exec --json` with that registration available; it must not spawn an arbitrary MCP binary directly for the live scenario.

`run-rishi-codex-acceptance.ts` supplies a bounded prompt describing the exact ordered tools and validates Codex JSON events as they arrive. A per-call and whole-run deadline enters deterministic cleanup. Unit tests use fixture event streams to prove required call order, tool/result correlation, redaction, refusal of any non-`rishi-apple` tool, and failure when Codex describes an action without an actual MCP tool event.

- [ ] **Step 4: Update the bounded release tool contract**

The executor and verifier allowlists must include `start_reading_session`, `leave_reading_session`, and `end_reading_session`, require them in the scenario order, and reject arbitrary tools. The final evidence must bind each action to an actual registered-Codex MCP event and its structured result.

Update the `apple-ui-release-gate` manifest entry and normalized `apple-ui.acceptance` command to call `run-rishi-codex-acceptance.ts` (through the bounded shell wrapper if retained), with the registration name `rishi-apple`, owner `catalyst`, participant `iphone17`, SHA, timeout, and evidence root. Remove `--mcp-binary` and `--mcp-client` from both command forms. The release-runner test must fail if either removed flag or the direct `run-rishi-mcp-acceptance.ts` path reappears.

- [ ] **Step 5: Preflight exact state**

Verify current branch SHA, registered `rishi-apple` executable/config, disk guard, ports/locks, zero logical app instances, and zero physical target processes. Start exactly Catalyst and iPhone 17 Pro through the MCP. Require `semanticState.authentication.status == "signedIn"` on both before proceeding.

- [ ] **Step 6: Select the shared book semantically**

Inspect Catalyst state, select the existing imported book using its stable accessibility identifier, and invoke `select_to_share`. Record the identifier, never book content.

- [ ] **Step 7: Create, join, and start one session**

Call `create_reading_session(catalyst, bookIdentifier)`. Pass the returned invite directly to `join_reading_session(iphone17, token)` without logging the token. Require both `wait_for_participant` calls to report the same non-empty session ID, exactly two readers, and capacity at least two. Call `start_reading_session(catalyst)` and require both peers to report that same session as `active` before opening either reader.

- [ ] **Step 8: Prove synchronized reading behavior**

Open the book on both targets. Capture semantic reader state, issue `next_page` from the controller, and require the participant to reach the same page/progress with a newer state. Exercise `pause` and `resume` where those controls are present and require the participant state to follow.

- [ ] **Step 9: Prove teardown**

Participant leaves; owner observes roster reduction. Owner ends the session; both targets no longer expose it. Stop both app targets. Require logical and physical ledgers `[0,1,2,0]` and zero owned descendants/listeners/locks.

- [ ] **Step 10: Classify any failure at its owning boundary**

If launch/inspection fails, return to Tasks 1–5. If the UI action is missing/wrong, add an Apple regression before changing product code. If the production API/room behavior fails, retain redacted route/error evidence and create a separate Worker repair task; do not guess or modify Worker code in this Apple plan.

### Task 7: Final verification, review, and branch handoff

**Files:**
- Update: this plan's task checkboxes and review ledger
- Update if required: existing Apple MCP evidence document

- [ ] **Step 1: Run final package and build gates**

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1
xcodebuild build-for-testing -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi-mcp -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -parallel-testing-enabled NO
xcodebuild build-for-testing -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi-mcp -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO
```

Run Xcode commands sequentially. Expected: exit 0 with no skipped focused regression and no stale owned process afterward.

- [ ] **Step 2: Audit the exact branch diff**

Require no Electron paths, no memory gate, no credentials/evidence binaries, and no unrelated working-tree changes in commits.

- [ ] **Step 3: Final independent review**

A fresh reviewer checks the entire diff plus live evidence against every completion-matrix row. Resolve and re-review all Critical/High findings until PASS.

- [ ] **Step 4: Commit/push/merge only after proof**

Push the reviewed commits to `feat/apple-shared-reading-sessions`. Merge PR #256 only after required GitHub checks pass for that exact head and the final live acceptance is attached/referenced.

## Subagent execution map

| Sequence | Model | Role | Write scope |
|---|---|---|---|
| Research A | Terra | MCP lifecycle and bridge root-cause reviewer | Read-only |
| Research B | Luna | Auth/shared-reading workflow mapper | Read-only |
| Plan review | Terra | Adversarial plan reviewer | Read-only |
| Task 1 | Terra | Complex lifecycle-state implementer | Driver/registry sources and tests listed in Task 1 |
| Task 1 reviews | Luna then Terra | Spec review, then code-quality review | Read-only |
| Task 2 | Terra | XCTest bridge implementer | MCP driver/tests and `MCPControlUITests.swift` |
| Task 2 reviews | Luna then Terra | Spec review, then code-quality review | Read-only |
| Task 3 | Luna | Bounded semantic/auth implementation | Auth/root/UI-test/AppTools files listed in Task 3 |
| Task 3 reviews | Terra then Luna | Spec review, then code-quality review | Read-only |
| Task 4 | Luna | Bounded shared-session tool contract | AppTools/protocol/UI semantic files listed in Task 4 |
| Task 4 reviews | Terra then Luna | Spec review, then code-quality review | Read-only |
| Task 5 | Main controller with one Luna evidence auditor | Live iPhone lifecycle proof; no concurrent agent launches | Evidence only unless a proven defect returns to an implementation task |
| Task 6 implementation | Luna | Acceptance executor memory/process/start-room contract | Acceptance script and tests listed in Task 6; no live apps |
| Task 6 live run | Main controller with one Luna evidence auditor | Live two-account acceptance; no concurrent agent launches | Evidence only unless a proven defect returns to an implementation task |
| Task 7 | Terra | Final branch/evidence review | Read-only |

Implementation subagents work sequentially on disjoint task scopes. They are not alone in the codebase, must preserve existing user changes, must not touch live app/simulator state unless assigned Tasks 4–5, and must report changed files and exact verification output.

## Adversarial review loop

Each round is review → log findings → update plan → re-review.

### Round 1 — independent Terra runtime research review

| # | Sev | Finding | Resolution in this draft |
|---|---|---|---|
| 1 | High | Static target ports are not evidence of the normal configuration path, and no-config `testServer` now fails instead of skipping. | Task 2 distinguishes config/fallback paths and restores safe no-listener behavior. |
| 2 | High | Cleanup can retry the same failed external launch because launch ownership is a Boolean. | Task 1 specifies an explicit terminal launch state and a one-attempt regression. |
| 3 | High | Auth is not a first-class semantic output. | Task 3 adds a mutually exclusive, privacy-safe auth contract. |
| 4 | High | Fresh-handle classifier tests do not prove a usable XCUIApplication connection. | Task 2 replaces classifier proof with a lazy long-lived handle and repeated live operations. |
| 5 | Medium | Snapshot performs broad synchronous accessibility queries under the same 30-second deadline. | Task 2 instruments phases and requires a bounded semantic snapshot if `debugDescription` is the blocker. |
| 6 | Medium | The process tracker explicitly permits an escaped descendant in an existing test. | Task 1 distinguishes never-owned processes from recorded descendants and fails on any recorded survivor. |

**Round 1 result:** all findings have concrete plan changes, but the plan is not yet PASS. A fresh independent plan re-review is required after the Luna workflow report is incorporated.

### Round 2 — independent Luna workflow research review

| # | Sev | Finding | Resolution in this draft |
|---|---|---|---|
| 1 | High | `create_reading_session` returns an invite without dismissing the composer, but the product queues the owner's join only on dismissal. | Task 4 requires stable dismissal and visible owner-session presentation before success. |
| 2 | High | `join_reading_session` reports only URL submission, not redemption/session presentation. | Task 4 makes visible, matching session presentation part of the public success contract. |
| 3 | High | Semantic state omits the authoritative shared progress sequence and playback state. | Task 4 extracts `shared-reading-progress` plus unique TTS control state and tests ambiguity/malformed values. |
| 4 | High | No bounded MCP action exists for participant leave or controller end. | Task 4 adds explicit leave/end tools with completion polling and required destructive confirmation. |
| 5 | Medium | `wait_for_participant` requires a `text` argument that its implementation ignores. | Task 4 aligns schema and implementation around a semantic condition. |
| 6 | Medium | Existing owner UI tests do not explicitly end the room. | Task 6 live acceptance requires controller end and both peers observing session disappearance. |
| 7 | Note | Source review found no confirmed product defect; current failures are harness/observability gaps until live evidence says otherwise. | Tasks preserve product code unless a focused live regression proves a product boundary failure. |

**Round 2 result:** all findings are represented, but this author-updated plan still requires a fresh independent adversarial re-review before implementation.

### Round 3 — independent Terra plan review

| # | Sev | Finding | Resolution in this revision |
|---|---|---|---|
| 1 | Critical | The actual TypeScript executor still enforces `configuredMinimumMemoryBytes`, but it was absent from plan ownership. | Task 6 owns the executor/tests, removes the floor, and treats memory only as optional telemetry. |
| 2 | Critical | `InstanceRegistry` lifecycle calls can fail or terminate the app when telemetry fails. | Task 1 owns registry/tests and requires lifecycle success with unavailable telemetry. |
| 3 | Critical | The live flow never presses `shared-reading-start`, so synchronization cannot become authoritative. | Task 4 adds `start_reading_session`; Task 6 requires `active` on both peers before opening readers. |
| 4 | Critical | Requiring `2/2` rejects a valid `2/5` roster. | Every gate now requires exactly two readers and capacity at least two. |
| 5 | High | A marker on `WelcomeScreen` does not cover the complete onboarding overlay and can conflict with the background auth branch. | Task 3 moves the marker to `OnboardingHost`, gives it precedence, and tests every stage. |
| 6 | High | Logical `[0,1,2,0]` can hide duplicate target processes because driver listing collapses targets into a set. | Tasks 1 and 6 add privacy-safe physical process identities, duplicate rejection, and a physical `[0,1,2,0]` ledger. |

**Round 3 result:** all six findings have concrete changes. A fresh independent re-review of this updated revision is required.

### Round 4 — independent Terra re-review

| # | Sev | Finding | Resolution in this revision |
|---|---|---|---|
| 1 | High | The release verifier rejects the newly required start/leave/end tools. | Task 6 owns verifier/tests and updates the exact bounded tool sequence. |
| 2 | High | Final verification still requires memory calls and `memoryChecked`. | Task 6 makes memory entirely optional in executor and verifier schemas. |
| 3 | High | The direct runner can spawn an arbitrary binary, so it cannot prove registered Codex use. | Task 6 rejects binary/env overrides and drives the live scenario through `codex exec --json` using the enabled `rishi-apple` registration, with fixture-tested event validation. |
| 4 | Low | The token rule contradicted the required owner-to-participant handoff. | The rule now permits in-memory local handoff only and forbids logging/persistence/external transmission. |

**Round 4 result:** all findings have concrete changes. A fresh independent re-review is required before implementation.

### Round 5 — independent Terra re-review

| # | Sev | Finding | Resolution in this revision |
|---|---|---|---|
| 1 | High | The checked-in required-test manifest still invokes direct acceptance with `--mcp-binary`, so the release gate cannot execute the new registered-Codex contract. | Task 6 now owns the manifest and release-runner test, replaces the Apple acceptance command, and forbids both removed direct-runner flags. |

**Round 5 result:** the finding has a concrete change. A fresh independent re-review is required before implementation.

### Round 6 — independent Terra final re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| — | — | No remaining execution blocker. | The plan owns the release manifest/test, registered-Codex path, optional memory telemetry, room start, capacity semantics, onboarding precedence, and physical duplicate detection. |

**Round 6 result:** **PASS** — 0 open Critical, High, or Medium findings.
