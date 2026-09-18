# Shared-Reading Repeatable Local E2E Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** Adversarial review complete — **PASS** (19 rounds, 0 open Critical/High/Medium findings).

**Goal:** Add a canonical Swift/XCTest regression that repeatedly proves a Catalyst owner and iPhone 17 Pro participant can share one live reading session, while deleting both temporary accounts and leaving no owned process, lock, or recovery residue.

**Architecture:** Extract the existing CLI composition into `SharedReadingLiveRun`, backed by an atomic redacted recovery journal shared by account, process, and lock lifecycle collaborators. Keep `SharedReadingHost` and the two existing UI tests as the scenario engine; the new live XCTest invokes the shared composition root and asserts its explicit evidence. A thin Apple-local shell wrapper runs deterministic package tests followed by the focused live XCTest.

**Tech Stack:** Swift 6, XCTest, Foundation, Darwin `proc_pidinfo`, Xcode UI testing, zsh.

**Approved design:** `apps/apple/docs/superpowers/specs/2026-09-17-shared-reading-live-e2e-test-design.md`

---

## File structure

### Create

- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift` — redacted persistent recovery state, unresolved-artifact discovery, exact account/process/lock recovery.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingLiveRun.swift` — shared environment parsing and real live-run composition used by CLI and XCTest.
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift` — atomic journal, fail-closed recovery, PID reuse, and artifact-removal tests.
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveRunTests.swift` — configuration ordering, unresolved-artifact, cleanup, and evidence tests using injected collaborators.
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveEndToEndTests.swift` — sole real-network/two-peer XCTest.
- `apps/apple/rishi/rishi/E2EProcessRegistration.swift` — launch-gated Catalyst app callback to the authenticated loopback relay; inactive outside explicit live E2E launches.
- `apps/apple/rishi/rishiTests/E2EProcessRegistrationTests.swift` — focused app-side registration gate tests.
- `apps/apple/scripts/validate-shared-reading.sh` — thin deterministic-then-live local runner.
- `apps/apple/scripts/validate-shared-reading.test.sh` — fake-`swift` wrapper contract tests; never starts Xcode or an app.

### Modify

- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift` — lifecycle recorder and authoritative second-delete verification.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift` — stable process identity and journal recording for roots/descendants.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift` — public lock ownership metadata and exact-generation reconciliation.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift` — typed participant-progress evidence accessor.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift` — split safe destination preflight from package resolution; no scenario behavior changes.
- `apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift` — argument handling delegating to the shared live runner/recovery API.
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ProcessRunnerTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift`
- `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift`
- `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift` — synchronous stable-process registration helper.
- `apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift` — self-register the Catalyst runner and require the app-side launch callback before scenario actions.
- `apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift` — preserve the intentional rejoin restart but remove the deferred cleanup relaunch on the disposable simulator.
- `apps/apple/rishi/rishi/rishiApp.swift` — invoke the Catalyst registration gate at the beginning of app initialization.
- `apps/apple/rishi-e2e-host/README.md`

Do not modify `Package.swift`: SwiftPM discovers the new files automatically. Do not modify MCP, Electron, Worker, GitHub workflow, or unrelated Apple app files. Preserve the existing uncommitted MCP/UI-test changes without staging them.

## Public contracts to implement

```swift
public struct OwnedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let birthTimeSeconds: UInt64
    public let birthTimeMicroseconds: UInt64
}

public struct OwnedProcessGroup: Codable, Hashable, Sendable {
    public let processGroupID: Int32
    public let leader: OwnedProcessIdentity
}

public struct OwnedSimulatorDevice: Codable, Hashable, Sendable {
    public let udid: String?
    public let name: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String
}

public struct PendingCatalystLaunch: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case runner, app }
    public let role: TestAccountRole
    public let kind: Kind
    public let bundleIdentifier: String
    public let baselineIdentities: Set<OwnedProcessIdentity>
    public let registeredIdentity: OwnedProcessIdentity?
}

public protocol OwnedProcessRecording: Sendable {
    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws
    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws
    func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws
    func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws
    func recordCatalystRegisteredIdentity(
        _ identity: OwnedProcessIdentity,
        role: TestAccountRole,
        kind: PendingCatalystLaunch.Kind
    ) throws
}

public enum TestAccountProvisioningOutcome: String, Codable, Sendable {
    case pending
    case recoverable
}

public protocol TestAccountLifecycleRecording: Sendable {
    func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws
    func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws
    func recordVerifiedDeletion(_ email: String) throws
}

public struct AppleXcodeBuildLockOwnership: Codable, Equatable, Sendable {
    public let path: String
    public let token: String
    public let generation: String
    public let owner: OwnedProcessIdentity
}

public final class AppleXcodeBuildLock: @unchecked Sendable {
    public let ownership: AppleXcodeBuildLockOwnership
    public func release() throws
    public func transferToRecovery() -> AppleXcodeBuildLockOwnership
    public static func reconcileRetainedLock(
        ownership: AppleXcodeBuildLockOwnership
    ) throws
}

public struct SharedReadingLiveEvidence: Codable, Sendable, Equatable {
    public let runID: String
    public let participantProgressSequence: Int64
    public let deletedAccountCount: Int
}

public enum SharedReadingLiveRun {
    public static func preflight(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws

    public static func execute(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> SharedReadingLiveEvidence
}
```

The implementation may keep test-only dependency injection internal, but the production entry point above must compose only real collaborators.

## Implementation order

1. Record the focused live-test red phase.
2. Add the recovery journal.
3. Close account provisioning/deletion recovery gaps.
4. Add stable process identity persistence and recovery.
5. Add exact build-lock ownership persistence and reconciliation.
6. Implement complete fail-closed recovery orchestration.
7. Extract the shared live runner and explicit relay evidence.
8. Wire the canonical XCTest and CLI.
9. Add/test the local wrapper and docs.
10. Run deterministic verification, then two consecutive live validations.

---

### Task 1: Establish the canonical XCTest red phase

**Files:**
- Create: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveEndToEndTests.swift`

- [ ] **Step 1: Add the gated acceptance test with an intentional live-mode failure**

```swift
import XCTest
@testable import RishiE2EHost

final class SharedReadingLiveEndToEndTests: XCTestCase {
    func testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress() async throws {
        guard ProcessInfo.processInfo.environment["RISHI_E2E_RUN_LIVE"] == "1" else {
            throw XCTSkip("Set RISHI_E2E_RUN_LIVE=1 only for an explicitly configured local live run.")
        }

        XCTFail("SharedReadingLiveRun has not been wired yet")
    }
}
```

- [ ] **Step 2: Prove ordinary package tests remain safe**

Run:

```sh
env -u RISHI_E2E_RUN_LIVE \
  -u RISHI_E2E_ALLOW_NETWORK \
  -u RISHI_E2E_ALLOW_SIMULATOR_RESET \
  swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: exit `0`; the live test is reported skipped; no Xcode, simulator, relay, or network action begins.

- [ ] **Step 3: Record the focused RED result**

Run:

```sh
RISHI_E2E_RUN_LIVE=1 \
  swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
```

Expected: non-zero with `SharedReadingLiveRun has not been wired yet`.

- [ ] **Step 4: Commit only the new test**

```sh
git add apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveEndToEndTests.swift
git commit -m "test(apple): define shared reading live acceptance"
```

---

### Task 2: Add the atomic redacted recovery journal

**Files:**
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- Create: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`

- [ ] **Step 1: Write failing persistence and discovery tests**

Add tests with these exact behaviors:

```swift
func testJournalPersistsOnlyRecoverySafeFieldsAtomically() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
    let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")

    try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)

    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("rishi-e2e-owner@example.test"))
    XCTAssertFalse(text.contains("password"))
    XCTAssertFalse(text.contains("bearer"))
    XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)
}

func testJournalRemovesAddressOnlyAfterVerifiedDeletion() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try SharedReadingRecoveryJournal(
        url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
        runID: "run-1"
    )
    try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
    XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
    try journal.recordVerifiedDeletion("rishi-e2e-owner@example.test")
    try journal.finalizeAfterSuccessfulCleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
}

private func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rishi-recovery-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

Also add:

- `testUnresolvedArtifactFindsEarlyJournalBeforeLaterManifest`
- `testMalformedRecoveryArtifactFailsClosed`
- `testJournalUpdateNeverLeavesPartialJSON`

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
```

Expected: compile failure because `SharedReadingRecoveryJournal` does not exist.

- [ ] **Step 3: Implement the journal model and atomic store**

First define the foundational recovery value types and protocols in this new source file so Task 2 compiles independently; Tasks 3–5 add their behavior without relocating the declarations:

```swift
public struct OwnedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let birthTimeSeconds: UInt64
    public let birthTimeMicroseconds: UInt64
}

public struct OwnedProcessGroup: Codable, Hashable, Sendable {
    public let processGroupID: Int32
    public let leader: OwnedProcessIdentity
}

public struct OwnedSimulatorDevice: Codable, Hashable, Sendable {
    public let udid: String?
    public let name: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String
}

public struct PendingCatalystLaunch: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case runner, app }
    public let role: TestAccountRole
    public let kind: Kind
    public let bundleIdentifier: String
    public let baselineIdentities: Set<OwnedProcessIdentity>
    public let registeredIdentity: OwnedProcessIdentity?
}

public protocol OwnedProcessRecording: Sendable {
    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws
    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws
    func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws
    func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws
    func recordCatalystRegisteredIdentity(
        _ identity: OwnedProcessIdentity,
        role: TestAccountRole,
        kind: PendingCatalystLaunch.Kind
    ) throws
}

public enum TestAccountProvisioningOutcome: String, Codable, Sendable {
    case pending
    case recoverable
}

public protocol TestAccountLifecycleRecording: Sendable {
    func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws
    func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws
    func recordVerifiedDeletion(_ email: String) throws
}

public struct AppleXcodeBuildLockOwnership: Codable, Equatable, Sendable {
    public let path: String
    public let token: String
    public let generation: String
    public let owner: OwnedProcessIdentity
}
```

Then implement a lock-protected class with `public let url: URL` whose encoded state contains only:

```swift
struct RecoveryState: Codable, Equatable {
    var runID: String
    var accounts: [RecordedAccount]
    var processGroups: Set<OwnedProcessGroup>
    var processes: Set<OwnedProcessIdentity>
    var simulatorDevices: Set<OwnedSimulatorDevice>
    var pendingCatalystLaunches: Set<PendingCatalystLaunch>
    var secretArtifactRelativePaths: Set<String>
    var buildLock: AppleXcodeBuildLockOwnership?
}

struct RecordedAccount: Codable, Equatable {
    var email: String
    var role: TestAccountRole
    var outcome: TestAccountProvisioningOutcome
}
```

Every mutation must encode sorted JSON and use `Data.write(options: [.atomic])`, followed by `chmod 0600`. `unresolvedArtifact(in:)` scans only direct children named `rishi-shared-reading-*` and accepts only `recovery.json` or `manifest.json`; it must not recurse broadly or delete anything.

Provide no-op recorders for deterministic callers:

```swift
public struct NoopTestAccountLifecycleRecorder: TestAccountLifecycleRecording {
    public init() {}
    public func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws {}
    public func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {}
    public func recordVerifiedDeletion(_ email: String) throws {}
}

public struct NoopOwnedProcessRecorder: OwnedProcessRecording {
    public init() {}
    public func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {}
    public func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {}
    public func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {}
    public func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {}
    public func recordCatalystRegisteredIdentity(_ identity: OwnedProcessIdentity, role: TestAccountRole, kind: PendingCatalystLaunch.Kind) throws {}
}
```

- [ ] **Step 4: Run focused and package tests**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: focused tests pass; deterministic suite passes with the live test skipped.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift
git commit -m "feat(apple): persist shared reading recovery state"
```

---

### Task 3: Journal provisioning before the request and verify deletion authoritatively

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`

- [ ] **Step 1: Write failing account lifecycle tests**

Add:

```swift
func testJournalRecordsGeneratedAddressBeforeProvisioningRequest() async throws {
    let recorder = RecordingAccountLifecycleRecorder()
    let transport = SequencedInspectingTransport { index, request in
        switch index {
        case 0:
            XCTAssertEqual(recorder.events, ["record:rishi-e2e-fixed@example.test:owner"])
            throw URLError(.networkConnectionLost)
        case 1:
            return TestAccountHTTPResponse(
                statusCode: 200,
                data: try JSONSerialization.data(withJSONObject: ["deleted": true])
            )
        default:
            return TestAccountHTTPResponse(
                statusCode: 404,
                data: try JSONSerialization.data(withJSONObject: ["error": "user not found"])
            )
        }
    }
    let client = TestAccountClient(
        configuration: .init(
            baseURL: URL(string: "https://api.example.test")!,
            testAuthSecret: "gate",
            testDomain: "example.test"
        ),
        transport: transport,
        valueGenerator: { "fixed" },
        lifecycleRecorder: recorder
    )

    do {
        _ = try await client.create(role: .owner)
        XCTFail("Expected provisioning failure")
    } catch is URLError {}
}

func testRecoveryRequiresSecondDeleteExactUserNotFoundJSON() async throws {
    let transport = RecordingTransport(responses: [
        .json(["deleted": true]),
        .json(["error": "user not found"], statusCode: 404),
    ])
    let client = TestAccountClient(
        configuration: .init(
            baseURL: URL(string: "https://api.example.test")!,
            testAuthSecret: "gate",
            testDomain: "example.test"
        ),
        transport: transport
    )
    try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test")
    XCTAssertEqual(transport.requests.count, 2)
}

private final class RecordingAccountLifecycleRecorder: TestAccountLifecycleRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    var events: [String] { lock.withLock { storedEvents } }

    func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws {
        lock.withLock { storedEvents.append("record:\(email):\(role.rawValue)") }
    }

    func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {
        lock.withLock { storedEvents.append("outcome:\(email):\(outcome.rawValue)") }
    }

    func recordVerifiedDeletion(_ email: String) throws {
        lock.withLock { storedEvents.append("deleted:\(email)") }
    }
}

private final class SequencedInspectingTransport: TestAccountTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callIndex = 0
    private let operation: @Sendable (Int, URLRequest) async throws -> TestAccountHTTPResponse
    init(operation: @escaping @Sendable (Int, URLRequest) async throws -> TestAccountHTTPResponse) {
        self.operation = operation
    }
    func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
        let index = lock.withLock {
            defer { callIndex += 1 }
            return callIndex
        }
        return try await operation(index, request)
    }
}
```

Extend the existing private `RecordingTransport.Response.json` helper to accept `statusCode: Int = 200`; do not introduce a second response model.

Add failure cases:

- `testRecoveryRejectsPlainTextNotFound`
- `testRecoveryRejectsGenericSuccessVerification`
- `testRecoveryRejectsAbsentJSONWithExtraFields`
- `testLostResponseAndFailedCompensationLeavesAddressJournaled`
- `testFourXXAfterValidProvisioningRequestRemainsRecoverableUntilVerifiedAbsent`
- `testVerifiedNormalDeletionRemovesAddressFromJournal`
- `testRecoveryAttemptsEveryRecordedAccountWhenOneFails`

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter TestAccountClientTests
```

Expected: failures because the recorder is not called and recovery accepts a single generic `2xx`/`404`.

- [ ] **Step 3: Add the required recorder dependency**

Change `TestAccountClient` to store:

```swift
private let lifecycleRecorder: any TestAccountLifecycleRecording
```

Add `lifecycleRecorder: any TestAccountLifecycleRecording = NoopTestAccountLifecycleRecorder()` after `valueGenerator` in the initializer, matching the call order shown above. In `create(role:)`, call `recordProvisioningAddress` after generating/validating the unique address but before constructing or sending the request. If recording fails, throw before network access.

Before the request, the journal entry is `.pending`. Once the valid provisioning request is sent, every outcome remains potentially side-effecting: mark successful responses, transport failures, decoding failures, and every HTTP failure (including 4xx) `.recoverable` before further handling. The current canonical route can create a user and then return a 4xx if sign-in fails, so status class alone never clears ownership. Only a future response contract that explicitly and authoritatively states `created: false` may clear an address without deletion; no current response has that status. After `verifyDeleted(_:)` accepts authoritative absence, call `recordVerifiedDeletion`. Compensating cleanup and `deleteProvisionedAccount(email:)` must perform the two-request protocol and call the same recorder only after exact absence verification.

Use a private verifier that accepts only:

```swift
response.statusCode == 404
    && Set(decoded.keys) == ["error"]
    && decoded["error"] as? String == "user not found"
```

Plain text `404`, gate failure, malformed JSON, or any `2xx` verification response throws without clearing journal state.

- [ ] **Step 4: Run account, journal, and package tests**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter TestAccountClientTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: all pass; live test skips.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift
git commit -m "fix(apple): make test account cleanup recoverable"
```

---

### Task 4: Record and safely recover owned process identities

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ProcessRunnerTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`

- [ ] **Step 1: Write failing stable-identity tests**

Add tests for:

```swift
func testRecoveryNeverSignalsReusedProcessIdentity() async throws {
    let recorded = OwnedProcessIdentity(pid: 701, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
    let reused = OwnedProcessIdentity(pid: 701, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
    let signals = SignalRecorder()

    try await SharedReadingRecoveryJournal.recoverProcesses(
        [recorded],
        liveIdentity: { _ in reused },
        signal: { pid, _ in signals.append(pid) },
        sleep: { _ in }
    )

    XCTAssertEqual(signals.values, [])
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int32] = []
    var values: [Int32] { lock.withLock { stored } }
    func append(_ pid: Int32) { lock.withLock { stored.append(pid) } }
}
```

Also add:

- `testProcessIdentityReaderUsesPIDAndBirthTime`
- `testFoundationRunnerRecordsStableRootAndDescendantIdentities`
- `testSpawnCreatesPrivateGroupBeforeGateRelease`
- `testJournalFailureBeforeGateReleasePreventsChildSideEffect`
- `testParentDeathPipeEOFBeforeJournalMakesGateExitWithoutChildSideEffect`
- `testCrashAfterGateReleaseRecoversIdentityBoundGroupBeforeDescendantJournal`
- `testRecoveryRefusesReusedGroupWhenLeaderIdentityDoesNotMatch`
- `testDisposableSimulatorIntentRecoversCrashBetweenCreateAndJournal`
- `testRecoveryDeletesOnlyExactJournaledDisposableSimulator`
- `testAppSideLaunchCallbackJournalsStableIdentityBeforeAcknowledgement`
- `testCatalystAppCannotFinishStartupUntilItsPeerPIDIsJournaled`
- `testCatalystCleanupNeverTerminatesUnregisteredBundleMatch`
- `testUnregisteredCatalystIntentClearsOnlyAfterBaselineAwareAbsenceProof`
- `testUnregisteredCatalystIntentBlocksLaterCleanupWhenNewBundleMatchExists`
- `testSharedReadingSupportNeverTerminatesBeforeRegistration`
- `testRegistrationGateIsInactiveWithoutExplicitLiveE2EEnvironment`
- `testLiveOwnerResetsDuringSingleRegisteredLaunchAndNeverRelaunchesInDeferredCleanup`
- `testDisposableParticipantPreservesScenarioRejoinButHasNoDeferredCleanupRelaunch`
- `testRecoveryCleansOriginalGroupMembersAfterLeaderExits`
- `testRecoverySignalsOnlyMatchingIdentityAndWaitsForAbsence`
- `testRecoveryRetainsJournalWhenOwnedProcessWillNotExit`

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter ProcessRunnerTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
```

Expected: compile/test failures because stable identities and process recovery do not exist.

- [ ] **Step 3: Implement PID-reuse-safe identity and recording**

On Darwin, read identity with:

```swift
var info = proc_bsdinfo()
let result = proc_pidinfo(
    pid,
    PROC_PIDTBSDINFO,
    0,
    &info,
    Int32(MemoryLayout<proc_bsdinfo>.size)
)
guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
return OwnedProcessIdentity(
    pid: pid,
    birthTimeSeconds: info.pbi_start_tvsec,
    birthTimeMicroseconds: info.pbi_start_tvusec
)
```

Inject an `OwnedProcessRecording` into `FoundationProcessRunner`, defaulting to no-op. Replace only its launch internals with a Darwin `posix_spawn` path while preserving the existing `ProcessRunner`/`ProcessHandle` API and bounded output behavior:

1. Create gate, stdout, and stderr pipes with close-on-exec parent ends. Do not add an ownership environment variable and do not inspect child environments; signed Xcode/XCTest processes may hide them under SIP.
2. Configure `posix_spawn_file_actions_t` so the gate read end becomes child stdin and stdout/stderr write ends become their standard descriptors. Explicitly close the gate write end and every unused pipe end in the child; otherwise the child would keep its own writer alive and never observe parent-death EOF.
3. Configure `posix_spawnattr_t` with `POSIX_SPAWN_SETPGROUP` and process group `0`, which creates the private group atomically at spawn time rather than racing `setpgid` after exec.
4. Spawn `/bin/sh` with argv `[/bin/sh, -c, 'IFS= read -r gate || exit 125; exec "$@"', rishi-e2e-gate, requestedExecutable, ...requestedArguments]`. The fixed `rishi-e2e-gate` operand becomes shell `$0`, so `"$@"` begins with the requested executable rather than accidentally omitting it. Never interpolate executable/argument text into shell source.
5. The child blocks on the gate pipe. If the parent dies or closes the pipe before release, EOF makes it exit `125` without executing the requested command.
6. Verify `getpgid(pid) == pid`, read the root birth-time identity, then persist both the root identity and `OwnedProcessGroup(processGroupID: pid, leader: rootIdentity)`. Only after both writes succeed may the parent write `go\n` and close the gate to permit `exec`.

Immediately after successful spawn, the parent closes its copies of the gate-read and stdout/stderr-write ends; it retains only the gate writer plus stdout/stderr readers. This is required for output readers to observe EOF after the child exits. If spawn, group verification, identity lookup, root/group recording fails, close the gate without writing, terminate/reap the private group/root if still present, close every remaining pipe, and rethrow; no requested executable side effect may occur. Add a test whose gate parent write end is deliberately closed to simulate host death before journaling and assert the child marker file is never created. Record every later descendant when the ownership monitor discovers it. If a descendant journal write fails, atomically retain that recording error on the handle, request group/tree cancellation, and make `wait()` throw after owned-process cleanup; never continue a run whose complete process ownership set could not be persisted.

Factor process-group enumeration into one internal helper used by both the live `FoundationProcessHandle` and recovery. While the original leader is alive, require its current identity to equal the journaled PID plus birth time. If the leader has exited but members still report the journaled PGID, the group is still the original group because Darwin cannot reuse a process-group ID while that group has members; snapshot and signal each member only after rechecking both its stable identity and PGID. If a live process whose PID equals the PGID has a different birth time, refuse to signal because the group was reused. Repeat until the group and every individually journaled identity are absent. The live monitor journals newly observed members as additional evidence, but ownership never depends on arguments or environments. Tests cover leader-alive, leader-exited/member-remains, fully absent, and reused-PGID cases.

Own simulator infrastructure by creating a disposable device for each run rather than terminating apps by bundle ID on a shared simulator. Before creation, persist an intent containing the exact unpredictable name `rishi-e2e-<runID>`, the configured iPhone 17 Pro device-type identifier, and runtime identifier. Run `simctl create`, atomically add the returned UDID to that record, boot only that device, and pass only its UDID to Xcode. If the host crashes after creation but before the UDID write, recovery lists devices and accepts only the exact pre-journaled UUID-bearing name plus matching device type/runtime. Cleanup shuts down and deletes that exact device and polls `simctl list --json` until its UDID/name is absent. This owns the participant app and its simulator XCTest runner as a whole without inspecting their processes. Never reset, boot, terminate, or delete the user's configured source simulator.

Own Catalyst processes through authenticated callbacks on the existing loopback rendezvous relay using its current bounded newline-delimited JSON request/response framing—not HTTP. Before starting Catalyst `xcodebuild`, enumerate `NSRunningApplication` identities for the exact runner bundle ID, atomically journal a runner `PendingCatalystLaunch` with that baseline, and reserve a runner nonce in the live relay. At the first line of the owner UI test, the runner sends `{secret, op:"register-runner", runID, role, kind:"runner", nonce, pid:getpid()}`. The relay's existing `secret` equality guard applies first; then it atomically consumes the exact runner reservation, validates stable identity and runner bundle, journals it, and acknowledges before scenario work.

Before `XCUIApplication.launch()`, the UI test sends the exact authenticated JSON request `{secret, op:"prepare-app-launch", runID, role:"owner", kind:"runner", nonce:<runnerNonce>}`. The relay's shared guard accepts the non-empty runner kind, then requires that exact runner registration to be already acknowledged, requires an empty exact app-bundle baseline, and journals the already host-reserved app launch intent. The host has reserved an in-memory single-use app-registration record keyed by a hash of the distinct launch nonce plus exact run ID/owner role/app kind/expected bundle before starting the owner test. It writes relay port, the same relay `secret`, run ID, owner role, app kind, and raw app nonce directly into that test configuration's `UITargetAppEnvironmentVariables`; the app nonce must not appear in runner `EnvironmentVariables`/`TestingEnvironmentVariables`. The runner receives the relay secret because all existing relay operations require it, but it receives only its distinct runner nonce. The UI test never receives or submits the app nonce/PID, and the `register-runner` operation rejects app kind.

At the first line of `rishiApp.init`, a small E2E-only registration gate activates only when the existing real-auth launch marker and every app-only registration value is present. Using a bounded raw TCP client compatible with `RendezvousRelayServer`, the app writes one newline-terminated JSON request `{secret, op:"register-app", runID, role, kind:"app", nonce, pid:getpid()}`, reads one bounded newline-terminated JSON response, and blocks startup until `ok:true`. The relay's existing `secret` guard runs first; then it atomically consumes the matching pre-reserved app nonce once, validates metadata, PID birth time, and exact app bundle, atomically records the stable identity into the matching intent and owned-process set, and only then acknowledges. A wrong/missing secret, unreserved/reused nonce, operation/kind mismatch, malformed/oversized frame, journal failure, PID reuse, or bundle mismatch fails without acknowledgement. Because Xcode injects the app nonce only into the launched target app—not the UI-test runner—and runner/app operations use distinct nonce reservations, an unrelated same-bundle process cannot be adopted. Failure aborts this explicit live-E2E app launch before normal startup. Remove the existing prelaunch `XCUIApplication.terminate()` from `SharedReadingTestSupport`; if an app is already present, fail closed without terminating it.

The live owner path launches Catalyst exactly once. Include the existing `--rishi-e2e-reset` behavior in that one registered launch so stale local auth/library state is cleared before sign-in. Remove the owner's deferred `resetLocalState` terminate/relaunch sequence for this live scenario; teardown terminates and verifies only the already registered stable app identity. Remove the participant test's deferred `resetLocalState` for the disposable-simulator run as well; preserve its intentional in-scenario terminate/launch used to prove rejoin, which remains inside the owned disposable device. UI-support regressions distinguish scenario restart from cleanup relaunch and prove one owner launch, no owner deferred relaunch, no participant deferred cleanup relaunch, and clean disposable-device deletion.

The UI test may not proceed until its runner handshake succeeds, and the app cannot finish startup until its app-side callback succeeds. Normal teardown and recovery signal only exact registered PID/birth-time identities. For an unresolved intent, recovery compares current exact-bundle identities with the journaled baseline: it may clear the intent only when no new identity exists; any new or unreadable identity blocks account deletion, lock release, and journal removal but is never signalled. This design works with SIP enabled and contains no UI-test-claimed app PID, filesystem IPC, `KERN_PROCARGS2`, task-port, process-name/environment scraping, bundle-wide termination, pre-registration `XCUIApplication.terminate()`, `pkill`, or `killall` fallback.

Recovery compares the current full identity before every signal. A missing identity or mismatched birth time means the recorded process is absent; never signal by PID alone or by process name.

- [ ] **Step 4: Run focused and package tests**

Run the two focused commands from Step 2, then:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: all pass; no real external process is signaled by tests.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ProcessRunnerTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift
git commit -m "fix(apple): persist owned e2e process identities"
```

---

### Task 5: Persist and reconcile the exact build-lock owner

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`

- [ ] **Step 1: Write failing lock ownership tests**

Add:

```swift
func testRecoveryReleasesOnlySameGenerationRetainedLock() throws {
    let lockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("rishi-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: lockPath) }
    let environment = ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path]
    let lock = try AppleXcodeBuildLock.acquire(environment: environment)
    let ownership = lock.ownership
    try AppleXcodeBuildLock.reconcileRetainedLock(
        ownership: ownership,
        liveIdentity: { _ in nil }
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: ownership.path))
}

func testRecoveryRefusesReplacementOwnerLock() throws {
    let lockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("rishi-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: lockPath) }
    let environment = ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path]
    let first = try AppleXcodeBuildLock.acquire(environment: environment)
    let staleOwnership = first.ownership
    try FileManager.default.removeItem(atPath: staleOwnership.path)
    let replacement = try AppleXcodeBuildLock.acquire(environment: environment)

    XCTAssertThrowsError(try AppleXcodeBuildLock.reconcileRetainedLock(
        ownership: staleOwnership,
        liveIdentity: { _ in nil }
    ))
    XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.ownership.path))
}
```

Also verify malformed/missing owner metadata fails closed.

Add `testReconcileTreatsAlreadyAbsentLockAsIdempotentSuccess`; this covers a crash after successful release but before journal finalization. An absent path succeeds, while any present lock must still match token, generation, and owner identity exactly.

Add `testTransferredLockSurvivesDeinitUntilExactRecovery`:

```swift
func testTransferredLockSurvivesDeinitUntilExactRecovery() throws {
    let lockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("rishi-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: lockPath) }
    var ownership: AppleXcodeBuildLockOwnership!
    do {
        let lock = try AppleXcodeBuildLock.acquire(environment: [
            "RISHI_APPLE_XCODE_BUILD_LOCK_PATH": lockPath.path,
        ])
        ownership = lock.transferToRecovery()
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path))
    try AppleXcodeBuildLock.reconcileRetainedLock(
        ownership: ownership,
        liveIdentity: { _ in nil }
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath.path))
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter ResourcePreflightTests
```

Expected: compile failure because `ownership` and exact reconciliation are unavailable.

- [ ] **Step 3: Expose immutable ownership and exact reconciliation**

Write owner metadata containing PID, birth time, token, and a separate generation UUID. `AppleXcodeBuildLock.ownership` must reflect exactly what was atomically persisted. `release()` and `reconcileRetainedLock` must reread metadata and require path + token + generation + owner identity to match whenever the path exists. If the path is already absent, reconciliation is idempotently successful; this API is called by recovery only after process/account absence is proved. A present replacement lock is never removed.

Add `transferToRecovery()`: while holding the lock's state mutex, mark the instance as transferred so `deinit` will not call `release`, then return immutable ownership. This is used only after cleanup cannot be proven and the journal already contains the same ownership. Normal success and proven-failure cleanup call `release()` explicitly. A transferred lock can be removed only by `reconcileRetainedLock` with exact persisted ownership.

The public reconciliation method delegates to this internal test seam, which Task 5 must implement with the exact signature used by its tests:

```swift
static func reconcileRetainedLock(
    ownership: AppleXcodeBuildLockOwnership,
    liveIdentity: (Int32) -> OwnedProcessIdentity?
) throws
```

Production `reconcileRetainedLock(ownership:)` passes `ProcessIdentityReader.identity(for:)`; tests inject deterministic PID-reuse/absence state.

The live journal records ownership immediately after acquisition. On journal write failure, release the just-acquired same-generation lock and fail before any relay/account/simulator action.

- [ ] **Step 4: Run lock, journal, and package tests**

Run:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter ResourcePreflightTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift
git commit -m "fix(apple): recover only owned e2e build locks"
```

---

### Task 6: Implement fail-closed recovery orchestration

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift`

- [ ] **Step 1: Write failing orchestration tests**

Add:

- `testRecoveryParsesEarlyJournalAndBothLegacyManifestShapes`
- `testRecoveryStopsCommandGroupsBeforeDeletingDisposableSimulatorAndAccounts`
- `testRecoveryStopsMatchingProcessesBeforeDeletingAccounts`
- `testRecoveryAttemptsEveryProcessWhenOneCannotBeStopped`
- `testRecoveryEnumeratesIdentityBoundPrivateGroupBeforeIndividualProcessCleanup`
- `testRecoveryDoesNotDeleteAccountsWhileProcessCleanupIsUnproven`
- `testRecoveryAttemptsSecondAccountAfterFirstDeletionFails`
- `testRecoveryDeletesPendingProvisioningAddressUntilAbsenceIsAuthoritative`
- `testRecoveryReconcilesLockOnlyAfterProcessesAndAccountsAreAbsent`
- `testRecoveryRetainsArtifactAndLockOnAnyFailure`
- `testRecoveryRemovesArtifactOnlyAfterCompleteProof`
- `testLegacyManifestFailsClosedWhileExactRunIDProcessOrConfiguredLockExists`

Use injected process identity/signal/sleep functions and a fake account manager. Record events and require this successful order:

```swift
[
    "process:stop:<pid>",
    "process:absent:<pid>",
    "simulator:delete:<udid>",
    "simulator:absent:<udid>",
    "account:delete:owner",
    "account:verified:owner",
    "account:delete:participant",
    "account:verified:participant",
    "lock:reconcile",
    "artifact:remove",
]
```

If any recorded process cannot be proved absent, assert that no account deletion or lock reconciliation occurs and the artifact remains. Within the account phase, one deletion failure must not suppress the other account attempt. Any account failure suppresses lock reconciliation/removal and retains all recovery state.

- [ ] **Step 2: Run focused tests and verify RED**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
```

Expected: failures because complete artifact recovery orchestration does not exist.

- [ ] **Step 3: Implement restrictive artifact decoding**

Add an internal normalized model:

```swift
struct RecoveryArtifact {
    let url: URL
    let runID: String
    let accounts: [RecordedAccount]
    let processGroups: Set<OwnedProcessGroup>
    let processes: Set<OwnedProcessIdentity>
    let simulatorDevices: Set<OwnedSimulatorDevice>
    let pendingCatalystLaunches: Set<PendingCatalystLaunch>
    let secretArtifactURLs: Set<URL>
    let buildLock: AppleXcodeBuildLockOwnership?
    let isLegacy: Bool
}
```

Decode, in order, the new recovery state, `RendezvousManifest`, and the existing redacted persisted-host shape (`owner/participant` objects containing role/email). Map `RecoveryState.processGroups`, `processes`, `simulatorDevices`, `pendingCatalystLaunches`, and secret-artifact paths without loss into the normalized model. Resolve secret-artifact paths only beneath that exact run root and accept only the two reserved role `.xctestrun` filenames. Runner/app registration nonces are never persisted in the recovery journal. Legacy manifest accounts are normalized as `.recoverable` because those formats are written only after successful creation; legacy process/resource sets are empty and therefore use the explicit legacy fail-closed checks below. Reject malformed files, duplicate roles, empty run IDs, addresses outside the configured generated namespace, simulator names not exactly derived from that run ID, non-iPhone-17-Pro device types, unconfigured runtimes, unexpected Catalyst bundle IDs/kinds, extra credential/token fields, and any external artifact path.

- [ ] **Step 4: Implement the complete recovery API and ordering**

Add:

```swift
public static func recover(
    at artifactURL: URL,
    temporaryRoot: URL,
    configuredBuildLockURL: URL,
    accountClient: TestAccountClient
) async throws
```

Production recovery performs:

1. Restrictively parse and normalize the artifact.
2. For new journals, recover every identity-bound private process group first so no live Xcode command can continue controlling a simulator or `.xctestrun`. Then attempt cancellation/absence verification for every individually registered/journaled Catalyst identity. Evaluate unresolved Catalyst intents against their exact-bundle baseline and block later phases if a new/unreadable identity remains; never signal an unregistered same-bundle process. Only after command groups and Catalyst intents are proven clear, shut down/delete and verify every exact disposable simulator (resolving an intent-only record by exact run-derived name/type/runtime), then remove and verify every exact secret-bearing `.xctestrun` clone. Collect failures rather than throwing out of any loop; never signal a reused PID/PGID.
3. For legacy manifests without identities, fail closed if an exact run-ID process is visible or the configured build-lock path exists; never guess ownership or remove that lock.
4. Only after process absence is proved, call strengthened two-request account deletion for every `.pending` or `.recoverable` address independently and collect all failures. A record is cleared only after the exact authoritative absent-user response.
5. Only after every process and account is absent, reconcile the exact journaled lock token/generation. If that exact lock was already released before a crash, an absent path is idempotent success; a present replacement/mismatch fails closed. Legacy recovery can proceed only when the lock path was already absent.
6. Remove the recovery artifact and its empty run directory only after all prior checks succeed; verify absence.
7. On any error, retain the artifact and any lock, return a combined redacted error, and never include account addresses, tokens, secrets, or arbitrary process command lines.

Tests use an internal overload that injects simulator inventory/control, identity reads, signals, sleeps, exact-run-ID process discovery, lock reconciliation, and artifact removal. Production defaults use `simctl`, `NSRunningApplication` only for registration validation, Darwin identity checks, and exact lock APIs.

- [ ] **Step 5: Run focused and package tests**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingRecoveryJournalTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: all pass; live test skips.

- [ ] **Step 6: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingRecoveryJournalTests.swift
git commit -m "fix(apple): orchestrate fail-closed e2e recovery"
```

---

### Task 7: Extract the shared live-run composition and explicit progress evidence

**Files:**
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingLiveRun.swift`
- Create: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveRunTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift`
- Create: `apps/apple/rishi/rishi/E2EProcessRegistration.swift`
- Create: `apps/apple/rishi/rishiTests/E2EProcessRegistrationTests.swift`
- Modify: `apps/apple/rishi/rishi/rishiApp.swift`

- [ ] **Step 1: Write failing configuration-order and evidence tests**

Add tests:

- `testLiveRunRequiresNetworkAcknowledgementBeforeAnyDependencyCall`
- `testLiveRunRequiresSimulatorResetAcknowledgementBeforeAnyDependencyCall`
- `testLiveRunRejectsNonCanonicalAPIBeforeAnyDependencyCall`
- `testLiveRunRejectsRetainedRecoveryArtifactBeforePreflight`
- `testSafeDestinationPreflightDoesNotResolvePackagesOrAcquireBuildLock`
- `testLiveRunAcquiresAndJournalsLockBeforePackageResolution`
- `testPackagePreparationUsesCallerHeldLockWithoutNestedAcquisition`
- `testPackageResolutionUsesJournalAwareRunnerAndSignalCancellation`
- `testExplicitPreflightResolvesPackagesUnderShortLivedLockAndCleansTemporaryState`
- `testExplicitPreflightRequiresAccountServiceWithoutCreatingAccounts`
- `testExplicitPreflightSignalCancellationAwaitsProcessCleanupBeforeLockRelease`
- `testRelayReturnsExactParticipantProgressSequence`
- `testRelayRejectsBooleanAndFractionalProgressSequences`
- `testPeerRegistrationNonceAndRoleAreWrittenToXctestrunEnvironment`
- `testRunnerCallbackAcknowledgesOnlyAfterStableIdentityJournalWrite`
- `testAppCallbackConsumesDistinctLaunchNonceAndJournalsBeforeAcknowledgement`
- `testAppLaunchNonceExistsOnlyInUITargetAppEnvironmentVariables`
- `testHostReservesDistinctRunnerAndAppNoncesBeforeOwnerTestLaunch`
- `testRegisterRunnerJSONOperationRequiresSecretRunnerReservationAndRunnerKind`
- `testRegisterAppJSONOperationRequiresSecretAppReservationAndAppKind`
- `testPrepareAppLaunchWireRequestIncludesAcknowledgedRunnerKindAndNonce`
- `testAppClientUsesBoundedNewlineDelimitedRelayJSONFraming`
- `testRelayRejectsAppKindOnRunnerEndpointAndRunnerKindOnAppEndpoint`
- `testAppCallbackRejectsWrongNonceRoleBundlePIDReuseAndSecondUse`
- `testAppRegistrationGateIsInactiveWithoutCompleteLiveE2EConfiguration`
- `testLiveOwnerUsesResetOnItsSingleRegisteredLaunchWithoutDeferredRelaunch`
- `testDisposableParticipantKeepsRejoinRestartButSkipsDeferredCleanupRelaunch`
- `testLiveRunCreatesAndDeletesOneDisposableIPhone17ProSimulator`
- `testLiveRunRejectsExternalPreparedDerivedRootBeforeSideEffects`
- `testHostInvokesOwnedResourceCleanupBeforeEitherAccountDeletion`
- `testHostSkipsAccountDeletionWhenOwnedResourceCleanupIsUnproven`
- `testLiveRunFailsWhenParticipantSequenceIsBelowTwo`
- `testLiveRunReturnsRunIDSequenceAndDeletedAccountsAfterCompleteCleanup`
- `testLiveRunRetainsJournalAndLockWhenCleanupFails`
- `testSignalCancellationAwaitsHostCleanupBeforeReturning`
- `testSuccessfulRunRemovesAndVerifiesRunDirectoryAndStagedFixture`
- `testExplicitArtifactRetentionKeepsOnlyDiagnosticsAndStillReturnsEvidence`
- `testArtifactRemovalFailurePreventsSuccessEvidence`

The test composition seam should accept closures/factories in an internal `Dependencies` value so ordering can be asserted without Xcode/network. The public `execute(environment:)` always uses `.live` dependencies.

- [ ] **Step 2: Run focused tests and verify RED**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingLiveRunTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter RendezvousRelayTests
```

Expected: failures because the live runner and typed sequence accessor do not exist.

- [ ] **Step 3: Split preflight from package resolution**

Make `XCTestPeerProcessRunner.preflight()` perform only resource, Xcode availability, and source-simulator template validation. Move package resolution into a destination-free `PackageDependencyPreparer.preparePackageDependencies(project:whileHolding:)` that runs `xcodebuild -resolvePackageDependencies` without `-destination` or any source-simulator UDID. It must not acquire another lock; it uses the caller-held lock as an ownership proof and verifies `lock.ownership` still matches current metadata before starting each Xcode command. Only after package resolution succeeds does the live runner create the disposable simulator and construct the scenario `XCTestPeerProcessRunner` with that new UDID. Add fake-runner tests proving one caller-held acquisition succeeds without nested-lock failure and no package, reset, build-for-testing, or test-without-building command ever targets the configured source simulator.

`SharedReadingLiveRun.execute` calls package preparation only after:

1. all configuration is validated;
2. unresolved recovery artifacts are rejected;
3. account/destination preflights pass;
4. the run journal exists;
5. the build lock is acquired and journaled.

Before package preparation, construct `FoundationProcessRunner(ownedProcessRecorder: journal)` and the destination-free `PackageDependencyPreparer` that uses it, then install shared signal cancellation around the package-preparation task. A signal during package resolution must cancel and await the journaled Xcode process before lock/recovery handling continues. Package resolution remains before disposable-simulator creation, scenario-runner construction, and account creation.

Preserve `--preflight` semantics through `SharedReadingLiveRun.preflight(environment:)`: validate configuration, reject an unresolved prior artifact, and call `accountClient.preflight()` first so disabled test-auth cannot report success. Then create an isolated preflight run root plus recovery journal, construct the journal-aware process runner and destination-free package preparer, install the same shared signal-to-cancellation handler used by live execution, validate that the configured source describes an available iPhone 17 Pro type/runtime without launching it, acquire and journal one short-lived Apple lock, and invoke destination-free package preparation. On success or cancellation, await all journaled process cleanup before releasing the lock, finalizing the journal, and removing/verifying the temporary root. On unproven cleanup, transfer the lock to recovery and retain the journal. Preflight creates/resets/boots no simulator, creates no account or relay, and uploads no book, but continues to validate account-service availability and package resolution.

- [ ] **Step 4: Expose typed relay evidence**

Add:

```swift
public func participantProgressSequence(runID: String) -> Int64? {
    guard let data = storedValue(for: "\(runID)\u{1F}participant-progress") else { return nil }
    return try? JSONDecoder().decode(Int64.self, from: data)
}
```

`JSONDecoder` must reject booleans and fractional numbers instead of truncating them. Read the sequence before `relay.stop()`. Do not expose arbitrary keys or secrets.

During initial configuration validation, reject missing/invalid callback settings before package resolution, relay startup, lock acquisition, simulator creation, or accounts. Before participant launch, create and journal the disposable `OwnedSimulatorDevice` described in Task 4 and use only its UDID. In the owner role `.xctestrun`, put relay port/secret, run/role/kind, and the host-reserved runner nonce in `EnvironmentVariables`/`TestingEnvironmentVariables`; put relay port/the same secret, app metadata, and the distinct host-reserved app nonce in `UITargetAppEnvironmentVariables`. Tests parse the clone and prove the runner dictionaries contain no app nonce while both clients receive the existing relay secret required by the JSON framing. The owner UI test self-registers only its runner and prepares the app intent before launch; the app-side startup gate performs the only `register-app` operation against the host's pre-reserved nonce. The participant is owned by disposable-simulator deletion and receives no Catalyst registration configuration. Reject `RISHI_E2E_PREPARED_DERIVED_ROOT` for live execution before any side effect; build-for-testing output and both role clones must live at fixed validated paths beneath the run root. Both `.xctestrun` clones contain account credentials and the owner clone also contains app registration secrets, so record their exact reserved relative paths before writing and make deletion plus absence verification mandatory on every success, failure, cancellation, and recovery path. Retained diagnostics may include redacted `.xcresult` output but never a secret-bearing `.xctestrun` clone. Do not discover ownership from process ancestry, names, arguments, or environment inspection.

Extend `SharedReadingHost.runReport` with an injected async `preAccountCleanup` collaborator, defaulting to a no-op for existing deterministic callers. After both peer handles have been stopped and awaited, invoke this collaborator to stop/verify registered Catalyst identities, resolve pending intents, delete/verify the disposable simulator, and remove/verify secret-bearing clones. Only if that phase succeeds may `SharedReadingHost` call either account deletion. If it fails, mark cleanup failed, retain recovery state/lock, and skip account deletion. This ordering is part of `SharedReadingHostTests`, not merely an outer `SharedReadingLiveRun` convention.

- [ ] **Step 5: Implement `SharedReadingLiveRun.execute`**

Move environment/fixture resolution and lifecycle code from `RishiE2EHostCLI.main` into the library. Required ordering:

```text
validate flags/paths/canonical URL
reject unresolved recovery artifacts
account and safe Apple preflight
create run root + recovery journal
acquire and journal exact build lock ownership
construct journal-aware account/process collaborators
install shared SIGINT/SIGTERM-to-task-cancellation sources
resolve packages using that caller-held lock and journal-aware runner (no nested acquisition)
start relay
persist disposable-simulator intent, create/journal/boot the exact device
run SharedReadingHost once; its pre-account cleanup stops/verifies registered identities, resolves intents, deletes/verifies simulator, and removes secret clones
read participant-progress and require >= 2
stop relay and remove staged fixture
verify host pre-account cleanup completed before its account cleanup
verify journaled accounts absent
release same-generation lock
finalize journal only after every owned-resource cleanup check
remove and verify the now-empty successful run directory unless retention requested
return redacted evidence
```

Move the CLI's signal-source logic into an internal shared `LiveRunSignalHandler` used by both CLI and XCTest. SIGINT/SIGTERM cancels the live host task; `execute` then awaits `host.runReport`'s uncancelled teardown before it returns/throws. Tests inject a signal installer that invokes the cancellation closure without sending a real process signal and assert peer stop plus account cleanup complete first.

Use `defer` plus an explicit uncancelled cleanup phase so relay stop and recovery run on throw/cancellation. Replace the current best-effort staged-fixture removal with a throwing helper that removes the two exact reserved fixture paths and every exact secret-bearing `.xctestrun` clone, then verifies absence before any diagnostics are retained. On success, remove and verify the run directory/results unless `RISHI_E2E_KEEP_ARTIFACTS=1`; on failure, retain only redacted diagnostics. Explicit successful-run retention may keep only redacted diagnostic/result files after the journal, manifest, staged fixture, `.xctestrun` clones, disposable simulator, owned processes, and lock are absent. If cleanup remains unproven, journal the lock ownership and call `transferToRecovery()` before the lock leaves scope so `deinit` cannot release it. Never return evidence when `report.primaryFailure != nil`, `report.cleanupFailed`, sequence `< 2`, signal cleanup is unfinished, exact required-artifact removal fails, final recovery state is non-empty, or the success run directory remains without explicit retention.

- [ ] **Step 6: Run focused and package tests**

Run the focused commands from Step 2 plus:

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:rishiTests/E2EProcessRegistrationTests
```

Expected: all deterministic host and app registration tests pass; live test still skips by default; no shared-reading UI-test app is launched.

- [ ] **Step 7: Commit**

```sh
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingLiveRun.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveRunTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift \
  apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift \
  apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift \
  apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift \
  apps/apple/rishi/rishi/E2EProcessRegistration.swift \
  apps/apple/rishi/rishiTests/E2EProcessRegistrationTests.swift \
  apps/apple/rishi/rishi/rishiApp.swift
git commit -m "feat(apple): compose repeatable shared reading live run"
```

---

### Task 8: Wire the canonical XCTest and CLI to the shared runner

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveEndToEndTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift`

- [ ] **Step 1: Replace the intentional live failure with real assertions**

```swift
func testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress() async throws {
    guard ProcessInfo.processInfo.environment["RISHI_E2E_RUN_LIVE"] == "1" else {
        throw XCTSkip("Set RISHI_E2E_RUN_LIVE=1 only for an explicitly configured local live run.")
    }

    let evidence = try await SharedReadingLiveRun.execute()
    XCTAssertFalse(evidence.runID.isEmpty)
    XCTAssertGreaterThanOrEqual(evidence.participantProgressSequence, 2)
    XCTAssertEqual(evidence.deletedAccountCount, 2)
    let encoded = try JSONEncoder.sorted.encode(evidence)
    print("RISHI_E2E_EVIDENCE \(String(decoding: encoded, as: UTF8.self))")
    if let path = ProcessInfo.processInfo.environment["RISHI_E2E_EVIDENCE_PATH"], !path.isEmpty {
        let url = URL(fileURLWithPath: path)
        try encoded.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
```

No fake dependencies are permitted in this file. The fixed evidence line and optional `RISHI_E2E_EVIDENCE_PATH` contain only run ID, integer sequence, and deletion count.

- [ ] **Step 2: Reduce CLI main to argument routing**

Keep `--help`, `--preflight`, and `--cleanup-manifest=` compatibility. Delegate normal execution to `SharedReadingLiveRun.execute(environment:)`, preflight to `SharedReadingLiveRun.preflight(environment:)`, and recovery to the complete journal recovery API from Task 6, passing the configured temporary root and exact configured/default build-lock URL. Recovery must parse only its network/API/test-auth settings plus those two safe local paths; it must not require fixture, Xcode project, simulator, reset permission, or live-test flag. Print only redacted evidence:

```text
Shared-reading E2E completed: <run-id>
Participant observed sequence: <sequence>
Temporary accounts deleted and verified: 2
```

Never print addresses, credentials, token values, or book contents.

- [ ] **Step 3: Verify default skip and fail-closed focused configuration**

Run the safe default command from Task 1 Step 2. Then run:

```sh
env -u RISHI_E2E_ALLOW_NETWORK \
  -u RISHI_E2E_ALLOW_SIMULATOR_RESET \
  RISHI_E2E_RUN_LIVE=1 \
  swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
```

Expected: default suite exits `0` with one skip; focused command exits non-zero naming `RISHI_E2E_ALLOW_NETWORK=1`, before network/Xcode/simulator work.

- [ ] **Step 4: Run deterministic package tests**

```sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: pass, one live skip.

- [ ] **Step 5: Commit**

```sh
git add apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingLiveEndToEndTests.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift
git commit -m "test(apple): run shared reading acceptance in XCTest"
```

---

### Task 9: Add the thin local validator and its no-app contract tests

**Files:**
- Create: `apps/apple/scripts/validate-shared-reading.sh`
- Create: `apps/apple/scripts/validate-shared-reading.test.sh`
- Modify: `apps/apple/rishi-e2e-host/README.md`

- [ ] **Step 1: Write the failing shell contract tests**

The test script creates an isolated temporary directory and a fake executable named `swift` placed first on `PATH`. The fake records `RISHI_E2E_RUN_LIVE` plus all arguments and returns configured statuses. Implement four cases:

1. `runs deterministic suite with live mode off, then focused test with live mode on`
2. `preserves deterministic suite failure and does not start live phase`
3. `rejects missing live acknowledgement before focused test`
4. `preserves focused live test failure and reports the live phase`

Assertions:

```text
first call:  RISHI_E2E_RUN_LIVE is absent; swift test --package-path ... --jobs 1
second call: RISHI_E2E_RUN_LIVE=1; same package path; exact live-test filter
missing configuration: wrapper exits 2 without second swift call
phase failure: wrapper preserves 23/37 rather than converting it
```

- [ ] **Step 2: Run and verify RED**

```sh
zsh apps/apple/scripts/validate-shared-reading.test.sh
```

Expected: non-zero because `validate-shared-reading.sh` does not exist.

- [ ] **Step 3: Implement the wrapper**

Use this control flow:

```zsh
#!/bin/zsh
set -u

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}
package_path="$repo_root/apps/apple/rishi-e2e-host"

env -u RISHI_E2E_RUN_LIVE swift test --package-path "$package_path" --jobs 1
status=$?
if (( status != 0 )); then
  print -u2 "Shared-reading validation failed during deterministic package tests."
  exit $status
fi

required=(RISHI_E2E_ALLOW_NETWORK RISHI_E2E_ALLOW_SIMULATOR_RESET RISHI_E2E_API_BASE_URL RISHI_E2E_TEST_AUTH_SECRET RISHI_E2E_TEST_DOMAIN RISHI_E2E_IPHONE17_UDID RISHI_E2E_PROJECT RISHI_E2E_FIXTURE)
for key in $required; do
  if (( ! ${+parameters[$key]} )) || [[ -z "${(P)key}" ]]; then
    print -u2 "Missing required shared-reading setting: $key"
    exit 2
  fi
done

RISHI_E2E_RUN_LIVE=1 swift test --package-path "$package_path" --jobs 1 \
  --filter SharedReadingLiveEndToEndTests/testTwoAccountsJoinOneSessionAndSynchronizeReadingProgress
status=$?
if (( status != 0 )); then
  print -u2 "Shared-reading validation failed during the focused live XCTest."
fi
exit $status
```

Additionally require both acknowledgement values equal `1` and the API URL equal `https://api.fidexa.org`; do not print values for secret-bearing keys.

- [ ] **Step 4: Run wrapper tests and deterministic package tests**

```sh
zsh apps/apple/scripts/validate-shared-reading.test.sh
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: both pass; wrapper test log proves no real Swift/Xcode/app invocation.

- [ ] **Step 5: Document local invocation, cleanup, and non-CI status**

Update the README with:

- the wrapper command and required variables;
- direct focused XCTest command;
- default skip semantics;
- recovery invocation for an exact retained artifact;
- explicit statement that GitHub Actions does not run this test;
- explicit statement that success requires two verified account deletions and no recovery residue.

- [ ] **Step 6: Commit**

```sh
git add apps/apple/scripts/validate-shared-reading.sh \
  apps/apple/scripts/validate-shared-reading.test.sh \
  apps/apple/rishi-e2e-host/README.md
git commit -m "test(apple): add local shared reading validator"
```

---

### Task 10: Verify deterministic behavior and two consecutive real runs

**Files:**
- No new production files unless a concrete live failure requires a scoped fix.
- Update tests adjacent to any necessary fix before implementation.

- [ ] **Step 1: Run all deterministic checks**

```sh
zsh apps/apple/scripts/validate-shared-reading.test.sh
env -u RISHI_E2E_RUN_LIVE \
  -u RISHI_E2E_ALLOW_NETWORK \
  -u RISHI_E2E_ALLOW_SIMULATOR_RESET \
  swift test --package-path apps/apple/rishi-e2e-host --jobs 1
git diff --check
```

Expected: shell tests pass; Swift package passes with one live skip; diff check is clean.

- [ ] **Step 2: Verify approved external prerequisites before launching apps**

Confirm the canonical API test-auth preflight succeeds and the configured simulator resolves to an available iPhone 17 Pro device type/runtime template. The test will create its own disposable simulator and must not launch or reset that source device. If test-auth is disabled, stop and report that operational blocker; a skip or preflight failure is not completion evidence.

- [ ] **Step 3: Ensure no previous test-owned processes are running**

Inspect for an existing E2E host, owned `xcodebuild`/XCTest process, relay, registered Catalyst process, and retained disposable simulator. Close only stale resources proven by recovery state. Do not launch more than the one Catalyst and one disposable iPhone 17 Pro peer required by the test.

- [ ] **Step 4: Run the canonical validator once**

Create an explicit redacted evidence destination:

```sh
e2e_evidence_one=$(mktemp /private/tmp/rishi-e2e-evidence-one.XXXXXX)
```

```sh
RISHI_E2E_ALLOW_NETWORK=1 \
RISHI_E2E_ALLOW_SIMULATOR_RESET=1 \
RISHI_E2E_API_BASE_URL=https://api.fidexa.org \
RISHI_E2E_TEST_AUTH_SECRET="$RISHI_E2E_TEST_AUTH_SECRET" \
RISHI_E2E_TEST_DOMAIN="$RISHI_E2E_TEST_DOMAIN" \
RISHI_E2E_IPHONE17_UDID="$RISHI_E2E_IPHONE17_UDID" \
RISHI_E2E_PROJECT="$PWD/apps/apple/rishi/rishi.xcodeproj" \
RISHI_E2E_FIXTURE="$RISHI_E2E_FIXTURE" \
RISHI_E2E_EVIDENCE_PATH="$e2e_evidence_one" \
apps/apple/scripts/validate-shared-reading.sh
```

Expected: deterministic phase passes; live phase exits `0`; the 0600 evidence JSON contains a non-empty run ID, integer participant sequence `>= 2`, and deletion count `2`.

- [ ] **Step 5: Audit residue after run one**

Confirm:

- no journal or manifest remains for the successful run;
- no staged fixture remains;
- the exact build-lock path is absent;
- no journaled process identity or private process group remains alive;
- the disposable simulator is absent and no registered Catalyst identity remains alive.

- [ ] **Step 6: Run the identical validator a second time**

Create a second evidence destination and run the same validator/configuration with only that path changed:

```sh
e2e_evidence_two=$(mktemp /private/tmp/rishi-e2e-evidence-two.XXXXXX)
```

Set `RISHI_E2E_EVIDENCE_PATH="$e2e_evidence_two"` and rerun the exact validator command from Step 4.

Expected: a different run ID, participant sequence `>= 2`, two verified deletions, and exit `0`. This is the idempotency proof.

- [ ] **Step 7: Audit residue after run two and capture redacted evidence**

Repeat Step 5. Extract and compare the two IDs:

```sh
e2e_run_one=$(/usr/bin/plutil -extract runID raw -o - "$e2e_evidence_one")
e2e_run_two=$(/usr/bin/plutil -extract runID raw -o - "$e2e_evidence_two")
[[ -n "$e2e_run_one" && -n "$e2e_run_two" && "$e2e_run_one" != "$e2e_run_two" ]]
```

Use `plutil` to verify both `participantProgressSequence` values are integers `>= 2` and both `deletedAccountCount` values equal `2`. Record only run IDs, observed sequences, deletion counts, command exit statuses, and test summaries, then remove the two explicit evidence files. Do not persist account addresses, secrets, invite values, or book contents.

- [ ] **Step 8: Run independent implementation reviews**

Dispatch:

1. Luna specification reviewer — compare the final diff and evidence with every approved design completion check.
2. Terra quality reviewer — inspect concurrency, cleanup, PID-reuse safety, lock ownership, secret handling, and maintainability.

Fix every Critical, High, and Medium finding with a failing regression first, rerun focused/full tests, and re-review until both return PASS with zero open issues.

- [ ] **Step 9: Commit any review-driven fixes separately**

Stage only Apple E2E host/script/docs files. Never stage the pre-existing MCP/UI-test edits.

---

## Consumer and call-site audit

| Behavioral contract | Producer | Consumers to update/verify |
|---|---|---|
| Account lifecycle recording | `TestAccountClient.create`, compensation, `verifyDeleted`, recovery delete | CLI/live runner, deterministic account tests, recovery journal |
| Stable process identity | `FoundationProcessRunner` root and ownership monitor | peer prepare/launch, journal recovery, process tests |
| Exact app-target ownership | `SharedReadingLiveRun` before peer launch | simulator/Catalyst controller, normal teardown, recovery, target tests |
| Build-lock ownership | `AppleXcodeBuildLock.acquire` | live runner, package-resolution path, recovery, resource tests |
| Safe preflight ordering | `XCTestPeerProcessRunner.preflight` and `preparePackageDependencies` | `SharedReadingLiveRun`, `SharedReadingHost.runReport`, host tests |
| Participant progress evidence | `RendezvousRelayServer` stored `participant-progress` | live runner evidence, relay tests, live XCTest |
| Shared live composition | `SharedReadingLiveRun.execute` | CLI normal run, canonical live XCTest |
| Recovery artifact formats | early `recovery.json`, later `manifest.json` | unresolved scan, `--cleanup-manifest`, README recovery command |
| Local validator exit behavior | `validate-shared-reading.sh` | shell contract tests, developer invocation |

## Explicitly out of scope

- MCP server implementation, tests, or the existing uncommitted MCP work.
- Electron code or tests.
- Worker code, migrations, deployment files, or typecheck fixes.
- GitHub workflow changes or required PR checks.
- Product behavior changes unless the real live test exposes a concrete shared-reading defect; any such defect requires its own failing regression and adversarial review before implementation.
- Launching more than one Catalyst peer and one iPhone 17 Pro peer.

## Adversarial review loop

Each round follows review → log findings → update plan → re-review.

### Research inputs

- Terra architecture pass mapped journal/account/process/lock seams and exact call sites.
- Luna test pass mapped live-XCTest gating, wrapper behavior, explicit progress evidence, and the package-resolution lock-order conflict.

### Round 1 — Luna adversarial review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Package preparation would reacquire the already-held global lock. | `preparePackageDependencies(whileHolding:)` now consumes/verifies the caller-held lock and never acquires internally; add a real-runner isolated-lock regression. |
| 2 | High | Lock `deinit` would release a lock that cleanup intended to retain. | Add `transferToRecovery()` and a deinit-survival regression; only exact static reconciliation can release a transferred lock. |
| 3 | High | XCTest bypassed CLI-only SIGINT/SIGTERM cleanup. | Move signal-to-cancellation handling into the shared live runner and test that host teardown is awaited. |
| 4 | High | A process could spawn descendants before root identity journaling. | Superseded by Round 2's stricter `posix_spawn` private-group plus parent-death-aware control-pipe gate. |
| 5 | High | `proc_pidinfo` snippet compared `Int32` with `Int`. | Compare against `Int32(MemoryLayout<proc_bsdinfo>.size)`. |
| 6 | Medium | Provisioning test transport failed compensation too, contradicting expected `URLError`. | Use a sequenced transport: provisioning loses response, cleanup succeeds, second delete returns exact absent JSON. |
| 7 | Medium | Planned preflight omitted existing package-resolution validation. | `SharedReadingLiveRun.preflight` resolves under one short-lived held lock and removes its temporary state without reset/accounts/relay. |
| 8 | Medium | Successful artifact and staged-fixture cleanup was best-effort/unverified. | Make exact fixture/run-root cleanup throwing and verifiable; no evidence returns while artifacts remain. |
| 9 | Medium | XCTest path emitted no machine-readable evidence or two-run ID comparison. | Emit/write redacted Codable evidence, capture two files, compare distinct IDs and both sequences/deletion counts. |
| 10 | Medium | `NSNumber.int64Value` could truncate fractional progress. | Decode relay evidence directly as `Int64`, rejecting boolean/fractional JSON. |

**Round 1 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 2 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Post-spawn `setpgid` can fail after exec, so the stopped-shell plan did not guarantee a private group. | Use `posix_spawn` with `POSIX_SPAWN_SETPGROUP` so the private group exists atomically before the gate runs. |
| 2 | High | A host crash before journaling could leave a stopped shell forever. | Child blocks on a parent-owned control pipe and exits `125` on EOF; journal+group verification precede the only gate-release write. |
| 3 | Medium | Recovery API was named but its artifact parsing and cleanup ordering were not planned. | Add Task 6 with restrictive dual-format decoding, process-before-account safety, independent account attempts, exact lock reconciliation, and fail-closed retention. |

**Round 2 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 3 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `sh -c` would consume the requested executable as `$0` and omit it from `"$@"`. | Add fixed `rishi-e2e-gate` as `$0`; requested executable is the first `"$@"` operand. |
| 2 | High | Parent retained child stdout/stderr writer FDs, preventing EOF. | Close parent gate-read/output-writer copies immediately after spawn; retain only gate writer/output readers. |
| 3 | Medium | One process recovery failure could suppress later identity attempts. | Attempt every recorded identity independently, collect results, and block later cleanup if any remains unproven. |
| 4 | Medium | Crash after lock release but before journal finalization could make absent lock unrecoverable. | Treat absent lock path as idempotent success only after process/account absence; present mismatch still fails closed. |
| 5 | Medium | Explicit successful artifact retention contradicted unconditional run-directory absence. | Permit only explicitly retained diagnostics/results after all owned/recovery artifacts are absent; add regression. |
| 6 | Medium | Task 2 referenced recovery types/protocols scheduled for later tasks. | Define all foundational Codable values and recorder protocols in Task 2; later tasks add behavior in place. |

**Round 3 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 4 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Recovery outcome policy treated every 4xx as no-side-effect even though signup can precede a sign-in 4xx. | Treat every post-request outcome, including 4xx, as recoverable until authoritative absence; no current response clears ownership without cleanup. |
| 2 | High | Root journaling did not cover descendants created immediately after gate release. | Persist the birth-time-bound private PGID before release and enumerate its members. The later token extension was superseded by SIP-safe exact app-target ownership in Round 7. |
| 3 | High | Package resolution launched Xcode before journal-aware runner and shared signal handling existed. | Construct journal-aware process/peer runners and install signal cancellation before package preparation. |
| 4 | Medium | Lock test used an undeclared injectable reconciliation overload. | Task 5 now declares the exact internal overload and production delegation. |

**Round 4 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 5 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Normalized recovery artifact dropped journaled process groups. | Preserve `processGroups` during normalization and use them before individual process cleanup. |
| 2 | High | App processes launched by Xcode are not guaranteed to remain descendants of `xcodebuild`. | Initially addressed with an `.xctestrun` token, then bundle targets; superseded in Round 8 by disposable simulator ownership and synchronous Catalyst stable-identity registration. |
| 3 | High | Generic 4xx was treated as no-side-effect despite signup-before-sign-in failure. | Every post-request outcome is recoverable until exact absent verification; remove rejected-state shortcut. |
| 4 | High | Standalone preflight lacked shared signal cleanup around package-resolution Xcode. | Give preflight a temporary recovery journal, journal-aware runner, shared cancellation, awaited teardown, and lock transfer on uncertainty. |
| 5 | Medium | Extracted preflight omitted account-service preflight. | Call `accountClient.preflight()` before journal/lock/package work without creating accounts. |

**Round 5 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 6 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Normal success cleanup could miss an app process detached from the Xcode process group. | Initially extended token discovery to normal cleanup; superseded in Round 7 by exact app-target teardown and verification under both normal and recovery paths. |

**Round 6 result:** Finding addressed in the plan. **Re-review required before Task 1.**

### Round 7 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Full-table ownership discovery relied on `KERN_PROCARGS2`, but SIP can hide environments for signed Xcode/XCTest descendants. | Remove environment-token discovery entirely. Own host commands through birth-time-verified private process groups. The initial bundle-target cleanup was further hardened in Round 8 with disposable simulator ownership and synchronous stable-identity registration. |

**Round 7 result:** Finding addressed in the plan. **Re-review required before Task 1.**

### Round 8 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Bundle/UDID cleanup could terminate an unrelated app launched after preflight. | Use a uniquely named disposable iPhone 17 Pro simulator owned as a whole; for Catalyst, synchronously validate and journal stable runner/app identities before test progress and signal only those exact identities. |
| 2 | High | Requiring the original process-group leader to remain alive stranded valid members after normal leader exit. | When the leader is absent, rely on Darwin's non-reuse of a PGID while members remain, but still snapshot/recheck each member identity; refuse a live reused leader with mismatched birth time. |
| 3 | High | Simulator XCTest runner may live outside the host `xcodebuild` group. | The per-run disposable simulator owns its app and all simulator-side runners; cleanup shuts down/deletes the exact device and verifies inventory absence. Catalyst runner/app use synchronous stable-identity registration. |
| 4 | Medium | A Task 6 test still named the removed token-bound discovery mechanism. | Rename it to identity-bound private-group recovery and prohibit token/environment discovery throughout. |

**Round 8 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 9 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Package resolution used a peer runner tied to the configured source simulator before the disposable simulator existed. | Add a destination-free package preparer; only construct the scenario runner after disposable-device creation and test that no mutating/test command targets the source simulator. |
| 2 | High | Recovery deleted the simulator before stopping `xcodebuild`, allowing a live command to race cleanup. | Stop and verify private command groups and registered Catalyst identities first, resolve intents, then delete/verify the simulator. |
| 3 | High | Existing UI support called `XCUIApplication.terminate()` before registration and could kill an unrelated same-bundle app. | Remove prelaunch termination; journal an app intent only after proving an empty baseline, then launch/register, and fail closed if an app is already present. |
| 4 | High | The Catalyst pre-registration crash window had no durable pending-launch state or recovery rule. | Journal runner/app launch intents with exact bundle baselines; recovery clears only on baseline-aware absence and otherwise blocks without signalling the process. |
| 5 | Medium | Secret-bearing `.xctestrun` clones could survive in retained diagnostics. | Journal only their exact reserved relative paths; remove and verify them on every teardown/recovery path before retaining redacted diagnostics. |

**Round 9 result:** All findings addressed in the plan. **Re-review required before Task 1.**

### Round 10 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Existing `SharedReadingHost.runReport` deleted accounts after peer-handle stop but before exact Catalyst/simulator cleanup. | Add a tested `preAccountCleanup` phase inside host teardown; it must prove registered processes, intents, disposable simulator, and secret clones clear before either account deletion. |
| 2 | High | External `RISHI_E2E_PREPARED_DERIVED_ROOT` could place credential-bearing clones outside recoverable run-root cleanup. | Reject that override for live runs before side effects and require generated output/clones at validated journaled paths beneath the run root. |
| 3 | Medium | Disposable simulator differed from the approved spec's configured participant wording. | Update the approved design: configured iPhone 17 Pro is a read-only type/runtime template; the equivalent run-owned disposable simulator is the participant. |

**Round 10 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 11 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Empty bundle baseline plus a nonce-bearing UI-test PID claim did not prove that the app process belonged to the run. | Require an app-side startup handshake rather than UI-test app registration. Earlier IPC transports were superseded by the single-use app callback in Round 14. |

**Round 11 result:** Finding addressed in plan and design. **Re-review required before Task 1.**

### Round 12 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Catalyst App Sandbox cannot connect to a Unix socket under the host temporary run root. | Initially moved to App Group IPC; superseded by entitlement-free anonymous XPC in Round 13. |
| 2 | High | The temporary run-root socket path already exceeded Darwin's `sockaddr_un.sun_path` limit. | Initially shortened the path; superseded by filesystem-free anonymous XPC in Round 13. |

**Round 12 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 13 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | SwiftPM host and UI-test runner lack App Group entitlement, so App Group socket access is not valid on current macOS. | Replace filesystem socket with `NSXPCListener.anonymous()`; pass its securely archived capability endpoint and derive caller PID from `NSXPCConnection.processIdentifier`, requiring no App Group or named-service entitlement. |
| 2 | Medium | Socket path validation occurred after package/relay/simulator side effects. | Anonymous XPC removes filesystem/path validation; endpoint archive round-trip and size validation now occurs in initial configuration preflight before every side effect. |

**Round 13 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 14 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `NSXPCListenerEndpoint` cannot be archived by `NSKeyedArchiver`; it may only be encoded by `NSXPCCoder`. | Replace anonymous-XPC transport with an app-side, single-use launch-nonce callback over the existing authenticated loopback relay; UI test cannot submit app-kind registration, and app startup blocks until its stable identity is journaled. |
| 2 | Medium | Participant registration requirements contradicted disposable-simulator ownership and absence of host IPC. | Remove participant registration changes; deleting/verifying the run-owned disposable simulator is the sole participant app/runner ownership proof. |

**Round 14 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 15 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Existing deferred owner `resetLocalState` terminates/relaunches Catalyst and would reuse the consumed app nonce during cleanup. | Apply reset during the single initial registered owner launch, remove the deferred relaunch for this live flow, and terminate/verify only the registered process. |

**Round 15 result:** Finding addressed in plan and design. **Re-review required before Task 1.**

### Round 16 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | App callback lacked an explicit relay-secret injection, host nonce reservation, and authenticated app route contract. | Pre-reserve exact app metadata/nonce, inject relay secret+nonce only into `UITargetAppEnvironmentVariables`, add bearer-authenticated `/register-app`, consume once, and journal stable identity before ack. |
| 2 | Medium | Participant still deferred `resetLocalState`, causing an unnecessary cleanup relaunch despite disposable-simulator ownership. | Remove only the deferred cleanup relaunch; preserve and test the intentional mid-scenario restart/rejoin behavior. |

**Round 16 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 17 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Planned HTTP `/register-app` was incompatible with the relay's actual newline-delimited JSON wire protocol. | Add bounded JSON operations `register-runner`, `prepare-app-launch`, and `register-app` to the existing framing; app uses a compatible raw TCP JSON-line client. |
| 2 | High | Runner authentication was underspecified even though every relay request requires the shared secret. | Give runner the existing relay secret plus a distinct pre-reserved runner nonce; validate secret, operation, role/kind, reservation, stable identity, and bundle before journal/ack. App receives a separate app nonce. |

**Round 17 result:** All findings addressed in plan and design. **Re-review required before Task 1.**

### Round 18 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `prepare-app-launch` omitted `kind`, so the relay's shared guard rejected it before dispatch. | Send exact `{secret, op, runID, role:"owner", kind:"runner", nonce:runnerNonce}` and require the acknowledged runner registration before journaling app intent; add wire-level regression. |

**Round 18 result:** Finding addressed in plan. **Re-review required before Task 1.**

### Round 19 — Luna re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| — | — | No actionable Critical, High, or Medium findings. | None required. |

**Round 19 result:** **PASS — 0 open Critical/High/Medium findings.**
