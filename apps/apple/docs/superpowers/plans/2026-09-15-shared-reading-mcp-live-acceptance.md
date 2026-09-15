# Shared Reading MCP and Live Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the registered Swift MCP server the sole owner of one Catalyst and one iPhone Rishi test session, then prove through Codex that the real production-backed shared-reading feature works and cleans up safely.

**Architecture:** A Swift stdio MCP server exposes a bounded semantic tool set and owns an audited destination-locked XCTest bridge. The E2E host supplies fixtures, rendezvous, OS sampling, and evidence verification but cannot launch app peers. Independent signed producers feed one hash-chained run ledger that binds source SHA, binaries, targets, MCP actions, UI observations, Worker events, and cleanup.

**Tech Stack:** Swift 6, Foundation process APIs, CryptoKit Ed25519, MCP JSON-RPC over stdio, XCTest/XCUITest, Xcode result bundles, macOS process inspection, Codex MCP configuration, production Rishi APIs.

---

## File ownership map

- MCP protocol/parity owner: `apps/apple/rishi-mcp/Package.swift`, `Sources/RishiAppleMCP/{MCPProtocol,AppTools,main}.swift`, matching tests, legacy Node MCP files only at parity commit.
- Process owner: `InstanceRegistry.swift`, `XCTestDriver.swift`, `XcodeToolchain.swift`, `MemorySnapshot.swift`, `ResourcePreflight.swift`, new `ProcessSupervisor.swift`, matching tests.
- Evidence owner: new MCP/E2E evidence files, E2E `ProcessRunner.swift`, `ResourcePreflight.swift`, `SharedReadingHost.swift`, tests.
- UI bridge owner: `apps/apple/rishi/rishiUITests/MCPControlUITests.swift` and the shared-reading UI-test support files.
- Live operator: no source edits; owns only run-scoped evidence and cleanup.

The E2E host must not start Catalyst/iPhone XCTest peers in the accepted path.
The host may prepare/verify builds and fixtures, run independent sampling, and
verify evidence. MCP exclusively starts/stops bridge/app processes.

## Mandatory command/result wrapper

Every SwiftPM, XCTest, build, and live peer command below runs through
`scripts/test-integrity/run-verified.ts`; raw commands shown are the arguments
after `--`. SwiftPM uses `swift-output`, XCTest uses a unique `xcresult`, and
build/registration/cleanup uses `command`. Green tests require discovered `> 0`,
skipped/failed `0`, exit `0`; red tests require discovered/failed `> 0`, nonzero
exit. Missing or unparseable output fails. Live result bundles are additionally
verified by `rishi-e2e-host verify-run` in M6.

## Task M0: Prove Swift MCP protocol parity before deleting Node MCP

**Files:**

- Modify: `apps/apple/rishi-mcp/Package.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/main.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`
- Delete only after green parity: legacy `apps/apple/rishi-mcp/package.json`, `src/*.mjs`, `test/*.mjs`

- [ ] **Step 1: Pin the public tool contract**

Tests require exactly this bounded set:

```swift
let expectedTools: Set<String> = [
    "list_app_instances", "memory_snapshot", "start_app", "stop_app",
    "restart_app", "inspect_app_state", "capture_screenshot",
    "select_book", "create_reading_session", "join_reading_session",
    "wait_for_participant", "start_reading_session", "open_shared_book",
    "send_reader_action", "open_active_sessions",
    "rejoin_active_session", "leave_reading_session", "end_reading_session",
]
```

Assert initialize metadata, `tools/list`, structured `tools/call`, malformed JSON,
unknown methods/tools, missing/unknown/invalid arguments, maximum line size, and
stdout purity. There is no shell, arbitrary URL, raw coordinate, token-dump, or
session-injection tool.

- [ ] **Step 2: Write semantic contract tests**

Require deterministic book ID, destination, and explicit action enums. Return
invite tokens only in the direct tool result; redact them from logs/evidence.

```swift
enum ReaderAction: String, Codable, CaseIterable {
    case nextPage, previousPage, play, pause, resume
}
```

`join_reading_session` accepts the canonical invite URL supplied by the owner
tool result; it does not accept a bearer session or internal room command.

- [ ] **Step 3: Run Swift and legacy parity suites**

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M0.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/swift-green.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp
bun scripts/test-integrity/run-verified.ts --format node-test --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/node-green.json" --cwd . -- node --test --test-reporter=tap apps/apple/rishi-mcp/test/*.test.mjs
```

Expected before deletion: both suites discover tests and pass the same public
contract. Missing Node dependencies or any inability to execute either runtime
is a hard failure: do not delete Node files. Record a parity matrix mapping every
executed Node assertion to an executed Swift assertion, with discovered `> 0`,
skipped/failed `0`, and exit `0` for both runtimes.

- [ ] **Step 4: Delete Node only in the parity commit**

```bash
git diff --name-only -- apps/apple/rishi-mcp/Package.swift apps/apple/rishi-mcp/README.md apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/main.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift apps/apple/rishi-mcp/package.json apps/apple/rishi-mcp/src/app-tools.mjs apps/apple/rishi-mcp/src/index.mjs apps/apple/rishi-mcp/src/instance-registry.mjs apps/apple/rishi-mcp/src/memory.mjs apps/apple/rishi-mcp/src/protocol.mjs apps/apple/rishi-mcp/src/xcode-toolchain.mjs apps/apple/rishi-mcp/src/xctest-driver.mjs apps/apple/rishi-mcp/test/app-tools.test.mjs apps/apple/rishi-mcp/test/instance-registry.test.mjs apps/apple/rishi-mcp/test/protocol.test.mjs apps/apple/rishi-mcp/test/server.test.mjs apps/apple/rishi-mcp/test/xcode-toolchain.test.mjs apps/apple/rishi-mcp/test/xctest-driver.test.mjs
git add apps/apple/rishi-mcp/Package.swift apps/apple/rishi-mcp/README.md apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/main.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift apps/apple/rishi-mcp/package.json apps/apple/rishi-mcp/src/app-tools.mjs apps/apple/rishi-mcp/src/index.mjs apps/apple/rishi-mcp/src/instance-registry.mjs apps/apple/rishi-mcp/src/memory.mjs apps/apple/rishi-mcp/src/protocol.mjs apps/apple/rishi-mcp/src/xcode-toolchain.mjs apps/apple/rishi-mcp/src/xctest-driver.mjs apps/apple/rishi-mcp/test/app-tools.test.mjs apps/apple/rishi-mcp/test/instance-registry.test.mjs apps/apple/rishi-mcp/test/protocol.test.mjs apps/apple/rishi-mcp/test/server.test.mjs apps/apple/rishi-mcp/test/xcode-toolchain.test.mjs apps/apple/rishi-mcp/test/xctest-driver.test.mjs
git diff --cached --name-status
git commit -m "feat(mcp): replace Apple server with Swift"
```

Expected: Swift tests exit `0`, discovered `> 0`, skipped/failed `0`; review
shows each Node tool/error/ownership assertion has a Swift equivalent.

## Task M1: Centralize audited process and resource ownership

**Files:**

- Create: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/ProcessSupervisor.swift`
- Create: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ProcessSupervisorTests.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`

- [ ] **Step 1: Write launch-gate and cleanup red tests**

Cover concurrent same-target start, pre-existing unowned app, stale/replaced lock,
launch failure, timeout, normal exit, cancellation, descendant escape attempt,
and a short-lived duplicate. Assert every accepted child has one audit event.

```swift
struct ProcessLaunchRecord: Codable, Sendable {
    let executableSHA256: String
    let parentPID: Int32
    let childPID: Int32
    let childStartTime: UInt64
    let destination: String
    let acceptedAt: Date
}
```

Run before implementation:

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M1-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect fail --require-failure-id "ProcessSupervisorTests.concurrentSameTargetStartIsRejected" --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter 'ProcessSupervisorTests|InstanceRegistryTests|MemorySnapshotTests|ResourcePreflightTests|XCTestDriverTests'
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero. Missing
or unparseable output blocks implementation.

- [ ] **Step 2: Implement one process supervisor**

All production `Process` creation goes through:

```swift
protocol ProcessSupervising: Sendable {
    func launch(_ request: ManagedLaunchRequest) async throws -> ManagedProcess
    func terminateTree(for process: ManagedProcess) async throws
    func reconcileOwnedProcesses() async throws -> ProcessReconciliation
}
```

Acquire an exclusive destination lock before launch; record executable, parent,
child, start time, and target; retain the lock through descendant exit. Static
tests scan production sources and fail on direct `Process()` outside the
supervisor.

- [ ] **Step 3: Enforce exact resource gates**

Before package resolution, each serialized build, and each live phase require:

```swift
let minimumAvailableMemory: UInt64 = 8 * 1024 * 1024 * 1024
let minimumFreeDisk: UInt64 = 20 * 1024 * 1024 * 1024
let abortAvailableMemory: UInt64 = 2 * 1024 * 1024 * 1024
let maximumOwnedRSS: UInt64 = 6 * 1024 * 1024 * 1024
let sampleInterval: Duration = .seconds(5)
```

Abort after two consecutive low-memory samples or one owned-RSS breach. Each
gate uses a sample no older than ten seconds and records current/peak RSS per
owned MCP, E2E, Xcode, XCTest, Catalyst, Simulator app process.

- [ ] **Step 4: Run ownership/resource tests**

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M1-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter 'ProcessSupervisorTests|InstanceRegistryTests|MemorySnapshotTests|ResourcePreflightTests|XCTestDriverTests'
```

Expected: discovered `> 0`, skipped/failed `0`, exit `0`; every fake owned PID
reconciles to an accepted launch and cleanup leaves none.

- [ ] **Step 5: Commit process-owned files**

```bash
git diff --name-only -- apps/apple/rishi-mcp/Sources/RishiAppleMCP/ProcessSupervisor.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ProcessSupervisorTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift
git add apps/apple/rishi-mcp/Sources/RishiAppleMCP/ProcessSupervisor.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ProcessSupervisorTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift
git diff --cached --name-status
git commit -m "fix(mcp): own Apple test processes safely"
```

## Task M2: Build independently sourced, tamper-evident evidence

**Files:**

- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceRecord.swift`
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceLedger.swift`
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceVerifier.swift`
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/OSProcessSampler.swift`
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SessionObservationVerifier.swift`
- Create matching tests
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift`

- [ ] **Step 1: Write hash-chain, signature, redaction, and source tests**

Test mutation, truncation, reordering, wrong signature, duplicate sequence,
mismatched run UUID/digest, stale sample, coordinator-only checkpoint, secret
patterns, and producer identity mismatch.

```swift
struct EvidenceEnvelope: Codable, Sendable {
    let runID: UUID
    let producerID: String
    let producerPID: Int32
    let producerExecutableSHA256: String
    let sequence: UInt64
    let timestamp: Date
    let previousDigest: String
    let payload: EvidencePayload
    let signature: Data
}
```

Run before implementation:

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M2-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect fail --require-failure-id "EvidenceVerifierTests.rejectsSingleProducerFabrication" --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-e2e-host --filter 'Evidence|OSProcessSampler|SessionObservationVerifier'
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero. Otherwise
do not implement the ledger.

- [ ] **Step 2: Implement separate producer keys**

At run start register public keys plus PID/executable hash for coordinator, MCP,
XCTest bridge/app observations, OS sampler, and production-observation verifier.
Each producer signs only its own records. Private keys are deleted at finalization.

- [ ] **Step 3: Require cross-source causal proof**

The verifier accepts a checkpoint only when an action-source record and an
independent effect-source record share run/session/event identities and causal
ordering. No one producer may attest both action and effect.

M3 adds an internal bridge operation—not a public MCP tool—that asks the running
app to call W3's member-authorized
`GET /api/v1/reading-sessions/:id/observations?after=...` with its existing
in-process bearer. The bearer never crosses the app/bridge boundary. The bridge
returns only the route's redacted session/membership/authority fields and W2
event IDs/digests, then signs that record with the bridge producer key.
`SessionObservationVerifier` validates route schema, account membership role,
monotonic opaque cursor, causal event ID/digest, and redaction before admitting
it to the ledger. Tests reject coordinator-authored copies, raw identities,
profiles, credentials, invite/admission tokens, signed URLs, SDP/ICE, book data,
wrong-session events, removed-member access, and stale cursors.

- [ ] **Step 4: Bind fresh binaries and targets**

Record repository SHA, bundle ID/version, Mach-O UUID/SHA-256, build SHA,
installation/launch timestamps, target UDID/model/OS, process PID/start time,
result bundle, and MCP executable/config hash. Reject a live process that does
not match the same-run build product.

- [ ] **Step 5: Run evidence tests and commit**

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M2-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/host.log" --cwd . -- swift test --package-path apps/apple/rishi-e2e-host --filter 'Evidence|OSProcessSampler|SessionObservationVerifier'
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/mcp.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter MCPProtocolTests
git diff --name-only -- apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceRecord.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceLedger.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceVerifier.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/OSProcessSampler.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SessionObservationVerifier.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/EvidenceLedgerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/EvidenceVerifierTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/OSProcessSamplerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SessionObservationVerifierTests.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceRecord.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceLedger.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/EvidenceVerifier.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/OSProcessSampler.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SessionObservationVerifier.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ProcessRunner.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/EvidenceLedgerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/EvidenceVerifierTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/OSProcessSamplerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SessionObservationVerifierTests.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/MCPProtocol.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift
git diff --cached --name-status
git commit -m "feat(test): attest shared reading evidence"
```

Expected: mutation/fabrication cases fail verification; valid multi-source chain
passes; retained ledger is redacted and signed.

## Task M3: Make the UI bridge fully semantic and fail closed

**Files:**

- Modify: `apps/apple/rishi/rishiUITests/MCPControlUITests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingInviteURLTests.swift`
- Modify: `apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift`

- [ ] **Step 1: Replace skip-based acceptance with explicit failure**

Live acceptance setup must use:

```swift
guard let manifest = SharedReadingLiveManifest.load() else {
    XCTFail("live manifest is required for shared-reading acceptance")
    return
}
```

`XCTSkip` may remain only in suites not counted as live acceptance. The result
counter rejects any skip in the accepted bundles.

- [ ] **Step 2: Implement semantic commands**

Bridge requests use stable book/session/action IDs and emit app-observation
evidence after the UI changes. Catalyst may internally calculate an element
coordinate for XCUI activation; no public MCP coordinate operation exists.

```swift
enum SharedReadingBridgeAction: String, Codable {
    case selectBook, createSession, joinSession, waitForParticipant
    case startSession, openReader, nextPage, pause, resume
    case openActiveSessions, rejoinSession, leaveSession, endSession
}
```

- [ ] **Step 3: Prove bridge behavior with fake app fixtures**

Test unsupported/unknown selectors, timeout, EOF, oversize frames, duplicate
request IDs, redaction, result/effect evidence separation, and Catalyst/iPhone
semantic element discovery.

Run before bridge implementation:

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M3-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect fail --require-failure-id "AppToolsTests.rejectsUnknownOrCoordinateActions" --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter 'AppToolsTests|XCTestDriverTests|MCPProtocolTests'
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero. Otherwise
do not proceed.

- [ ] **Step 4: Run package/UI bridge tests and commit**

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M3-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter 'AppToolsTests|XCTestDriverTests|MCPProtocolTests'
```

Expected: discovered `> 0`, skipped/failed `0`, exit `0`.

- [ ] **Step 5: Commit the exact semantic bridge files**

```bash
git diff --name-only -- apps/apple/rishi/rishiUITests/MCPControlUITests.swift apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift apps/apple/rishi/rishiUITests/SharedReadingInviteURLTests.swift apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift
git add apps/apple/rishi/rishiUITests/MCPControlUITests.swift apps/apple/rishi/rishiUITests/SharedReadingOwnerUITests.swift apps/apple/rishi/rishiUITests/SharedReadingParticipantUITests.swift apps/apple/rishi/rishiUITests/SharedReadingInviteURLTests.swift apps/apple/rishi/rishiUITests/SharedReadingTestSupport.swift apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MCPProtocolTests.swift
git diff --cached --name-status
git commit -m "test(mcp): expose semantic shared reading controls"
```

## Task M4: Restrict the E2E host to preparation and verification

**Files:**

- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/FixtureBookProvisioner.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift`
- Retire from accepted path: `TestAccountClient.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/FixtureBookProvisionerTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift`

- [ ] **Step 1: Write a static ownership red test**

The accepted host source must contain no Catalyst/iPhone peer launch operation.
It may start only its sampler/verifier helpers through the shared supervisor.

Run the new static/behavior test before implementation:

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M4-red.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect fail --require-failure-id "SharedReadingHostTests.testAcceptedHostNeverLaunchesPeers" --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-e2e-host --filter SharedReadingHostTests
```

Expected: discovered/failed `> 0`, skipped `0`, underlying exit nonzero because
the current host still launches peers. Otherwise do not proceed.

- [ ] **Step 2: Use the two designated signed-in accounts**

Remove production test-auth/account creation from accepted configuration. The
manifest contains non-reversible per-run account fingerprints and target IDs,
never credentials, bearer sessions, passwords, or fixture source paths.

- [ ] **Step 3: Keep only preparation/verification responsibilities**

Host preflight verifies canonical endpoints, memory/disk, Xcode, exact iPhone 17
Pro UDID, signed-in app containers, fixture hash, result/evidence directories,
and destination locks. MCP invokes all app actions.

The accepted CLI exposes only:

```text
rishi-e2e-host prepare-run --run-root ABSOLUTE_RUN_ROOT
rishi-e2e-host preflight-run --run-root ABSOLUTE_RUN_ROOT
rishi-e2e-host codex-session-id --run-root ABSOLUTE_RUN_ROOT
rishi-e2e-host assert-codex-policy --run-root ABSOLUTE_RUN_ROOT --sandbox read-only --only-server rishi-apple-shared-reading
rishi-e2e-host verify-run --run-root ABSOLUTE_RUN_ROOT --phase live
rishi-e2e-host verify-run --run-root ABSOLUTE_RUN_ROOT --phase cleanup
```

`prepare-run` initializes only the already-created private supplied root and its `derived/catalyst`,
`derived/iphone17pro`, `results`, `evidence`, and `transcripts` children; it never
launches an app peer. `preflight-run` requires that prepared manifest, refreshes
resource/process/lock samples without recreating or deleting evidence, and never
launches a peer. Cleanup verification directly enumerates every manifest-
owned PID/start-time descendant, destination/build lock, bridge/rendezvous socket,
credential/manifest/cloned-test-spec, derived-data child, result bundle, and
retained evidence entry. Unknown/inaccessible process state, a missing probe, an
unrecognized path, or a disposable survivor exits nonzero. It checks only paths
beneath the supplied absolute run root and never scans/deletes a broad home,
workspace, or `/private/tmp` tree.

- [ ] **Step 4: Run host tests and commit**

```bash
RISHI_RUN_ROOT=$(mktemp -d /private/tmp/rishi-M4-green.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_RUN_ROOT" --artifact "$RISHI_RUN_ROOT/evidence.log" --cwd . -- swift test --package-path apps/apple/rishi-e2e-host
git diff --name-only -- apps/apple/rishi-e2e-host/Package.swift apps/apple/rishi-e2e-host/README.md apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/FixtureBookProvisioner.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/FixtureBookProvisionerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift
git add apps/apple/rishi-e2e-host/Package.swift apps/apple/rishi-e2e-host/README.md apps/apple/rishi-e2e-host/Sources/RishiE2EHost/SharedReadingHost.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/FixtureBookProvisioner.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/RendezvousRelay.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift apps/apple/rishi-e2e-host/Sources/RishiE2EHost/TestAccountClient.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/SharedReadingHostTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/FixtureBookProvisionerTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/RendezvousRelayTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/TestAccountClientTests.swift
git diff --cached --name-status
git commit -m "fix(test): make MCP own shared reading peers"
```

Expected: discovered `> 0`, skipped/failed `0`, exit `0`; static test proves no
accepted host path launches app peers or provisions test-auth accounts.

## Task M5: Register the real Swift MCP server and prove Codex connectivity

**Files:**

- Modify: `apps/apple/rishi-mcp/README.md`
- Create: `apps/apple/rishi-mcp/scripts/register-codex-mcp.sh`
- Create: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/CodexRegistrationTests.swift`
- Machine-local: Codex MCP configuration
- Create run-scoped smoke evidence only

- [ ] **Step 1: Create the audited run and pass resource preflight**

Create the one run root before package resolution or build, using the already
built M4 host CLI. The preflight records memory/disk, current processes, locks,
and the supervisor PID/start-time in the evidence ledger and exits nonzero below
8 GiB available memory or 20 GiB free disk:

```bash
RISHI_SHARED_READING_RUN_ROOT=$(mktemp -d /private/tmp/rishi-shared-reading.XXXXXX)
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/M5-prepare-command.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host prepare-run --run-root "$RISHI_SHARED_READING_RUN_ROOT"
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/M5-resource-preflight.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host preflight-run --run-root "$RISHI_SHARED_READING_RUN_ROOT"
```

- [ ] **Step 2: Build the exact executable through the audited supervisor**

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/M5-build-command.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host supervised-command --run-root "$RISHI_SHARED_READING_RUN_ROOT" -- swift build -c release --package-path apps/apple/rishi-mcp
```

`supervised-command` is implemented and tested in M4 on top of M1's process
supervisor. It records command PID/start time, every descendant, finish status,
and post-build memory/disk sample. Expected: exit `0`; record executable SHA-256
and Swift package source SHA; zero surviving build descendants. It refuses to
start unless the same run UUID has a passing resource preflight sample less than
ten seconds old.

- [ ] **Step 3: Register the absolute stdio executable**

Use this exact server name and executable:

```text
/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi-mcp/.build/release/rishi-apple-mcp
```

Implement `register-codex-mcp.sh` as a fail-closed adapter. It accepts the exact
server name, executable, and output path; uses `codex mcp get --json`; adds only
when the server is absent; rejects a mismatched existing command; then writes
normalized `get` and `list` JSON without environment values. Its Swift test
uses a fake `codex` executable to cover missing/add, exact existing, mismatch,
malformed JSON, add failure, and readback mismatch. Run the tested adapter:

```bash
bun scripts/test-integrity/run-verified.ts --format swift-output --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/M5-registration-tests.log" --cwd . -- swift test --package-path apps/apple/rishi-mcp --filter CodexRegistrationTests
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/M5-registration-command.json" --cwd . -- apps/apple/rishi-mcp/scripts/register-codex-mcp.sh rishi-apple-shared-reading /Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi-mcp/.build/release/rishi-apple-mcp "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-mcp-registration.json"
```

If the first `get` succeeds, do not run `add`; verify its command is byte-for-byte
the path above and stop on mismatch rather than replacing user configuration.
If it reports missing, run `add`, then both readbacks. Store the readback in the
run evidence and hash its normalized server name/transport/command. Expected:
enabled stdio server with no Node fallback or secret environment entries.

- [ ] **Step 4: Perform a real read-only Codex smoke**

Create one run ID and root, then invoke a real non-ephemeral Codex task so the
originating task/session identity can be retained:

```bash
bun scripts/test-integrity/run-verified.ts --format codex-jsonl --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --allow-server rishi-apple-shared-reading --require-tool list_app_instances --require-tool memory_snapshot --raw-output "$RISHI_SHARED_READING_RUN_ROOT/transcripts/codex-read-only.jsonl" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-read-only-normalized.json" --cwd . -- codex exec --json -C /Users/faridmatovu/projects/rishi-monorepo --sandbox read-only "Use only the registered rishi-apple-shared-reading MCP server. Call list_app_instances, then memory_snapshot, and return both structured results without launching an app."
```

Retain raw Codex JSONL containing the actual `thread.started`, `turn.started`,
`mcp_tool_call` item start/update-if-present/completion, and terminal
`turn.completed` events emitted by Codex 0.146. The MCP producer log records correlation
ID, server PID/start time, executable hash, tool name, and redacted result digest.
The independent OS sampler binds that PID/start time/hash. The verifier requires
each Codex call correlation/digest to match the MCP log; direct server invocation
or missing Codex-origin records fails. It also rejects any transcript event for
shell/terminal execution, file writes, arbitrary network access, state injection,
or a tool from any server other than `rishi-apple-shared-reading`. Expected: no
app/Xcode/Simulator launch and no non-MCP capability use.

- [ ] **Step 5: Run a semantic no-op/fail-closed smoke**

Call an invalid book/action identifier and prove a stable validation error. The
server must not fall back to text, index, arbitrary coordinate, or shell action.

Run through the same Codex session with `codex exec resume` and capture the raw
JSONL under the same run root. A direct handcrafted MCP request is not accepted
as Codex connectivity evidence.

```bash
RISHI_CODEX_SESSION_ID=$(apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host codex-session-id --run-root "$RISHI_SHARED_READING_RUN_ROOT")
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-policy-before-invalid.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host assert-codex-policy --run-root "$RISHI_SHARED_READING_RUN_ROOT" --sandbox read-only --only-server rishi-apple-shared-reading
bun scripts/test-integrity/run-verified.ts --format codex-jsonl --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --allow-server rishi-apple-shared-reading --require-tool send_reader_action --require-rejection "send_reader_action=unsupported reader action" --raw-output "$RISHI_SHARED_READING_RUN_ROOT/transcripts/codex-invalid-action.jsonl" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-invalid-action-normalized.json" --cwd . -- codex exec resume --json "$RISHI_CODEX_SESSION_ID" "Use only rishi-apple-shared-reading MCP. Call send_reader_action with an invalid action and report the exact unsupported reader action error. Do not launch or mutate an app."
```

`codex-session-id` parses the retained raw Codex event, rejects zero/multiple/
malformed IDs, and returns the one bound session ID. The transcript/MCP/OS
cross-source verifier must pass before M6. Because this Codex version exposes
the sandbox flag only on the initial `exec`, not `exec resume`, every resume is
preceded by `assert-codex-policy`. It parses immutable session metadata and
fails unless the resumed session inherited `read-only`; it also verifies the
tool inventory contains no accepted MCP server other than
`rishi-apple-shared-reading`.

- [ ] **Step 6: Commit the reviewed registration adapter**

```bash
git diff --name-only -- apps/apple/rishi-mcp/README.md apps/apple/rishi-mcp/scripts/register-codex-mcp.sh apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/CodexRegistrationTests.swift
git add apps/apple/rishi-mcp/README.md apps/apple/rishi-mcp/scripts/register-codex-mcp.sh apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/CodexRegistrationTests.swift
git diff --cached --name-status
git commit -m "test(mcp): prove Codex registration"
```

Expected: only the adapter, its tests, and documentation are committed; the
machine-local registration and run evidence remain untracked.

## Task M6: Run the real two-account production acceptance

**Files:** Run-scoped redacted evidence only; no production source edits

- [ ] **Step 1: Preflight and inventory**

Through MCP and independent sampler, record memory/disk, current process list,
destination locks, exact Catalyst/iPhone 17 Pro targets, signed-in account
fingerprints, build/install identities, production endpoint/Worker versions,
and zero duplicate Rishi instances. Abort if memory is below 8 GiB, disk below
20 GiB, or either target has an unowned/duplicate instance.

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/preflight-command.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host preflight-run --run-root "$RISHI_SHARED_READING_RUN_ROOT"
```

Expected: run directories/manifest exist, no app/Xcode/XCTest peer launched, and
resource/target/build identity checks came from the independent sampler.

- [ ] **Step 2: Start exactly two owned targets**

MCP calls `start_app(catalyst)` then `start_app(iphone17Pro)`. Record every PID,
start time, descendant, lock, result bundle, and memory sample. Do not start a
third app or host-owned peer.

Each `start_app` maps to exactly one fresh invocation of
`rishiUITests/MCPControlUITests/testServer`, launched by the audited MCP
supervisor with these run-scoped result paths:

```text
<run-root>/results/catalyst-owner.xcresult
<run-root>/results/iphone17pro-participant.xcresult
```

Before launch, both paths must be absent. The bridge writes the run UUID,
destination, XCTest identifier, launched app binary SHA-256, bridge PID/start
time, and MCP correlation ID into the evidence ledger. `start_app` returns only
after `testServer` is discovered and the semantic bridge is ready; any skip,
zero discovery, early completion, reused bundle, or metadata mismatch fails.
M3 unit tests prove both destination command lines contain the exact test
identifier, unique `-resultBundlePath`, and run UUID environment binding.

- [ ] **Step 3: Create and join through semantic UI**

Codex calls:

```text
inspect_app_state(catalyst)
select_book(catalyst, deterministicBookID)
create_reading_session(catalyst, deterministicBookID)
join_reading_session(iphone17Pro, canonicalInviteURL)
wait_for_participant(catalyst, distinctAccountFingerprint)
start_reading_session(catalyst)
open_shared_book(catalyst)
```

Execute the sequence through the bound Codex session and retain its raw events:

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-policy-before-live.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host assert-codex-policy --run-root "$RISHI_SHARED_READING_RUN_ROOT" --sandbox read-only --only-server rishi-apple-shared-reading
bun scripts/test-integrity/run-verified.ts --format codex-jsonl --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --allow-server rishi-apple-shared-reading --require-tool start_app --require-tool create_reading_session --require-tool join_reading_session --require-tool wait_for_participant --require-tool start_reading_session --require-tool open_shared_book --require-tool send_reader_action --require-tool restart_app --require-tool open_active_sessions --require-tool rejoin_active_session --require-tool leave_reading_session --require-tool end_reading_session --require-tool stop_app --raw-output "$RISHI_SHARED_READING_RUN_ROOT/transcripts/codex-live-flow.jsonl" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/codex-live-flow-normalized.json" --cwd . -- codex exec resume --json "$RISHI_CODEX_SESSION_ID" "Using only the registered rishi-apple-shared-reading MCP tools and the run manifest's deterministic book ID, perform the recorded sequence: preflight both destinations; start exactly Catalyst and iPhone 17 Pro; create on Catalyst; join on iPhone; wait for the distinct participant; start and open the shared book; move to a precise locator; pause and resume; restart only iPhone; open active sessions and rejoin; verify a newer authoritative sequence; have iPhone leave; have Catalyst end; stop only owned targets. Abort on any tool error, duplicate instance, memory/resource gate, identity mismatch, skipped test, missing observation, or non-MCP capability use."
```

Missing Codex session identity, ordered thread/turn lifecycle events, correlated
MCP item start/completion records,
or independently observed effects makes the run fail even if the UI appears
correct. The live verifier rejects shell/terminal, file-write, arbitrary-network,
direct state-injection, and every MCP-server event whose server name is not
`rishi-apple-shared-reading` before evaluating UI or protocol evidence.

Expected: D1/room evidence proves one canonical invite, one redemption, two
distinct accounts, matching session/book/controller/authority generations. This
proof comes from the app-authenticated W3 observation route and independently
signed bridge observation record, never a coordinator assertion.

- [ ] **Step 4: Prove bidirectional reader state**

Move to a precise locator, then pause/resume. For each action require matching
MCP action record, app UI observation, causal `/v2` frame ID, server membership/
authority observation, and peer UI observation. Session, book, controller,
sequence, exact locator, and playback state must match.

After each action, the bridge asks the app to fetch observations after the prior
opaque cursor. `SessionObservationVerifier` must match the returned W2 event ID
and frame digest to the MCP action and both UI observations.

- [ ] **Step 5: Prove restart, `/active`, and fresh rejoin**

Capture iPhone reader sequence, call `restart_app(iphone17Pro)`, then
`open_active_sessions` and `rejoin_active_session`. Expected: production
`/active` membership evidence, a newly issued admission ticket identity, and one
authoritative snapshot whose accepted sequence is greater than pre-restart.
Cached UI state is not accepted.

- [ ] **Step 6: Prove leave/end and cleanup**

Call participant leave then owner end. Stop only MCP-owned targets. Require local
registry/transport drain, authoritative membership/room state, then three probes
one second apart confirming no socket, reconnect task, token, lease, membership,
or room authority. Reconcile all MCP/E2E/Xcode/XCTest/Rishi descendants.

Run all three member-authorized observation probes while the owner app remains
available, then stop both MCP-owned targets and execute:

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/cleanup-command.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host verify-run --run-root "$RISHI_SHARED_READING_RUN_ROOT" --phase cleanup
```

The cleanup verifier exits nonzero on any surviving owned descendant, missing/
contradictory probe, stale or inaccessible process record, lock/socket/credential/
manifest/cloned-spec/derived-data survivor, unrecognized manifest path, or memory
sample older than ten seconds. It preserves only the redacted evidence/result
bundles under the recorded retention owner/expiry policy.

- [ ] **Step 7: Finalize and independently verify evidence**

Finalize producer signatures and ledger digest; copy public keys/digest/signature
into both result bundles and Codex transcript. Run the independent verifier.

```bash
bun scripts/test-integrity/run-verified.ts --format command --expect pass --owned-output-root "$RISHI_SHARED_READING_RUN_ROOT" --artifact "$RISHI_SHARED_READING_RUN_ROOT/evidence/live-verifier-command.json" --cwd . -- apps/apple/rishi-e2e-host/.build/debug/rishi-e2e-host verify-run --run-root "$RISHI_SHARED_READING_RUN_ROOT" --phase live
```

Expected: discovered `> 0`, passed peer tests `= 1` per target, skipped/failed
`0`. The verifier opens both fresh result bundles with `xcresulttool`, requires
exactly one discovered/passed `MCPControlUITests/testServer` in each, and
cross-checks run UUID, destination, launched binary SHA-256, bridge PID/start
time, and MCP correlation against the ledger and transcript. Any stale or
unbound bundle fails. All process/resource/identity checks pass, retained
evidence is redacted, and disposable locks/sockets/manifests/credentials/cloned
specs/derived data are removed.

## Task M7: Independent MCP/live review

**Files:** Review evidence; source only when fixing findings

- [ ] **Step 1: Protocol/process security review**

Reviewer attempts arbitrary action, coordinate exposure, shell escape, duplicate
launch, unowned cleanup, stale PID reuse, bridge timeout/EOF, secret leakage, and
coordinator-only evidence fabrication.

Round 2 planning review found raw accepted gates, workspace-write Codex
capability, unsupervised preflight/build ordering, and stale peer-bundle risk.
The revised lane wraps every test/build/registration gate, starts Codex in a
read-only sandbox and rejects non-registered-tool events, preflights before the
supervised release build, and binds exactly two fresh
`MCPControlUITests/testServer` bundles to run UUID/binary/PID/correlation
evidence. Fresh independent PASS remains required.

Final Terra and Luna planning verdict: **PASS**, zero open Critical/High
findings.

- [ ] **Step 2: Live-evidence specification review**

Separate reviewer maps every approved completion requirement to same-run source
records and verifies causal linkage rather than screenshots alone.

- [ ] **Step 3: Resolve and re-run**

Fix every Critical/High, re-run affected unit/live checks, and re-review until
both verdicts are `PASS`. A new source/binary SHA invalidates prior live evidence
and requires a fresh run.

- [ ] **Step 4: Final cleanup audit**

Expected: no owned descendants, no destination/build locks, no bridge/rendezvous
sockets, no credentials or disposable manifests, and only the redacted run-UUID
evidence set under its recorded owner/expiry policy.

## Adversarial plan review

### Round 1 — Terra

**Verdict:** RE-REVIEW REQUIRED. High findings identified incomplete DAG/file
ownership, broad staging, and an undefined independent Worker/D1 observation
source. The master now orders every M task and gives M3 sole bridge ownership;
M0/M1/M2/M4 use reviewed exact staging manifests; M2 defines the app-bearer
boundary and independent session-observation verifier against W2/W3's redacted
member-authorized contract; M6 consumes those records. Re-review is required.
