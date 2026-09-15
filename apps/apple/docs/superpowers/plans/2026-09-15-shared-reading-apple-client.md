# Shared Reading Apple Client Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Apple app converge on authoritative shared-reading state across transient failures, restart/rejoin, sign-out, account switching, and account deletion while preserving native Catalyst and iPhone interaction behavior.

**Architecture:** The signaling client owns one bounded reconnect loop; the coordinator applies separately typed authority fences and reader sequence. A composition-root registry owns every live shared-reading session and drains account-scoped work before identity changes can publish UI. `/active` plus `/rejoin` restores a fresh admission and server snapshot after restart.

**Tech Stack:** Swift 6, Swift Concurrency, SwiftUI, URLSession/WebSocket, WebRTC data channels, Swift Testing, XCTest, Xcode/Catalyst/iPhone Simulator.

---

## File ownership map

- Recovery owner: `SharedReadingModels.swift`, `SharedReadingErrors.swift`, `SharedReadingAPI.swift`, `Transport/SharedReadingSignalingClient.swift`, `SharedReadingSessionCoordinator.swift`, `ActiveReadingSessionsView.swift`, related focused tests.
- Lifecycle owner: `ActiveReadingSessionStore.swift`, `PendingSessionInviteStore.swift`, `SharedSessionProgressStore.swift`, `ServiceGraphFactory.swift`, `rishiApp.swift`, `RootView.swift`, `Auth/SignedOutViewModel.swift`, `Account/AccountDeletionCoordinator.swift`, new registry/tests.
- Semantic UI owner: library grid/root/tab, shared-reading views, reader
  destination/views, stable accessibility identifiers, and semantic UI tests.
  M3 alone owns `MCPControlUITests.swift` after this interface is published.
- No Apple agent edits Worker files, MCP process ownership files, Electron assets, screenshots, or marketing scripts.

## Mandatory command/result wrapper

No raw `xcodebuild` command below is itself accepted as a test/build gate. Run it
through `scripts/test-integrity/run-verified.ts`. Tests include a unique path such
as `-resultBundlePath /private/tmp/A2.xcresult` and use format `xcresult`;
builds use format `command`. Every green test requires discovered `> 0`, skipped/
failed `0`, and exit `0`; every red test requires discovered/failed `> 0` and
nonzero exit. Missing/unparseable result bundles fail. The literal command shown
is passed after `--`; artifact names use `A0`, `A1`, `A2`, `A3`, `A4`, or `A5`.

## Task A0: Freeze DTO and generation contracts with red tests

**Files:**

- Modify: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingModelsTests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingGenerationTests.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingModels.swift`

- [ ] **Step 1: Add distinct generation value types**

First write a compiling static contract test that reads
`SharedReadingModels.swift` and requires four distinct type declarations; this
produces a discoverable red rather than an unparseable compile failure:

```swift
@Test func generationTypesAreDeclaredAndDistinct() throws {
    let source = try sharedReadingModelsSource()
    for name in ["SharedReadingRoomEpoch", "SharedReadingRosterGeneration",
                 "SharedReadingControllerGeneration", "SharedReadingConnectionGeneration"] {
        #expect(source.contains("struct \(name):"))
    }
}
```

After implementation, add compiled construction/DTO tests that prove the four
types conform as required and cannot be interchanged at API boundaries; keep the
static contract test unchanged.

Run:

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SharedReadingGenerationTests/generationTypesAreDeclaredAndDistinct()" --artifact /private/tmp/A0-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A0-red.xcresult -only-testing:rishiTests/SharedReadingGenerationTests
```

Expected red: the named types do not exist.

- [ ] **Step 2: Implement the value types and DTO decoding**

Add:

```swift
struct SharedReadingRoomEpoch: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
struct SharedReadingRosterGeneration: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
struct SharedReadingControllerGeneration: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
struct SharedReadingConnectionGeneration: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
```

Update DTOs so room, roster, controller, and connection fields use only their
matching type. Remove any comparison of `rosterGeneration` to `roomEpoch`.

- [ ] **Step 3: Prove old and stale events are rejected by their own fence**

Add a table test that sends a stale room, roster, controller, connection, and
reader sequence independently and asserts current state is unchanged.

- [ ] **Step 4: Run focused tests and commit**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A0-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A0-green.xcresult -only-testing:rishiTests/SharedReadingModelsTests -only-testing:rishiTests/SharedReadingGenerationTests
git add apps/apple/rishi/rishi/SharedReading/SharedReadingModels.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingModelsTests.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingGenerationTests.swift
git commit -m "fix(apple): separate shared reading generations"
```

Expected green: discovered `> 0`, skipped/failed `0`, exit `0`.

## Task A1: Repair signaling reconnect and authoritative handshake reset

**Files:**

- Modify: `apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingErrors.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingReconnectTests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingCoordinatorFenceTests.swift`

- [ ] **Step 1: Write a deterministic reconnect red test**

Use an injected clock/sleeper and scripted socket/admission providers:

```swift
@Test func retryBackoffResetsOnlyAfterAuthoritativeState() async throws {
    let clock = RecordingReconnectClock()
    let harness = SignalingHarness(clock: clock, outcomes: [.transportFailure, .openedWithoutState, .authoritativeState])
    await harness.client.connect()
    #expect(clock.delays == [.milliseconds(250), .milliseconds(500)])
    #expect(await harness.client.retryAttempt == 0)
}
```

Add tests for bearer refresh, admission refresh, terminal ended/removed/forbidden/
incompatible-book, explicit cancellation, and one-loop-only concurrency.

Run before implementation:

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SharedReadingReconnectTests/retryBackoffResetsOnlyAfterAuthoritativeState()" --artifact /private/tmp/A1-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A1-red.xcresult -only-testing:rishiTests/SharedReadingReconnectTests -only-testing:rishiTests/SharedReadingCoordinatorFenceTests
```

Expected: wrapper confirms discovered/failed `> 0`, skipped `0`, underlying exit
nonzero. Missing/unparseable results or a passing test blocks implementation.

- [ ] **Step 2: Implement one cancellable reconnect task**

The state machine must expose this shape:

```swift
enum SharedReadingReconnectDecision: Equatable {
    case retry(after: Duration)
    case refreshBearer
    case refreshAdmission
    case stop(SharedReadingErrorCode)
}
```

Store exactly one `Task<Void, Never>?`. Increment bounded exponential backoff on
retryable failures. Reset the attempt only when a validated `session.state`
arrives. Cancel and nil the task on explicit disconnect or terminal state.

- [ ] **Step 3: Apply server events through typed fences**

Coordinator acceptance order:

```swift
guard event.sessionID == sessionID else { return }
if event.roomEpoch > roomEpoch {
    resetSubordinateFences(for: event.roomEpoch)
} else {
    guard event.roomEpoch == roomEpoch else { return }
}
guard event.rosterGeneration >= rosterGeneration else { return }
guard event.controllerGeneration >= controllerGeneration else { return }
guard event.connectionGeneration >= connectionGeneration else { return }
guard event.sequence > acceptedReaderSequence else { return }
```

Only compare like types. A strictly newer room epoch atomically clears roster,
controller, connection, accepted-reader-sequence, and locally buffered reader
state before applying the new authoritative tuple. Within an equal epoch, reject
stale roster, controller, connection, and reader values independently. Tests
cover every reset and a mixed tuple containing one stale subordinate value.

Implement the reset in the coordinator before evaluating subordinate fields:

```swift
private func resetSubordinateFences(for epoch: SharedReadingRoomEpoch) {
    roomEpoch = epoch
    rosterGeneration = .init(rawValue: 0)
    controllerGeneration = .init(rawValue: 0)
    connectionGeneration = .init(rawValue: 0)
    acceptedReaderSequence = 0
    bufferedReaderState = nil
}
```

- [ ] **Step 4: Run red/green focused tests**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A1-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A1-green.xcresult -only-testing:rishiTests/SharedReadingReconnectTests -only-testing:rishiTests/SharedReadingCoordinatorFenceTests
```

Expected: controlled-clock tests pass without wall-clock sleeps; discovered
`> 0`, skipped/failed `0`, exit `0`.

- [ ] **Step 5: Commit recovery-owned files**

```bash
git add apps/apple/rishi/rishi/SharedReading/Transport/SharedReadingSignalingClient.swift apps/apple/rishi/rishi/SharedReading/SharedReadingSessionCoordinator.swift apps/apple/rishi/rishi/SharedReading/SharedReadingErrors.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingReconnectTests.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingCoordinatorFenceTests.swift
git commit -m "fix(apple): recover shared reading signaling"
```

## Task A2: Make `/active` restart recovery authoritative

**Files:**

- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionStore.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`
- Modify: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingActiveRecoveryTests.swift`

- [ ] **Step 1: Write API route and retry-classification tests**

Assert exact paths:

```swift
#expect(transport.requests.map(\.url.path) == [
    "/api/v1/reading-sessions/active",
    "/api/v1/reading-sessions/session-1/rejoin",
])
```

Test owner/participant response decoding, retryable upstream failure, terminal
removed/ended, one 401 bearer refresh, and fresh admission ticket replacement.

Run before implementation:

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SharedReadingActiveRecoveryTests/activeAndRejoinUseVersionedRoutes()" --artifact /private/tmp/A2-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A2-red.xcresult -only-testing:rishiTests/SharedReadingAPITests -only-testing:rishiTests/SharedReadingActiveRecoveryTests
```

Expected: wrapper confirms discovered/failed `> 0`, skipped `0`, underlying exit
nonzero. Otherwise do not proceed.

- [ ] **Step 2: Implement an explicit recovery result**

Use:

```swift
struct SharedReadingRecoveredSession: Sendable {
    let summary: SharedReadingActiveSession
    let admission: SharedReadingAdmission
    let importedContentHash: String
}
```

The view/store first fetches `/active`, validates local content hash, then calls
`/rejoin`. It never reconstructs an invite or reuses an admission ticket.

- [ ] **Step 3: Require a fresh authoritative snapshot before presenting reader state**

Keep the reconnecting surface visible until coordinator publishes a matching
server state/roster/snapshot tuple. Do not read cached progress as proof of
recovery. The accepted snapshot sequence must be greater than the pre-restart
sequence captured by the live test.

- [ ] **Step 4: Run focused tests and commit**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A2-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A2-green.xcresult -only-testing:rishiTests/SharedReadingAPITests -only-testing:rishiTests/SharedReadingActiveRecoveryTests
git add apps/apple/rishi/rishi/SharedReading/SharedReadingAPI.swift apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionsView.swift apps/apple/rishi/rishi/SharedReading/ActiveReadingSessionStore.swift apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingAPITests.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingActiveRecoveryTests.swift
git commit -m "fix(apple): rejoin active reading sessions"
```

## Task A3: Drain account-scoped sessions at the composition root

**Files:**

- Create: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionRegistry.swift`
- Create: `apps/apple/rishi/rishiTests/SharedReading/SharedReadingSessionRegistryTests.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Modify: `apps/apple/rishi/rishi/rishiApp.swift`
- Modify: `apps/apple/rishi/rishi/RootView.swift`
- Modify: `apps/apple/rishi/rishi/Auth/SignedOutViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Account/AccountDeletionCoordinator.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/PendingSessionInviteStore.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedSessionProgressStore.swift`

- [ ] **Step 1: Write lifecycle matrix tests**

Use one registry spy and cover leave, end, sign-out, account switch, owner
deletion, participant deletion, participant-controller deletion, timeout, and
delayed account-A callback after account B signs in.

```swift
@Test func accountSwitchDrainsOldIdentityBeforePublishingNewIdentity() async {
    let registry = SharedReadingSessionRegistrySpy()
    let model = SignedOutViewModel(sessionRegistry: registry)
    await model.switchAccount(from: "account-a", to: "account-b")
    #expect(registry.events == [.drain("account-a"), .activate("account-b")])
}
```

Run before implementation:

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SignedOutViewModelTests/accountSwitchDrainsOldIdentityBeforePublishingNewIdentity()" --artifact /private/tmp/A3-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A3-red.xcresult -only-testing:rishiTests/SharedReadingSessionRegistryTests -only-testing:rishiTests/SignedOutViewModelTests
```

Expected: wrapper confirms discovered/failed `> 0`, skipped `0`, underlying exit
nonzero. Otherwise do not proceed.

- [ ] **Step 2: Implement the single registry contract**

```swift
@MainActor
protocol SharedReadingSessionRegistering: AnyObject {
    func register(_ session: SharedReadingSessionHandle, accountID: String)
    func unregister(sessionID: String)
    func drain(accountID: String, deadline: Duration) async -> SharedReadingDrainReport
}
```

Drain performs best-effort leave, cancels signaling/peer/media/TTS tasks, clears
pending presentation/invite/progress state, and returns explicit transport and
local-registry quiescence. Identity generation guards prevent delayed callbacks
from publishing under a new account.

- [ ] **Step 3: Install exactly one registry in app composition**

`ServiceGraphFactory` constructs it once. `rishiApp`/`RootView` inject the same
instance into session creation, auth transitions, and deletion. Do not construct
a registry per view or sheet.

- [ ] **Step 4: Enforce bounded observable cleanup**

Tests use a 30-second logical deadline, explicit registry/transport drained
signals, authoritative session status, then three probes one second apart. Any
timeout, contradiction, or inconclusive probe fails.

- [ ] **Step 5: Run lifecycle tests and commit**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A3-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A3-green.xcresult -only-testing:rishiTests/SharedReadingSessionRegistryTests -only-testing:rishiTests/SignedOutViewModelTests
git add apps/apple/rishi/rishi/SharedReading/SharedReadingSessionRegistry.swift apps/apple/rishi/rishiTests/SharedReading/SharedReadingSessionRegistryTests.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/rishiApp.swift apps/apple/rishi/rishi/RootView.swift apps/apple/rishi/rishi/Auth/SignedOutViewModel.swift apps/apple/rishi/rishi/Account/AccountDeletionCoordinator.swift apps/apple/rishi/rishi/SharedReading/PendingSessionInviteStore.swift apps/apple/rishi/rishi/SharedReading/SharedSessionProgressStore.swift apps/apple/rishi/rishiTests/SignedOutViewModelTests.swift
git commit -m "fix(apple): drain shared sessions on account changes"
```

## Task A4: Preserve native gestures and expose stable semantic controls

**Files:**

- Modify: `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift`
- Modify: `apps/apple/rishi/rishi/Library/LibraryRootView.swift`
- Modify: `apps/apple/rishi/rishi/Library/LibraryTabView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift`
- Modify: `apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift`
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestinationView.swift`
- Create: `apps/apple/rishi/rishiUITests/SharedReadingSemanticControlTests.swift`

- [ ] **Step 1: Write gesture and identifier red tests**

Assert one primary click/tap opens the book. On Catalyst, secondary/two-finger
click presents the context menu. On touch iPhone, long press presents it. All
MCP actions target stable identifiers derived from deterministic book ID.

```swift
let bookID = "library.book.\(deterministicBookID)"
XCTAssertTrue(app.descendants(matching: .any)[bookID].waitForExistence(timeout: 5))
```

Run both platforms before implementation, serialized and only after the resource
gate:

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SharedReadingSemanticControlTests/testPrimaryClickOpensBookAndSecondaryClickShowsActions" --artifact /private/tmp/A4-catalyst-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -resultBundlePath /private/tmp/A4-catalyst-red.xcresult -only-testing:rishiUITests/SharedReadingSemanticControlTests
bun scripts/test-integrity/run-verified.ts --format xcresult --expect fail --require-failure-id "SharedReadingSemanticControlTests/testTapOpensBookAndLongPressShowsActions" --artifact /private/tmp/A4-iphone-red.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A4-iphone-red.xcresult -only-testing:rishiUITests/SharedReadingSemanticControlTests
```

Expected: each wrapper confirms discovered/failed `> 0`, skipped `0`, underlying
exit nonzero. A missing result or unexpected pass blocks implementation.

- [ ] **Step 2: Separate primary activation from context menu**

Use a `Button`/navigation action for opening and SwiftUI `.contextMenu` for
actions. Do not attach a competing zero-duration long-press or drag gesture to
the primary surface. Preserve Catalyst secondary-click and iPhone long-press.

- [ ] **Step 3: Expose the fixed semantic action set**

The bridge may address only identifiers such as:

```swift
enum MCPAccessibilityID {
    static func book(_ id: String) -> String { "library.book.\(id)" }
    static let create = "shared-reading-create-link"
    static let start = "shared-reading-start"
    static let openBook = "shared-reading-open-book"
    static let leave = "shared-reading-leave"
    static let active = "shared-reading-active-sessions"
    static let progress = "shared-reading-progress"
}
```

Raw coordinates remain internal to Catalyst XCTest activation and are not an MCP
tool. No title-only or list-index selectors are accepted.

- [ ] **Step 4: Run focused UI tests under the resource gate**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A4-catalyst-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -resultBundlePath /private/tmp/A4-catalyst-green.xcresult -only-testing:rishiUITests/SharedReadingSemanticControlTests
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A4-iphone-green.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A4-iphone-green.xcresult -only-testing:rishiUITests/SharedReadingSemanticControlTests
```

Expected: single activation opens; context gesture shows actions; discovered
`> 0`, skipped/failed `0`, exits `0`.

- [ ] **Step 5: Commit semantic UI files**

```bash
git diff --name-only -- apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift apps/apple/rishi/rishi/Library/LibraryRootView.swift apps/apple/rishi/rishi/Library/LibraryTabView.swift apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift apps/apple/rishi/rishi/Reader/ReaderDestinationView.swift apps/apple/rishi/rishiUITests/SharedReadingSemanticControlTests.swift
git add apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryGrid.swift apps/apple/rishi/rishi/Library/LibraryRootView.swift apps/apple/rishi/rishi/Library/LibraryTabView.swift apps/apple/rishi/rishi/SharedReading/SharedReadingShareComposerView.swift apps/apple/rishi/rishi/SharedReading/SharedReadingSessionView.swift apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift apps/apple/rishi/rishi/Reader/ReaderDestinationView.swift apps/apple/rishi/rishiUITests/SharedReadingSemanticControlTests.swift
git commit -m "fix(apple): expose shared reading controls"
```

## Task A5: Apple verification and independent review

**Files:** Apple files changed by A0-A4; review evidence only

- [ ] **Step 1: Run focused non-live suites**

```bash
bun scripts/test-integrity/run-verified.ts --format xcresult --expect pass --artifact /private/tmp/A5-unit.xcresult --cwd . -- xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -resultBundlePath /private/tmp/A5-unit.xcresult -only-testing:rishiTests/SharedReadingModelsTests -only-testing:rishiTests/SharedReadingGenerationTests -only-testing:rishiTests/SharedReadingReconnectTests -only-testing:rishiTests/SharedReadingCoordinatorFenceTests -only-testing:rishiTests/SharedReadingAPITests -only-testing:rishiTests/SharedReadingActiveRecoveryTests -only-testing:rishiTests/SharedReadingSessionRegistryTests -only-testing:rishiTests/SharedReadingSessionRepairTests
```

Expected: discovered `> 0`, skipped/failed `0`, exit `0`.

- [ ] **Step 2: Build fresh serialized products**

Only after host available memory is at least 8 GiB and disk at least 20 GiB:

```bash
set -euo pipefail
bun scripts/test-integrity/run-verified.ts --format command --expect pass --artifact /private/tmp/A5-catalyst-preflight-command.json --cwd . -- bun scripts/test-integrity/resource-preflight.ts --min-available-memory-gib 8 --min-free-disk-gib 20 --target catalyst --artifact /private/tmp/A5-catalyst-preflight.json
bun scripts/test-integrity/run-verified.ts --format command --expect pass --resource-artifact /private/tmp/A5-catalyst-preflight.json --owned-output-root /private/tmp/rishi-shared-reading-catalyst-derived --artifact /private/tmp/A5-catalyst-build.json --cwd . -- xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/rishi-shared-reading-catalyst-derived
bun scripts/test-integrity/run-verified.ts --format command --expect pass --artifact /private/tmp/A5-iphone-preflight-command.json --cwd . -- bun scripts/test-integrity/resource-preflight.ts --min-available-memory-gib 8 --min-free-disk-gib 20 --target iphone17pro --artifact /private/tmp/A5-iphone-preflight.json
bun scripts/test-integrity/run-verified.ts --format command --expect pass --resource-artifact /private/tmp/A5-iphone-preflight.json --owned-output-root /private/tmp/rishi-shared-reading-iphone-derived --artifact /private/tmp/A5-iphone-build.json --cwd . -- xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /private/tmp/rishi-shared-reading-iphone-derived
```

Expected: serialized exits `0`; bundle IDs, versions, Mach-O UUIDs/hashes, build
SHA, target UDID/OS, install times, fresh resource digests, build PID/start-time/
descendants, and owned derived-data roots are captured for the live plan. Each
build rejects a preflight older than ten seconds, a duplicate target process,
or an unreconciled descendant.

- [ ] **Step 3: Independent specification review**

Reviewer checks all Apple design requirements and test semantics. Resolve and
re-review all Critical/High findings.

- [ ] **Step 4: Independent code-quality/concurrency review**

Separate reviewer checks actor isolation, task cancellation, retain cycles,
cross-account callbacks, stale fences, reader sequence, view-owned coordinator
lifetime, gesture conflicts, and secret logging. Resolve and re-review all
Critical/High findings.

- [ ] **Step 5: Verify endpoint centralization**

```bash
rg -n '127\.0\.0\.1|localhost|rishi\.fidexa\.org/api/auth' apps/apple/rishi/rishi
```

Expected: no shared-reading Debug/Release fallback; HTTP is
`https://api.fidexa.org`, WebSocket is `wss://sharing.fidexa.org`.

## Adversarial plan review

### Round 1 — Terra

**Verdict:** RE-REVIEW REQUIRED. A1 previously accepted a newer room epoch but
then compared reset subordinate counters against stale local controller/
connection fences, and omitted roster generation. A1 now atomically resets every
subordinate fence on a strictly newer epoch and independently checks roster,
controller, connection, and sequence only within the accepted epoch. A4 no
longer shares ownership of `MCPControlUITests.swift`; it publishes accessibility
identifiers consumed later by M3. Re-review is required.

Round 2 found that accepted Apple test gates still bypassed the mandatory
integrity wrapper. Every red and green XCTest invocation now emits a fresh,
unique xcresult bundle parsed by the fail-closed runner. Fresh independent PASS
is required.

Final Terra and Luna verdict: **PASS**, zero open Critical/High findings.
