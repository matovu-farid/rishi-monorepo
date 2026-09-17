# Remove Apple Test Memory Gates Implementation Plan

> **Status:** Adversarial review loop complete — **PASS** (4 rounds, 0 open issues)
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple MCP and native two-peer acceptance ignore available-memory levels while preserving memory telemetry, disk enforcement, two-target ownership, and cleanup.

**Architecture:** Both automation packages keep their existing `ResourcePreflight` entry point, but it becomes disk-only. Each preflight gains an internal capacity-provider seam so tests can supply deterministic disk and memory values without consulting the live machine. The provider's optional memory value exists only to prove policy removal: final production providers populate disk alone, and preflight never reads memory. The native host and MCP driver each route their periodic loop through a small independently testable watchdog helper with injected sleep/check/pressure callbacks; production callbacks keep the existing five-second cadence and cleanup route. MCP `MemorySnapshot` continues parsing and reporting available bytes but removes the configured minimum field.

**Tech Stack:** Swift 6, XCTest, Swift Package Manager, Foundation, Darwin process APIs.

**Implementation order:** Native host seam/tests/implementation first, then MCP seam/tests/implementation, then package-wide review and the exact two-target acceptance run. Do not begin acceptance until both package review gates pass.

**Explicitly out of scope:** Electron, Worker code or deployment, UI behavior beyond the existing shared-reading acceptance flow, simulator/device proliferation, and changing production test-account policy.

---

### Task 1: Make the native E2E host preflight disk-only

**Files:**
- Modify: `apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift`
- Create: `apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourceWatchdog.swift`
- Modify: `apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift`
- Modify: `apps/apple/rishi-e2e-host/README.md`

- [ ] **Step 1: Add deterministic resource and watchdog seams without changing behavior**

Add an internal `ResourceCapacity` value (`diskBytes`, optional `memoryBytes`) and a capacity-provider closure to the testable overload of `ResourcePreflight.requireSufficient`; before policy removal, the public/default entry point preserves current filesystem and `vm_stat` behavior through that provider. Move the periodic loop from the CLI into library `ResourceWatchdog.run`, with injected `sleep`, `check`, and `onPressure` async closures. The production CLI supplies a five-second sleep, calls `ResourcePreflight.requireSufficient`, cancels `runTask`, and throws the same `HostError.resourcePressure` through the existing task-group path. Commit or verify this seam separately before changing policy.

- [ ] **Step 2: Replace the memory-floor unit tests with failing no-gate contracts**

Replace `testDefaultMemoryFloorLeavesHostHeadroom`, `testConfiguredFloorCanLowerTheDefaultWhenExplicit`, and `testAvailableMemoryDoesNotDoubleCountPurgeablePages` with:

```swift
func testMemoryThresholdEnvironmentCannotRejectPreflight() throws {
    try ResourcePreflight.requireSufficient(
        for: FileManager.default.temporaryDirectory,
        environment: [
            "RISHI_E2E_MIN_FREE_MEMORY_GB": "1024",
        ],
        capacity: .init(
            diskBytes: 40 * 1024 * 1024 * 1024,
            memoryBytes: 1
        )
    )
}

func testDiskThresholdStillRejectsPreflight() {
    let root = FileManager.default.temporaryDirectory
    XCTAssertThrowsError(
        try ResourcePreflight.requireSufficient(
            for: root,
            environment: [:],
            capacity: .init(diskBytes: 1, memoryBytes: UInt64.max)
        )
    ) { error in
        XCTAssertTrue(error.localizedDescription.contains("Insufficient free disk"))
    }
}
```

Add `ResourceWatchdogTests.swift`. Use a controllable sleeper that records one tick and then suspends until cancellation; prove a successful check keeps the loop alive and never invokes `onPressure`, then cancel and await clean termination. Separately, release one tick, inject a `ResourcePreflightError` from the check, and assert `onPressure` is invoked exactly once with that disk error and the loop terminates. The test must not wait five real seconds or use a zero-duration hot loop.

- [ ] **Step 3: Run the focused tests and verify the memory case is red**

Run:

```bash
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter ResourcePreflightTests/testMemoryThresholdEnvironmentCannotRejectPreflight
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 \
  --filter ResourceWatchdogTests
```

Expected: FAIL because the seam-preserving implementation still enforces the requested 1024 GiB memory minimum. The watchdog tests pass before policy removal and prove the extracted loop preserves cancellation routing.

- [ ] **Step 4: Remove native-host memory enforcement**

In `ResourcePreflight.swift`, leave `defaultMinimumDiskBytes`, disk capacity lookup, disk `configuredMinimum`, and the disk guard. Delete `defaultMinimumMemoryBytes`, the `vm_stat` process, memory parsing helpers used only by preflight, and the memory guard. The final production capacity provider populates `diskBytes` and leaves `memoryBytes` nil. Keep optional `memoryBytes` on the internal test capacity so the green contract can pass `1` and prove it is never consulted. The resulting public entry point remains:

```swift
public static func requireSufficient(
    for path: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    let disk = try availableDiskBytes(at: path)
    let minimumDisk = configuredMinimum(
        key: "RISHI_E2E_MIN_FREE_DISK_GB",
        defaultValue: defaultMinimumDiskBytes,
        environment: environment
    )
    guard disk >= minimumDisk else {
        throw ResourcePreflightError(
            "Insufficient free disk for Apple E2E: \(format(bytes: disk)) available, \(format(bytes: minimumDisk)) required."
        )
    }
}
```

Do not remove any call to `ResourcePreflight.requireSufficient`; those calls become disk-only checks at startup, between sequential builds, and in the active-run watchdog.

- [ ] **Step 5: Update native-host documentation**

Replace the README statements about an 8 GiB floor and memory-triggered cancellation with this contract:

```markdown
The host records normal operating-system failures but does not reserve or gate on available memory.
It checks free disk before Xcode starts and every five seconds while peers are active; insufficient
disk cancels the run and enters the normal account/process cleanup path.
```

Document only `RISHI_E2E_MIN_FREE_DISK_GB`; remove `RISHI_E2E_MIN_FREE_MEMORY_GB` from the supported environment.

- [ ] **Step 6: Run focused and full host tests**

Run:

```bash
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter ResourcePreflightTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1 --filter ResourceWatchdogTests
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

Expected: all ResourcePreflight tests pass; full package has zero failures. The optional real-fixture test may be run with the validated bundled fixture to avoid a skip:

```bash
RISHI_E2E_EPUB_FIXTURE="$PWD/apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Resources/Bundled/alice.epub" \
swift test --package-path apps/apple/rishi-e2e-host --jobs 1
```

- [ ] **Step 7: Commit the host slice**

```bash
git add apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourceWatchdogTests.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourceWatchdog.swift \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHostCLI/main.swift \
  apps/apple/rishi-e2e-host/README.md
git commit -m "test(apple): remove host memory gate"
```

### Task 2: Make Apple MCP preflight disk-only and telemetry gate-free

**Files:**
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift`
- Create: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourceWatchdog.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift`
- Modify: `apps/apple/rishi-mcp/README.md`

- [ ] **Step 1: Add deterministic resource and watchdog seams without changing behavior**

Add an internal `ResourceCapacity` value (`diskBytes`, optional `memoryBytes`) and capacity-provider closure to the testable preflight overload; before policy removal, the production entry point preserves current filesystem and `vm_stat` behavior through that provider. Extract the five-second loop in `XCTestDriver.startResourceWatchdog` to `ResourceWatchdog.run`, with injected sleep/check/pressure callbacks. Production must still call `stopForResourcePressure` after a failed disk check and return after the first pressure event.

- [ ] **Step 2: Write failing MCP preflight, telemetry, and watchdog tests**

Replace memory-floor tests in `ResourcePreflightTests` with:

```swift
func testMemoryThresholdEnvironmentCannotRejectPreflight() throws {
    try ResourcePreflight.requireSufficient(
        for: FileManager.default.temporaryDirectory,
        environment: [
            "RISHI_MCP_MIN_FREE_MEMORY_GB": "1024",
            "RISHI_E2E_MIN_FREE_MEMORY_GB": "1024",
        ],
        capacity: .init(
            diskBytes: 40 * 1024 * 1024 * 1024,
            memoryBytes: 1
        )
    )
}

func testDiskThresholdStillRejectsPreflight() {
    XCTAssertThrowsError(
        try ResourcePreflight.requireSufficient(
            for: FileManager.default.temporaryDirectory,
            environment: [:],
            capacity: .init(diskBytes: 1, memoryBytes: UInt64.max)
        )
    ) { error in
        XCTAssertTrue(error.localizedDescription.contains("Insufficient free disk"))
    }
}
```

Rename the snapshot test to `testSnapshotEmitsAvailableMemoryWithoutConfiguredMinimum` and assert:

```swift
XCTAssertEqual(result["host"]?["availableMemoryBytes"]?.intValue, 40_960)
XCTAssertNil(result["host"]?["configuredMinimumMemoryBytes"])
```

Construct the snapshot without a memory-threshold environment fixture; it is no longer relevant to telemetry output.

Add `ResourceWatchdogTests.swift` with a controllable sleeper that records and suspends each tick. A successful check must not call the pressure callback before cancellation and must terminate cleanly after the sleeper is cancelled; a released tick followed by a throwing disk check must invoke the callback once and stop. These tests directly cover the helper used by `XCTestDriver` without launching an app, waiting five seconds, or spinning.

- [ ] **Step 3: Run the focused tests and verify red**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'ResourcePreflightTests|MemorySnapshotTests/testSnapshotEmitsAvailableMemoryWithoutConfiguredMinimum'
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter ResourceWatchdogTests
```

Expected: the preflight test fails on the 1024 GiB threshold and the snapshot test fails because `configuredMinimumMemoryBytes` still exists. The extracted watchdog tests pass and prove disk failures still reach the stopping callback.

- [ ] **Step 4: Remove MCP memory enforcement and threshold output**

In MCP `ResourcePreflight.swift`, retain only disk capacity and disk threshold logic. The final production capacity provider populates `diskBytes` and leaves optional `memoryBytes` nil; the internal test capacity retains that field so the green contract proves a supplied tiny value is ignored. Keep the shared disk fallback:

```swift
let minimumDisk = configuredMinimum(
    key: "RISHI_MCP_MIN_FREE_DISK_GB",
    fallback: "RISHI_E2E_MIN_FREE_DISK_GB",
    defaultValue: defaultMinimumDiskBytes,
    environment: environment
)
```

Delete the memory constant, `vm_stat` execution, memory parser, and memory guard. Keep `configuredMinimum` because disk uses it.

In `MemorySnapshot.swift`, continue calculating `availableMemoryBytes`, but remove the call that derives a configured minimum and omit `configuredMinimumMemoryBytes` from the returned host object:

```swift
"host": .object([
    "pageSize": .integer(pageSize),
    "pages": .object(pages),
    "processRssKb": .integer(processRSSKb),
    "availableMemoryBytes": .integer(availableMemoryBytes),
])
```

- [ ] **Step 5: Update MCP documentation**

Replace the README's memory floor/watchdog language with:

```markdown
Before Xcode starts and every five seconds while a session is active, the driver enforces free-disk
capacity. Memory snapshots remain available as telemetry, but available memory never blocks or stops
an app session.
```

Document only `RISHI_MCP_MIN_FREE_DISK_GB` and its shared `RISHI_E2E_MIN_FREE_DISK_GB` fallback.

- [ ] **Step 6: Run focused and full MCP tests**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'ResourcePreflightTests|MemorySnapshotTests'
swift test --package-path apps/apple/rishi-mcp --jobs 1 --filter ResourceWatchdogTests
swift test --package-path apps/apple/rishi-mcp --jobs 1
```

Expected: all focused tests and the full package pass with zero failures and no orphaned `RishiAppleMCPTests`, `rishi-apple-mcp`, or `xcodebuild` process.

- [ ] **Step 7: Commit the MCP slice**

```bash
git add apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift \
  apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift \
  apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourceWatchdog.swift \
  apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourceWatchdogTests.swift \
  apps/apple/rishi-mcp/README.md
git commit -m "test(apple-mcp): remove memory gate"
```

### Task 3: Prove no hidden memory gate remains

**Files:**
- Inspect: `apps/apple/rishi-e2e-host/**`
- Inspect: `apps/apple/rishi-mcp/**`

- [ ] **Step 1: Search for rejected contracts**

Run:

```bash
rg -n 'MIN_FREE_MEMORY|defaultMinimumMemory|configuredMinimumMemory|Insufficient available memory|memory floor|memory reserve' \
  apps/apple/rishi-e2e-host/Sources apps/apple/rishi-e2e-host/README.md \
  apps/apple/rishi-mcp/Sources apps/apple/rishi-mcp/README.md
rg -n 'vm_stat|availableMemoryBytes' \
  apps/apple/rishi-e2e-host/Sources/RishiE2EHost/ResourcePreflight.swift \
  apps/apple/rishi-mcp/Sources/RishiAppleMCP/ResourcePreflight.swift
rg -n 'RISHI_(E2E|MCP)_MIN_FREE_MEMORY_GB' \
  apps/apple/rishi-e2e-host/Tests/RishiE2EHostTests/ResourcePreflightTests.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/ResourcePreflightTests.swift
```

Expected: the first two commands have no matches. The final command finds only the two ignored-variable contract tests. MCP `MemorySnapshot.swift` intentionally retains `vm_stat` and `availableMemoryBytes` telemetry and is not included in the preflight-specific zero-match command.

- [ ] **Step 2: Verify disk and ownership safeguards remain**

Run:

```bash
rg -n 'MIN_FREE_DISK|defaultMinimumDisk|Insufficient free disk|AppleXcodeBuildLock|BuildPathLock|killProcessGroup' \
  apps/apple/rishi-e2e-host apps/apple/rishi-mcp
```

Expected: disk checks, shared/exclusive build locks, and process-group cleanup remain present.

- [ ] **Step 3: Run independent spec and quality reviews**

Dispatch one reviewer against the approved design and one independent concurrency/cleanup reviewer. Both review only the two package slices. Fix every Critical/High finding and re-review until both verdicts are PASS or PASS WITH NOTES with no open Critical/High.

- [ ] **Step 4: Push the two implementation commits**

```bash
git push origin feat/apple-shared-reading-sessions
```

Expected: the remote branch advances to the local HEAD without staging or pushing unrelated Worker, Electron, screenshot, or marketing changes.

### Task 4: Resume the exact two-target shared-reading acceptance

**Files:**
- Use: `apps/apple/rishi-e2e-host/README.md`
- Use: `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Resources/Bundled/alice.epub`

- [ ] **Step 1: Prove launch inventory is clean**

Run a PID/PPID/PGID/executable-only inventory. Require no existing `rishi.app`, `xcodebuild`, `rishiUITests`, or unexplained `rishi-apple-mcp` process. Do not collect full command lines.

- [ ] **Step 2: Validate the real fixture**

Run:

```bash
unzip -t apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Resources/Bundled/alice.epub
```

Expected: no archive errors. The focused `RealBookFixturesTests` must pass with `RISHI_E2E_EPUB_FIXTURE` set to this absolute path.

- [ ] **Step 3: Run exactly Catalyst owner and iPhone 17 Pro participant**

Use the existing two-account setup when its sessions are still valid. Otherwise use the native host only when the production data plane has an explicitly approved controlled provisioning configuration, a valid secret and domain are supplied, and `rishi-e2e-host --preflight` confirms the gated route is available. A secret alone is insufficient; 404 or 503 means provisioning is unavailable and acceptance is operationally blocked before launch. Start no third app or simulator. Exercise: owner creates a link, participant joins the same session, both report the same session identity and roster 2/2, owner progress reaches participant, participant cannot publish controller progress, and cleanup returns the app count to zero.

- [ ] **Step 4: Report the acceptance result**

Completion evidence must include exact branch SHA, owner and participant target identities, matching session ID, roster 2/2, progress synchronization, participant permission rejection, and final zero-instance/process inventory. If authentication is the only remaining blocker, report that precise operational requirement without weakening the acceptance flow.

## Consumer / call-site audit

| Consumer | Current call | Planned effect |
|---|---|---|
| Native `SharedReadingHost` preflight/package-resolution checks | `ResourcePreflight.requireSufficient` | Continues rejecting low disk; memory cannot reject. |
| Native CLI active-run loop | Five-second inline resource loop | Uses tested `ResourceWatchdog`; disk error still cancels `runTask` and enters existing cleanup. |
| MCP launch and package-resolution checks | `ResourcePreflight.requireSufficient` | Continues rejecting low disk; memory cannot reject. |
| MCP `XCTestDriver` active session | `startResourceWatchdog` then `stopForResourcePressure` | Uses tested `ResourceWatchdog`; disk error still invokes the existing terminate path. |
| MCP `memory_snapshot` tool | `MemorySnapshot.snapshot` | Reports current available bytes and process RSS; no minimum/floor field. |
| READMEs and environment contract | Memory and disk threshold documentation | Memory threshold variables removed; disk thresholds retained. |

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Independent review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | Resource tests depended on live disk/RAM and MCP's 20 GiB floor. | Added deterministic disk probe seams and controlled capacity values. |
| 2 | High | No direct proof that active-run watchdogs ignore memory while retaining disk cancellation. | Added extracted, injectable watchdog helpers and tests in both packages; production callbacks retain existing cleanup routes. |
| 3 | High | A package-wide zero-match grep contradicted the ignored-variable contract tests. | Scoped production zero-match searches and added a separate assertion that only the tests retain ignored variable names. |
| 4 | High | A test-auth secret alone does not make production provisioning available. | Acceptance now requires approved data-plane configuration, secret/domain, and a successful host preflight; 404/503 blocks before launch. |

**Round 1 result:** Four High findings resolved in the plan. **Re-review required.**

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | Disk-only probe seams still left the red memory tests dependent on live `vm_stat`. | Replaced them with controlled capacity providers carrying sufficient disk and a one-byte memory sample; final production providers omit memory and final preflight ignores the test value. |
| 2 | Medium | An immediate sleeper could hot-loop and race cancellation assertions. | Required a controllable sleeper that suspends, releases a single tick, and terminates through cancellation. |
| 3 | Medium | The telemetry test's old threshold environment would create an unaccounted third variable reference. | Required removal of the obsolete environment fixture from `MemorySnapshotTests`. |

**Round 2 result:** One High and two Medium findings resolved in the plan. **Re-review required.**

### Round 3 — Re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | Medium | Red-phase commands claimed watchdog proof without selecting watchdog tests. | Added explicit `ResourceWatchdogTests` commands to both pre-policy checkpoints. |

**Round 3 result:** One Medium finding resolved in the plan. **Re-review required.**

### Round 4 — Final re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| — | — | No open Critical, High, or Medium findings. | Controlled capacity seams, suspended watchdog clocks, telemetry fixture cleanup, source audits, call-site coverage, and acceptance prerequisites verified against current code. |

**Round 4 result:** **PASS — 0 open issues.**
