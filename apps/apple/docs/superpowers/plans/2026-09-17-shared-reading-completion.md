# Shared Reading Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a verified shared-reading feature in the Apple app, controlled through the Swift MCP server, with exactly one Mac Catalyst owner and one iPhone 17 Pro participant using their existing signed-in accounts.

**Architecture:** Keep the MCP server as a local stdio process outside the app and use the dedicated `rishi-mcp` Xcode scheme plus semantic accessibility selectors. Keep the production app and sharing Workers unchanged unless live evidence demonstrates a feature defect. Every launch is resource-gated, every app process is MCP-owned, and the final proof is tied to the exact PR head.

**Tech Stack:** Swift 6, XCTest/XCUI, Swift Package Manager, Codex CLI MCP, Xcode 26, iPhone 17 Pro Simulator, Mac Catalyst, Cloudflare Workers, GitHub Actions.

---

## Scope and non-negotiable invariants

- Scope is PR #256, branch `feat/apple-shared-reading-sessions`, relative to `origin/main`.
- `origin/main` must remain the merge base; do not fold unrelated local changes into this branch.
- The deprecated Electron app is out of scope and must not be built, tested, moved, or edited here.
- Do not use test-auth, injected sessions, fake MCP drivers, raw coordinates, or additional app instances for acceptance.
- Use exactly two app targets: `catalyst` as owner and `iphone17` as participant.
- Preserve the two existing signed-in accounts and the existing imported book.
- Never lower the MCP's 8 GiB available-memory floor or 20 GiB free-disk floor.
- Run memory-heavy Apple commands sequentially. Before and after each launch, prove there is no stale `rishi`, XCTest, `xcodebuild`, or MCP process.
- A green unit test is not proof that sharing works. Completion requires visible create, join, participant, synchronized progress, leave/end, and cleanup observations from both targets.

## Authoritative baseline

At plan creation:

- PR head: `02a4aa78a599085d18c26f5042d99a8382251075`.
- `origin/main`: `70557b0631bff63e495d2dd3244b1da5950a5cc1`.
- Merge base equals `origin/main`; the branch is 43 commits ahead.
- GitHub checks pass: Anti-Steering + Entitlements, Test result integrity, Web, Worker typecheck.
- Dedicated Catalyst semantic tests pass 4/4 after restarting stale `testmanagerd`.
- Dedicated iPhone semantic tests pass 4/4.
- Real Codex discovery and read-only calls to the Swift MCP pass when user config is isolated.
- Live two-person acceptance is not proven.
- Host memory is below the 8 GiB launch floor.
- An unfiltered MCP memory snapshot exposes all process command lines; a local red/green fix exists but is not committed.
- `swift test --jobs 1` has an order-dependent hang even though all 50 tests pass in isolated class groups.

## Completion matrix

| Gate | Authoritative proof | Pass condition |
|---|---|---|
| Scope | `git merge-base`, `git diff --name-only`, clean-worktree status | Base equals current `origin/main`; no Electron or unrelated dirty paths committed |
| MCP privacy | Swift regression test + real Codex response | Empty filter returns host memory and `matchingProcesses: []`; no unrelated command lines |
| MCP suite | One bounded full Swift test invocation | All tests exit 0 in one process; no hang or orphan descendants |
| Codex registration | `codex mcp get` + isolated `codex exec --json` | Command is the Swift executable; no Node entrypoint; list/memory calls succeed |
| Resource safety | MCP `memory_snapshot`, `df`, process inventory | Available memory >= 8 GiB, disk >= 20 GiB, zero pre-existing Rishi instances |
| Shared reading | Live MCP transcript + screenshots/state from both targets | Create, join, roster 2/2, synchronized progress, leave/end all succeed |
| Cleanup | MCP list/memory + OS process inventory | Zero app instances and zero owned XCTest/Xcode/MCP descendants |
| Review | Independent spec and code-quality verdicts | Zero open Critical/High findings |
| Merge | GitHub PR state and post-merge SHA | Required checks pass, PR merged, merge commit reachable from `origin/main` |
| Deployment | Worker health/deploy evidence only if branch changes Worker runtime | Deployment succeeds without startup CPU error; production health/version matches merged SHA |

## Subagent execution map

Subagents work in isolated worktrees based on the exact feature-branch head. They must not edit the shared checkout, reuse another agent's worktree, or commit unrelated dirty files.

| Sequence | Model/role | Scope | Required handoff |
|---|---|---|---|
| 1A | Terra, independent spec/security reviewer | Entire plan plus the two-file memory privacy patch; read-only and parallel with 1B | Verdict, severity-ordered findings, missing proof, privacy compliance |
| 1B | Luna, lifecycle investigator/implementer | Task 2 only: reproduce, test, fix, and commit the full-suite hang | DONE status, root cause, focused commit SHA, full-suite and orphan-process evidence |
| 2 | Luna, privacy implementer | Task 1 only after Terra's plan/privacy review is resolved | Focused privacy commit and four-test result |
| 3A | Terra, spec-compliance reviewer | Review each implementation commit against its task and invariants | PASS or actionable gaps; no code edits |
| 3B | Terra, code-quality reviewer | Starts only after 3A passes; review races, privacy, cleanup, and maintainability | PASS or severity-ordered findings; no code edits |
| 4 | Luna, acceptance-infrastructure implementer | Tasks 3–4 implementation only; wrappers, runner, registration phase, verifiers, provenance producers; no GUI | Focused commit, normalized unit-test artifacts, no launched apps |
| 5 | Terra, live-run controller | One uninterrupted invocation of the complete Tasks 4–6 state machine | Separate 0/1/0 and 0/1/2/0 ledgers, evidence paths, failure details if any |
| 6 | Luna, final evidence auditor | Task 7 release artifacts and process cleanup, read-only | Requirement-by-requirement completion matrix |
| 7 | Terra, final branch reviewer | Entire final PR diff and evidence | PASS with zero open Critical/High issues before merge |

Execution rules:

1. Only 1A and 1B run concurrently because one is read-only and their file ownership cannot conflict.
2. Implementation tasks run sequentially. The controller cherry-picks one reviewed commit at a time onto the feature branch.
3. Every implementation receives spec review first and code-quality review second. Any finding returns to the same implementer, then to the same reviewer for re-review.
4. Runtime agents may launch apps only after the controller independently confirms the memory/disk/process gate.
5. A subagent may report `BLOCKED`; it must include the exact command, terminal evidence, and smallest unresolved condition. The controller must not replace a blocked live run with mock evidence.
6. Review agents never modify code. Implementation agents never merge the PR or deploy production.

### Task 1: Commit the MCP memory privacy repair

**Files:**
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift`
- Modify: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift`

- [ ] **Step 1: Preserve the red test**

The test must record every injected runner invocation, feed a fake host process command containing a secret-like argument if broad enumeration is attempted, and require both an empty process array and proof that `ps -axo` was never invoked for `snapshot(match: "")`:

```swift
let result = try await snapshot.snapshot(match: "")
XCTAssertEqual(result["matchingProcesses"]?.arrayValue, [])
XCTAssertFalse(invocations.contains { $0 == ["ps", "-axo", "pid=,rss=,command="] })
```

- [ ] **Step 2: Verify the test fails without the implementation**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter MemorySnapshotTests.testUnfilteredSnapshotDoesNotExposeHostProcessCommands
```

Expected before the fix: failure showing the fake `/usr/bin/example --secret-value` process in `matchingProcesses` and/or the forbidden broad-process invocation in `invocations`. Expected after the fix: the broad invocation is absent, not merely filtered after collection.

- [ ] **Step 3: Skip process enumeration for an empty filter**

Implement the equivalent of:

```swift
let processOutput = processMatch.isEmpty
    ? ""
    : try await runProcess(
        "/usr/bin/env",
        ["ps", "-axo", "pid=,rss=,command="],
        environment,
        .seconds(3)
    ).stdout
```

Filtered `catalyst` and `iphone17` calls must continue to enumerate only Rishi processes.

- [ ] **Step 4: Run focused verification**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 --filter MemorySnapshotTests
git diff --check -- \
  apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift
```

Expected: 4 tests pass; `git diff --check` produces no output.

- [ ] **Step 5: Obtain independent reviews and commit**

Require a spec reviewer and then a code-quality reviewer. Resolve every Critical/High finding and re-review. Commit only the two files:

```bash
git add apps/apple/rishi-mcp/Sources/RishiAppleMCP/MemorySnapshot.swift \
  apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/MemorySnapshotTests.swift
git commit -m "fix: redact unfiltered mcp memory snapshots"
```

### Task 2: Remove the order-dependent Swift suite hang

**Files:**
- Inspect: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- Inspect/modify only if proven: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Inspect/modify only if proven: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XcodeToolchain.swift`
- Modify if needed for the bounded diagnostic: `scripts/test-integrity/run-verified.ts`
- Test if modified: `scripts/test-integrity/run-verified.test.ts`

- [ ] **Step 1: Add and prove the hard-timeout primitive**

Use TDD in `run-verified.test.ts` to add a strict positive-integer `--timeout-ms` option to `run-verified.ts`. The red test must start a fixture that leaves a child alive beyond the deadline. The implementation must race the owned session against the wall clock; on timeout it must terminate and await the owned POSIX session/process group, inventory remaining descendants by PID/PPID/PGID/executable (never full command line), record the timeout and cleanup signals in the normalized artifact, and fail if any descendant remains. Run the new focused runner tests before using the option.

- [ ] **Step 2: Reproduce from a clean worktree with the proven outer bound**

Run the full suite once through the now-tested hard timeout while recording elapsed time and process descendants:

```bash
bun scripts/test-integrity/run-verified.ts swift-output \
  --expect pass \
  --timeout-ms 300000 \
  --artifact /private/tmp/rishi-mcp-full-suite.json \
  --cwd "$PWD" \
  -- swift test --package-path apps/apple/rishi-mcp --jobs 1
```

Expected current failure: the test process remains sleeping beyond five minutes with no completion output. Do not repeatedly launch it.

- [ ] **Step 3: Find the order-dependent pair**

Use class partitions first, then bisect only `XCTestDriverTests`. The known partitions are:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'AppToolsTests|InstanceRegistryTests|MCPProtocolTests|MemorySnapshotTests|ResourcePreflightTests'
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'XCTestDriverTests/(testBridge|testBuild|testCommand|testConfigured|testDefault|testFalls|testGeneric|testIPhone|testRejects|testSelects|testUses)'
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'XCTestDriverTests/testStopCoordinator'
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter 'XCTestDriverTests/(testManagedProcessCleanup|testNormallyCompletedCommand|testNormalRootExit|testTimedOutCommand)'
```

All four partitions must pass before changing production code. Add a regression test that reproduces the exact combined-order hang.

- [ ] **Step 4: Fix lifecycle ownership, not the timeout value**

The fix must ensure every `ManagedProcess` monitor, pipe reader, continuation, timeout task, child process, and process group reaches one terminal state. Do not increase sleeps or weaken cleanup assertions.

- [ ] **Step 5: Prove one-process suite completion and no orphans**

Run:

```bash
bun scripts/test-integrity/run-verified.ts swift-output \
  --expect pass --timeout-ms 300000 \
  --artifact /private/tmp/rishi-mcp-full-suite-final.json \
  --cwd "$PWD" \
  -- swift test --package-path apps/apple/rishi-mcp --jobs 1
if ps -axo pid=,ppid=,pgid=,comm= | rg -q 'RishiAppleMCPTests|rishi-apple-mcp|xcodebuild|rishiUITests|rishi.app'; then exit 1; fi
```

Expected: all tests pass in one invocation and the explicit inverse process assertion exits zero because it finds no orphan.

- [ ] **Step 6: Review and commit**

Require spec review, code-quality review, and re-review after fixes. Commit only the proven lifecycle files and tests.

### Task 3: Implement and review acceptance infrastructure without launching apps

**Files:**
- Modify: `apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh`
- Add: `scripts/test-integrity/run-shared-reading-acceptance-wrapper.test.ts`
- Modify: `scripts/test-integrity/run-rishi-mcp-acceptance.ts`
- Modify: `scripts/test-integrity/run-rishi-mcp-acceptance.test.ts`
- Modify: `scripts/test-integrity/verify-shared-reading-release.ts`
- Modify: `scripts/test-integrity/verify-shared-reading-release.test.ts`
- Add: `scripts/test-integrity/verify-rishi-codex-action.ts`
- Add: `scripts/test-integrity/verify-rishi-codex-action.test.ts`
- Modify: `scripts/test-integrity/run-shared-reading-release.ts`
- Modify: `scripts/test-integrity/run-shared-reading-release.test.ts`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/AppTools.swift`
- Modify: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/InstanceRegistry.swift`
- Modify if needed: `apps/apple/rishi-mcp/Sources/RishiAppleMCP/XCTestDriver.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/AppToolsTests.swift`
- Test: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/InstanceRegistryTests.swift`
- Test if driver changes: `apps/apple/rishi-mcp/Tests/RishiAppleMCPTests/XCTestDriverTests.swift`
- Add: `apps/apple/rishi-mcp/test-command-contract.json`

- [ ] **Step 1: Add runner invariants and lifecycle evidence with red tests**

Before any live run, add failing unit tests and then the minimum implementation for all of these contracts:

1. Replace generic `--mcp-binary` and caller-supplied `--mcp-env-file` with required `--mcp-binary-provenance` and `--mcp-environment-provenance`, and add `--controller-mcp-allowlist` to the shell wrapper. Its test must prove exact argv forwarding, reject generic binary/environment overrides, and prove the wrapper never reads, expands, evaluates, or sources any evidence file.
2. The TypeScript client parses the exact four-value environment data file without shell evaluation, adds release-owned `RISHI_MCP_ATTEMPT_ID`, `RISHI_MCP_PHASE_ID`, and phase-specific `RISHI_MCP_RECEIPT_PATH` values generated by the runner, passes that explicit environment to the MCP `Bun.spawn`, creates one owned POSIX session/process group, and enforces a configurable per-RPC deadline plus a strictly larger whole-phase deadline. The Codex and direct phases use distinct absent paths `launch-receipt-codex.json` and `launch-receipt-direct.json`. Before `start_app` returns, the Swift MCP server atomically persists its mode-`0600` canonical phase receipt, bound to attempt/phase ID, server PID/executable/start-time, target, and target identity: Catalyst PID/executable/start-time/bundle ID plus its driver PGID, or iPhone simulator UDID/bundle ID plus every launched xcodebuild/XCTest/app PID, executable, start time, and owned PGID. The receipt is updated before every response and is cleanup authority even if the response is dropped. Phase startup refuses a pre-existing path; after cleanup it atomically records terminal zero-state and becomes immutable. The next phase starts only after the prior terminal receipt verifies; both receipt hashes remain in the final manifest. Either deadline enters `finally`: request cancellation, bounded app-stop attempts where the transport still responds, stdin close, TERM then KILL only within the MCP-owned session, then an identity-bound out-of-band reaper consuming that phase receipt. The reaper revalidates every recorded process identity and may TERM/KILL only recorded positive target PGIDs that are not the controller/current PGID; it then signals the recorded Catalyst app PID and calls bounded `xcrun simctl terminate` only for the recorded iPhone UDID/bundle ID. Any identity mismatch is a hard cleanup failure and unrelated processes are never signaled. Final process-group and simulator inventories must prove all recorded xcodebuild/XCTest/app identities and bundles absent. Unit tests cover receipt succession, a response dropped after server-side launch/receipt write, never-responding `tools/call` after each target starts, whole-phase timeout, transport death, TERM/KILL escalation, receipt tampering/stale attempt, PID/PGID reuse or mismatch refusal, nonpositive/current-group refusal, exact simulator termination argv, unrelated-process preservation, and cleanup failure. No full command line is persisted.
3. The runner records `instanceCountLedger: [0, 1, 2, 0]`, observing `list_app_instances` immediately after each start and after cleanup. The release verifier requires the exact ledger and call order.
4. Both `wait_for_participant` results are retained and parsed. The runner requires one equal non-empty session ID plus `participantCount == 2` and `participantCapacity == 2` for both targets. Persist only redacted booleans/counts as `sessionInvariant: { matchingNonEmptyIDs: true, ownerCount: 2, ownerCapacity: 2, participantCount: 2, participantCapacity: 2 }`; the release verifier requires those exact values.
5. Accept and validate a SHA-bound controller allowlist path containing only MCP hosts that pre-existed the release attempt. Each phase separately records its provenance-bound release MCP root PID/PGID/executable/start-time when spawned. During a phase, valid hosts are exactly the immutable controller allowlist plus that phase's one recorded release root; between/final phases only controller identities may remain. Evidence adds `processLifecycle` with each release root, bounded-shutdown outcome, pre/post executable-only inventories, controller allowlist content hash, and `remainingReleaseHosts: []`. The release verifier rejects missing fields, survivors, unexpected Rishi/XCTest/xcodebuild executables, unrecorded MCP hosts, or controller/release identity mismatch.
6. Implement and test `verify-rishi-codex-action.ts` for the separate ordered Codex `0/1/0` action proof.

- [ ] **Step 2: Make provenance artifacts release-run outputs**

Extend the release manifest/runner with explicit producer steps that begin with absent outputs and atomically create them during one exact-SHA release attempt. The release runner—not the caller—generates a fresh lowercase UUID `attemptId`, derives `/private/tmp/rishi-shared-reading-acceptance-<SHA>-<ATTEMPT_UUID>`, and rejects any pre-existing path including an empty directory before creating it. The release manifest artifact, every security/provenance artifact, and both live acceptance reports contain the same `attemptId`; normalized test artifacts are bound transitively by their SHA-256 entries in that signed release manifest artifact. Evidence roots are never reused. A final rerun creates a new attempt/root, preserves the prior attempt as historical evidence, and designates exactly one fully passing attempt in the final report. Tests inject a deterministic UUID and prove collision/pre-existing-root rejection.

All security/provenance JSON listed below, the controller allowlist, both live acceptance reports, and the final release manifest artifact use one canonical contract: recursively sort object keys lexicographically, preserve array order, encode JSON as UTF-8 with no insignificant whitespace and one trailing LF. For an object with `contentHash`, compute SHA-256 over the canonical UTF-8 bytes of the same object with only its top-level `contentHash` field removed; then serialize the signed object canonically. Verifiers reject non-canonical bytes, duplicate JSON keys, invalid UTF-8, an altered payload/digest, or a mismatched `attemptId`/SHA. Ordinary `run-verified` normalized artifacts need not change encoding; their exact bytes are SHA-256-bound into the canonical release manifest artifact.

Before any build producer, the release runner performs the Task 5 memory/disk/zero-instance/process gate and verifies the repository worktree is clean with `HEAD == sha`. The first producers create absent attempt-local Swift and Apple build directories, run `swift build --package-path apps/apple/rishi-mcp --scratch-path <attempt-root>/swift-build --jobs 1`, then run exact-destination `xcodebuild build-for-testing` for Catalyst and iPhone 17 Pro with derived-data paths under `<attempt-root>/derived-data/{catalyst,iphone17}`. A checked-in `test-command-contract.json`, loaded and schema-tested by both the TypeScript producer and Swift `XCTestDriver`, is the sole source for project-relative path, scheme `rishi-mcp`, configuration `Debug`, destination identities, source-package-directory policy, and selector `rishiUITests/MCPControlUITests/testServer`; runtime code may substitute only canonical repo/attempt paths. Hash the contract into environment provenance. After each build, perform metadata-only xctestrun/test-enumeration validation with the same contract and require the exact selector/destination before accepting provenance; do not launch a test or app. Producer and driver golden tests must emit identical contract-controlled argv fields. These producers fail if any output path pre-exists or escapes the attempt root.

After all three builds succeed, a producer atomically writes the immutable static environment file under the attempt root—never from a caller-supplied file—with exactly these attested values: `RISHI_MCP_PROJECT=<clean HEAD==sha repo>/apps/apple/rishi/rishi.xcodeproj`, both attempt-local derived-data paths, and `RISHI_MCP_TEST_WITHOUT_BUILDING=1`. It validates that the project path resolves inside the clean repository, `git -C <project-root> rev-parse HEAD == sha`, and both derived-data paths are the outputs created in this attempt. Only then create:

- `mcp-binary-provenance.json`: `{ version: 1, attemptId, sha, sourceHead, scratchPath, buildStartedAt, buildFinishedAt, absolutePath, sha256, contentHash }`; `sourceHead == sha`, the binary must be inside the fresh attempt scratch path, and both consumers must use it. Tests reject a binary outside that scratch path, a pre-existing scratch path, or a mismatched source head.
- `mcp-environment-provenance.json`: `{ version: 1, attemptId, sha, environmentFilePath, environmentFileSha256, values: { the exact four path/literal values }, projectRoot, projectGitHead, testCommandContractSha256, catalystDerivedDataSha256, iphoneDerivedDataSha256, catalystHandoffValidated: true, iphoneHandoffValidated: true, runtimeKeys: ["RISHI_MCP_ATTEMPT_ID", "RISHI_MCP_PHASE_ID", "RISHI_MCP_RECEIPT_PATH"], contentHash }`. All paths are canonical absolute paths; `projectGitHead == sha`; contract hash and derived-data digests refer to exact attempt outputs; both metadata handoffs are validated. The state machine supplies only `phaseId == "codex"` with `<attempt-root>/launch-receipt-codex.json` or `phaseId == "direct"` with `<attempt-root>/launch-receipt-direct.json`; paths must be absent, canonical, direct children of the attempt root, and match the phase. `codex-mcp-invocation.json` attests the Codex values; the direct client derives and attests the direct values. Registration, both clients, receipts, and verifiers reject any other runtime key/value or override, path escape, hash/contract change, project-head mismatch, unvalidated handoff, or derived-data substitution.
- `codex-mcp-invocation.json`: a non-shell argv/config specification generated only from the preceding binary/environment provenance, containing `attemptId`, their content hashes, canonical executable path/digest, and exact environment keys; the Codex action runner consumes this artifact without accepting replacement binary/environment arguments.

At phase-1 preflight, capture the immutable set of controller MCP PID/executable/start-time identities in memory and a canonical hashed `controller-preflight-snapshot.json`; no later process may enter that set. Immediately before Codex `0/1/0`, the sole allowlist producer asserts `controller-mcp-allowlist.json` absent, revalidates every preflight identity, asserts no unexplained additional MCP host, and writes exactly the same identity set with current SHA/attemptId plus the preflight-snapshot hash. The immutable allowlist is reused by both live phases; immediately before direct `0/1/2/0`, revalidate every identity and fail if either file/hash changed. Codex and direct phases each record one separate provenance-bound release MCP root after spawn and prove it absent after that phase. Tests prove no second producer runs, a mid-attempt host cannot be allowlisted, and an unrecorded release host is rejected.

The release verifier must cross-check all producer hashes/SHAs against both live acceptance phases. Tests must prove stale SHA, substituted binary/path, changed environment file, altered Codex invocation spec, pre-existing producer output, and unexpected MCP process identities are rejected.

- [ ] **Step 2A: Execute one non-interactive release state machine**

`run-shared-reading-release.ts` owns the attempt from start to finish; no external task pauses it or selects an existing attempt root. Its tested state machine is exactly:

1. generate/reject-collision attempt root; verify clean `HEAD == sha`; enforce memory/disk/zero-instance/process preflight;
2. run fresh Swift and two exact-contract Apple build-for-testing producers; validate handoff metadata; generate canonical environment, provenance, and Codex invocation artifacts;
3. execute Task 4 registration plus read-only Codex smoke from those artifacts, then stop its release MCP host and prove zero release hosts/apps;
4. create the sole immutable controller allowlist;
5. execute Codex `0/1/0`, cleanup/revalidate;
6. execute direct `0/1/2/0`, cleanup/revalidate;
7. verify/sign final artifacts and return the attempt ID/root.

Every transition validates the previous phase's outputs and zero-state requirements. Failure enters the identity-bound cleanup path and terminates the attempt; it never resumes from a partial root.

- [ ] **Step 3: Review and commit infrastructure**

Run focused wrapper, acceptance-runner, Codex-action verifier, release-runner, and release-verifier tests. Obtain independent spec and code-quality reviews, fix every Critical/High issue, and commit before any host-capacity snapshot or app launch.

### Task 4: Bind Swift MCP registration to the exact release attempt

**Machine-local configuration:** Codex MCP configuration.

- [ ] **Step 1: Start the exact-SHA release attempt and consume its producer outputs**

This is phase 3 of the single Task 3 state machine, not a separately paused/invoked task. Do not run or register a generic `.build/debug/rishi-apple-mcp`. Consume the in-memory attempt context and persisted outputs after preflight, exact-SHA Swift build, exact-contract Apple build-for-testing plus metadata handoff validation, immutable environment file, binary/environment provenance, and `codex-mcp-invocation.json` all succeed. Verify their hashes, paths, command-contract hash, derived-data digests, and source/project SHA before registration. The only accepted executable and environment are those inside the current attempt's provenance artifacts.

- [ ] **Step 2: Replace the stale Node registration**

`codex mcp get rishi-apple` must no longer show `node` or `src/index.mjs`. Generate the invocation-scoped registration only from the current attempt's `codex-mcp-invocation.json`; it must contain the provenance-bound scratch executable plus these static environment values and the runner-injected attempt/receipt values:

```text
RISHI_MCP_PROJECT=<clean-worktree>/apps/apple/rishi/rishi.xcodeproj
RISHI_MCP_DERIVED_DATA_CATALYST=<verified Catalyst derived data>
RISHI_MCP_DERIVED_DATA_IPHONE17=<verified iPhone derived data>
RISHI_MCP_TEST_WITHOUT_BUILDING=1
```

Set `mcp_servers.rishi-apple.default_tools_approval_mode = "approve"` only for this local test server. Do not initialize unrelated external MCP servers during acceptance.

The release producer has already generated the four static values and immutable environment file from the clean exact-SHA project and attempt-local build outputs. Task 4 must not create, edit, or replace them. Add attempt/receipt runtime values from the same attempt; never source or evaluate the file in a shell. Registration is valid only for that attempt and is removed or replaced after the attempt. Codex registration alone is not evidence that a directly spawned process inherited the same values.

- [ ] **Step 3: Prove a real Codex read-only connection**

Run `codex exec --ignore-user-config` with the generated invocation-scoped configuration containing only `rishi-apple`. Require `list_app_instances` and `memory_snapshot`; the normalized smoke evidence must include and cross-check the attempt ID and binary/environment/invocation provenance hashes.

Expected:

```json
{
  "list_app_instances": [],
  "memory_snapshot": {
    "host": { "availableMemoryBytes": 1, "configuredMinimumMemoryBytes": 8589934592 },
    "matchingProcesses": []
  }
}
```

`availableMemoryBytes` may differ, but must be non-negative and the response must not contain unrelated command lines.

### Task 5: Restore enough host capacity for exactly two app targets

**Files:** none.

- [ ] **Step 1: Inventory without launching**

Run MCP `list_app_instances`, MCP `memory_snapshot`, `df -g /private/tmp`, and a read-only process inventory using PID/PPID/PGID/executable/start-time fields only. Inspect the controller's already-running MCP hosts for the capacity decision, but do not persist the release allowlist here. Assert there is no pre-existing Rishi app, XCTest, xcodebuild, simulator launch, or unexplained `rishi-apple-mcp` process before launch. During the exact-SHA release run, its sole setup producer creates `controller-mcp-allowlist.json` immediately before acceptance with schema `{ version: 1, attemptId, capturedAt, sha, hosts: [{ pid, ppid, pgid, executable, startedAt }], contentHash }`, mode `0600`, and the Task 3 canonical hash/encoding contract; consumers reject stale attemptId/SHA/hash, duplicate identity, PID executable/start-time mismatch, or any command-line field.

- [ ] **Step 2: Close only unnecessary user-approved applications**

Prefer a reboot if closing ordinary applications cannot restore the 8 GiB floor. Never kill system services, lower the floor, or start another simulator. Preserve the existing iPhone 17 Pro simulator and Catalyst account data.

- [ ] **Step 3: Require the launch gate**

Proceed only when:

```text
availableMemoryBytes >= configuredMinimumMemoryBytes
freeDiskBytes >= 21474836480
list_app_instances == []
```

If any condition fails, stop before `start_app` and report the exact measurement.

### Task 6: Run real two-account shared-reading acceptance

**Files/evidence:**
- Use reviewed files from Task 3; no code may change after the Task 5 SHA-bound provenance/allowlist snapshot without regenerating every artifact and rerunning all gates.
- Produce under the fresh attempt root generated and exclusively owned by the release runner: `/private/tmp/rishi-shared-reading-acceptance-<PR_HEAD>-<ATTEMPT_UUID>/`

- [ ] **Step 1: Prove real Codex action control in an isolated 0/1/0 session**

Through an actual isolated `codex exec --ignore-user-config` client launched from the exact generated `codex-mcp-invocation.json` (no independent binary or environment override), require this Catalyst sequence in one MCP session: initial `list_app_instances == []`; `start_app(catalyst)`; immediate `list_app_instances` shows exactly one Catalyst instance; `inspect_app_state`; `select_book(identifier: "library-book-cell#0", action: "open")`; verify reader state; `send_reader_action(action: "close")`; verify library state; `stop_app(catalyst)`; final `list_app_instances == []`. Capture sanitized Codex JSONL to `rishi-codex-action.jsonl`. Implement and test `verify-rishi-codex-action.ts` to require the ordered `instanceCountLedger: [0, 1, 0]`, exact action sequence, reader-then-library observations, final zero, current SHA, canonical binary path/digest, binary-provenance content hash, environment-provenance content hash, Codex-invocation content hash, validated launch-receipt hash, and no secrets/arbitrary command lines. The release verifier cross-checks those fields against producer outputs. If cleanup does not return to zero, stop before full acceptance.

- [ ] **Step 2: Give the deterministic acceptance runner sole ownership of 0/1/2/0**

After the Codex proof has returned to zero instances, run the full MCP acceptance without pre-starting either target. Pass the exact current-attempt binary and environment provenance artifacts; the TypeScript client validates them and resolves the immutable environment file internally—never source it and never accept path/value overrides. The runner itself must assert initial `0`, start Catalyst and assert `1`, start iPhone 17 Pro and assert `2`, and clean up to `0`; abort on a duplicate or third instance:

```bash
RISHI_E2E_BOOK_IDENTIFIER='library-book-cell#0' \
apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh \
  --mcp-binary-provenance '<attempt-root>/mcp-binary-provenance.json' \
  --mcp-client '<repo>/scripts/test-integrity/run-rishi-mcp-acceptance.ts' \
  --mcp-environment-provenance '<attempt-root>/mcp-environment-provenance.json' \
  --controller-mcp-allowlist '<evidence-root>/controller-mcp-allowlist.json' \
  --owner catalyst \
  --participant iphone17 \
  --sync-timeout-ms 120000 \
  --sha '<40-character PR head>' \
  --evidence-root '<release-runner-generated-attempt-root>'
```

Expected visible sequence:

1. Catalyst opens the context menu and chooses `Start Shared Reading`.
2. Catalyst creates exactly one canonical invite.
3. iPhone opens the supported deep link and joins under the second account.
4. The returned owner and participant states have exactly one identical, non-empty stable session ID; both report participant count exactly `2` and capacity exactly `2`. The runner must validate and retain the structured results of both `wait_for_participant` calls rather than ignoring them.
5. A Catalyst page advance changes the owner's progress and then the participant reaches the same newer fingerprint.
6. Catalyst ends for everyone; both targets lose active-session state.
7. Rejoining with the ended token is rejected.

- [ ] **Step 3: Verify cleanup and evidence**

Require:

```text
shared-reading-mcp-evidence.json exists and hashes correctly
shared-reading-apple-e2e-evidence.json has failed == 0
peakInstances == 2
cleanup.zeroInstances == true
cleanup.memoryChecked == true
instanceCountLedger == [0, 1, 2, 0]
sessionInvariant == { matchingNonEmptyIDs: true, ownerCount: 2, ownerCapacity: 2, participantCount: 2, participantCapacity: 2 }
processLifecycle.boundedShutdown == true
processLifecycle.remainingDescendants == []
processLifecycle.remainingReleaseHosts == []
targetCleanup.catalyst == { identityValidated: true, notRunning: true }
targetCleanup.iphone17 == { udid: '<recorded>', bundleId: '<recorded>', notRunning: true }
no invite token or account credential appears in stored evidence
the acceptance-owned POSIX session has no remaining descendants
the final PID/PPID/PGID/executable inventory contains no Rishi/XCTest/xcodebuild process and no non-allowlisted MCP host
```

### Task 7: Review, push, merge, and deploy only proven runtime changes

**Files:**
- Update: `apps/apple/docs/superpowers/plans/2026-09-17-shared-reading-completion.md`
- Update evidence manifest only if commands or required artifacts changed.

- [ ] **Step 1: Run the adversarial review loop**

Use one independent Terra review for spec/security/process ownership and one independent Luna review for tests/runtime evidence. Fix all Critical/High findings and re-review until both return PASS or PASS WITH NOTES with explicitly accepted non-blocking notes.

- [ ] **Step 2: Re-run release gates from the exact final SHA**

Run Swift MCP tests, four iPhone semantic tests, four Catalyst semantic tests, release-integrity tests, and the live two-account acceptance. The release manifest must pass `--mcp-binary-provenance`, `--mcp-environment-provenance`, and `--controller-mcp-allowlist` to the acceptance wrapper and own/hash `rishi-codex-action.jsonl`, its normalized `0/1/0` verifier artifact, all build/provenance artifacts, `controller-mcp-allowlist.json`, and the runner's `0/1/2/0` evidence. GitHub's required checks must pass for the same SHA.

- [ ] **Step 3: Push only reviewed commits**

Before push:

```bash
git diff --check
git status --short
git diff --name-only origin/main...HEAD | rg '^apps/rishi-electron/' && exit 1 || true
```

Do not stage unrelated shared-checkout modifications or untracked screenshots.

- [ ] **Step 4: Merge PR #256**

Merge only if the PR is `CLEAN`, all required checks pass, all live gates pass, and both independent reviews have zero open Critical/High findings. Verify the merge commit is reachable from updated `origin/main`.

- [ ] **Step 5: Deploy only the affected Worker runtime**

If the final PR still changes Worker runtime paths, use Bun for Worker commands and the repository's Wrangler workflow. A deployment is complete only when startup succeeds without Cloudflare error `10021` and the production health/version response identifies the merged revision. If no Worker runtime path changed after the final review, record deployment as not applicable; do not redeploy unrelated services.

## Adversarial plan review

### Round 0 — controller self-review

- **High — unit and semantic tests could be mistaken for live feature proof.** Resolved by making the two-account create/join/synchronize/end sequence a mandatory merge gate with exact observations and evidence files.
- **High — memory pressure could tempt an agent to lower the resource floor or create extra instances.** Resolved by making the 8 GiB/20 GiB thresholds invariants and requiring 0/1/2/0 instance counts.
- **High — the dirty shared checkout could contaminate the branch.** Resolved by requiring clean-worktree execution, exact path staging, and an Electron-path rejection before push.
- **Medium — “deployment” was ambiguous.** Resolved by limiting deployment to Worker runtime paths that remain in the final PR and requiring health/version proof; unrelated services are not redeployed.
- **Medium — a direct protocol client alone would not prove Codex can act on the app.** Resolved by requiring a real isolated `codex exec` open/close action in addition to deterministic full-flow acceptance.
- **Verdict:** PASS for dispatch; zero open Critical/High findings. Independent Terra and Luna review results must be appended as completed rounds before Task 7 can pass.

### Round 1 — independent Terra review

- **High — conflicting app ownership.** The plan pre-started both targets and then invoked a runner that requires zero initial instances and owns launch/cleanup. Resolved by splitting acceptance into an isolated Codex-owned `0/1/0` action proof followed by a deterministic runner-owned `0/1/2/0` full flow; neither phase may begin unless the previous phase ended at zero.
- **High — privacy test did not prove non-enumeration.** An empty result alone could be produced after collecting host command lines. Resolved by requiring the injected runner to record argv and asserting the broad `ps -axo pid=,rss=,command=` invocation is absent when `match == ""`.
- **High — exact roster contract was unasserted.** The runner discarded participant-wait results and accepted counts above one. Resolved by requiring both structured wait results, one identical non-empty session ID, participant count exactly `2`, and capacity exactly `2` on both targets, with regression tests.
- **High — full-suite diagnostic was not actually bounded.** Resolved by requiring a tested 300-second `run-verified.ts --timeout-ms` path that terminates and awaits its owned POSIX session/process group and inventories any survivors without collecting full command lines.
- **High — direct acceptance did not inherit registered MCP environment.** Resolved by recording a non-secret Task 3 environment file and loading it before the direct acceptance wrapper spawns the same reviewed Swift binary.
- **Medium — global stale-process absence was not concretely proven.** Resolved by requiring pre/post PID/PPID/PGID/executable inventories, a controller MCP allowlist, and zero acceptance-owned descendants.
- **Verdict:** FAIL before correction. All five High findings and the Medium finding are addressed in the revised plan contract; a fresh independent re-review is required before implementation of the affected steps.

### Round 2 — independent Terra re-review

- **High — timeout command preceded timeout implementation.** Resolved by making the first Task 2 step a red test plus implementation of strict `--timeout-ms` process-session cleanup, before the bounded Swift reproduction command can run.
- **High — runner and release verifier still encoded only `0/2/0`.** Resolved by adding a required TDD implementation step and exact `instanceCountLedger: [0, 1, 2, 0]` evidence/verifier contract before live acceptance.
- **High — roster responses were still discarded by current code.** Resolved by explicitly owning changes in the runner, its tests, the release verifier, and its tests, with a redacted exact session/roster invariant schema.
- **High — current privacy test lacked invocation capture.** Resolved in Task 1 and implemented locally with an actor-backed argv recorder plus an assertion that broad `ps -axo pid=,rss=,command=` is absent; the focused test passes.
- **Medium — process cleanup lacked an owner and schema.** Resolved by assigning one POSIX-session-owning transport with bounded close/escalation and an explicit `processLifecycle` evidence/verifier schema.
- **Medium — environment-file wording and propagation were ambiguous.** Resolved by specifying the exact four-key grammar, path/value validation, explicit spawn environment, and a fake-spawn unit test.
- **Verdict:** FAIL before this correction. A third fresh independent plan re-review is required; implementation evidence remains separately required before any completion claim.

### Round 3 — independent Terra re-review

- **High — shell evaluation preceded environment validation.** Resolved by forbidding shell sourcing/evaluation and requiring a `--mcp-env-file` TypeScript parser with exact-key/value validation and explicit `Bun.spawn` propagation tests.
- **High — Codex action proof did not observe the middle count.** Resolved by adding an immediate post-start `list_app_instances == [catalyst]`, a dedicated tested JSONL verifier, an exact `0/1/0` ledger, and release-manifest ownership.
- **High — controller MCP allowlist was neither durable nor consumed.** Resolved by defining a hashed SHA-bound process-identity artifact, passing it to acceptance, revalidating identities, recording its hash in lifecycle evidence, and requiring verifier tests for allowed and unexpected hosts.
- **Medium — no-orphan command treated no match as failure.** Resolved by expressing it as an explicit inverse assertion whose zero exit means no orphan was found.
- **Verdict:** FAIL before this correction. A fourth fresh independent plan re-review is required; implementation and live evidence remain separate gates.

### Round 4 — independent Terra re-review

- **High — SHA-bound allowlist was captured before later implementation commits.** Resolved by moving all non-GUI acceptance infrastructure into Task 3, requiring its review/commit before Task 4 binary provenance and Task 5 process identity capture, and invalidating/regenerating all artifacts after any subsequent code change.
- **High — shell wrapper did not own or forward new arguments.** Resolved by making the wrapper an explicit Task 3 modified file with a dedicated exact-argv/no-file-evaluation test.
- **High — binary and environment provenance were not release-owned outputs.** Resolved by assigning release-run producer steps that start with absent files, atomically create SHA-bound hashed binary/environment/allowlist artifacts during the exact-SHA run, and are cross-checked by acceptance and release verifiers.
- **Verdict:** FAIL before this correction. A fifth fresh independent plan re-review is required; implementation and live evidence remain separate gates.

### Round 5 — independent Terra re-review

- **High — two producers claimed the same controller allowlist path.** Resolved by making Task 5 preflight read-only and the exact-SHA release setup immediately before acceptance the sole producer; pre-existing output is rejected.
- **High — Codex action proof was not cryptographically tied to binary/environment provenance.** Resolved by generating a non-shell Codex invocation artifact from the producer outputs, removing independent overrides, recording canonical binary/digest and all provenance hashes in the normalized `0/1/0` artifact, and cross-checking them in the release verifier.
- **Verdict:** FAIL before this correction. A sixth fresh independent plan re-review is required; implementation and live evidence remain separate gates.

### Round 6 — independent Terra re-review

- **High — final rerun reused an evidence root whose outputs must be absent.** Resolved by assigning every release run a fresh UUID attempt ID and unique evidence root, binding that ID into every artifact/hash, never reusing roots, and designating one fully passing final attempt.
- **High — provenance hash domain and serialization were undefined.** Resolved by specifying exact canonical UTF-8 JSON bytes, top-level `contentHash` exclusion for the hash payload, trailing-LF serialization, duplicate-key rejection, and tests for payload/digest/encoding/order tampering.
- **Verdict:** FAIL before this correction. A seventh fresh independent plan re-review is required; implementation and live evidence remain separate gates.

### Round 7 — independent Terra re-review

- **High — allowlist production timing was ambiguous across two phases.** Resolved by creating it exactly once immediately before Codex `0/1/0`, reusing it immutably, and revalidating identities/hash immediately before direct `0/1/2/0`; tests forbid a second producer.
- **High — stalled RPC/phase could bypass cleanup.** Resolved by mandatory per-RPC and whole-phase deadlines whose `finally` path performs bounded stop attempts, owned-session TERM/KILL, and zero-app/zero-descendant proof, with stalled-call tests.
- **High — caller could reuse a pre-existing empty attempt root.** Resolved by making the release runner generate the UUID/path itself and reject any pre-existing path before creation, with deterministic collision tests.
- **High — ordinary normalized test artifacts were accidentally pulled into the canonical evidence contract.** Resolved by limiting canonical signed encoding to security/provenance/live/final-manifest artifacts and binding exact normalized bytes transitively through signed SHA-256 manifest entries.
- **High — binary digest did not prove an in-attempt build.** Resolved by requiring a clean exact-SHA worktree and absent attempt-local Swift scratch path, building there as the first producer, and rejecting binaries outside that path or source-head mismatches.
- **Verdict:** FAIL before this correction. An eighth fresh independent plan re-review is required; implementation and live evidence remain separate gates.

### Round 8 — independent Terra re-review

- **Medium — target apps could outlive a dead MCP transport.** Resolved by recording attempt-owned target identities at launch and specifying a bounded out-of-band reaper that revalidates exact Catalyst process identity or exact iPhone UDID/bundle ID, refuses mismatches, preserves unrelated apps, and proves zero attempt-owned targets after failure.
- **Medium — release MCP roots were incorrectly treated as pre-existing controller hosts.** Resolved by restricting the immutable allowlist to pre-attempt controllers and separately recording exactly one provenance-bound release MCP root per phase, allowed only during that phase and required absent afterward.
- **Verdict:** FAIL before this correction despite zero Critical/High findings because cleanup ownership remained ambiguous. A ninth fresh independent plan re-review is required.

### Round 9 — independent Terra re-review

- **High — target identity required by cleanup was not producible by owned Swift files.** Resolved by assigning `AppTools`, `InstanceRegistry`, optional driver changes, and their tests to Task 3, with structured target identities.
- **High — dropped `start_app` response could orphan an unrecorded target.** Resolved by requiring an atomic canonical mode-`0600` server-side per-attempt launch receipt written before response, validated and consumed by the reaper, with dropped-response/tampering tests.
- **High — direct acceptance still allowed a generic binary.** Resolved by replacing it with `--mcp-binary-provenance`; the wrapper/client resolve and verify the exact attempt-scratch path/digest and reject overrides.
- **Medium — simulator cleanup lacked target-specific evidence.** Resolved by adding explicit validated Catalyst absence and recorded iPhone `{ udid, bundleId, notRunning }` evidence required by the release verifier.
- **Verdict:** FAIL before this correction. A tenth fresh independent plan re-review is required.

### Round 10 — independent Terra re-review

- **High — standalone Task 4 registration could use a generic build outside provenance.** Resolved by making Task 4 start/consume the exact-SHA release attempt and generated Codex invocation; generic `.build` binaries are forbidden and smoke evidence cross-checks all attempt provenance hashes.
- **High — dropped iPhone response could leave xcodebuild/XCTest groups alive.** Resolved by recording all owned target PID/PGID/executable/start-time identities before response and authorizing the reaper to TERM/KILL only revalidated positive non-controller groups before exact simulator-bundle termination; final evidence requires every recorded identity absent.
- **Verdict:** FAIL before this correction. An eleventh fresh independent plan re-review is required.

### Round 11 — independent Terra re-review

- **High — environment provenance was produced before its environment file existed.** Resolved by making the release runner first perform preflight, exact-SHA Swift and two-destination Apple build-for-testing producers, then atomically generate the immutable four-value environment file, and only then create provenance; Task 4 is consumption-only.
- **High — environment provenance omitted attested values/project identity.** Resolved by including canonical values and paths, project root/head, attempt-local derived-data digests, rejecting overrides/substitutions, and replacing caller-supplied env-file input with `--mcp-environment-provenance`.
- **Verdict:** FAIL before this correction. A twelfth fresh independent plan re-review is required.

### Round 12 — independent Terra re-review

- **High — no handoff existed between producers, registration smoke, allowlist, and acceptance.** Resolved by defining one non-interactive release-runner state machine with seven explicit transitions, zero-state validation between phases, and no pause/resume or external attempt-root selection.
- **Medium — build-for-testing could differ from the Swift driver's test-without-building contract.** Resolved by a shared checked-in hash-bound test command contract consumed by TypeScript and Swift, golden argv tests, and per-target metadata-only handoff validation before provenance is accepted.
- **Verdict:** FAIL before this correction. A thirteenth fresh independent plan re-review is required.

### Round 13 — independent Terra re-review

- **High — execution map split a state machine that cannot pause.** Resolved by assigning Tasks 3–4 implementation to one implementer and the entire Tasks 4–6 live state-machine invocation to one controller.
- **High — post-smoke discovery could admit a mid-attempt MCP host to the controller allowlist.** Resolved by capturing a canonical controller identity snapshot at phase-1 preflight and allowing the phase-4 producer only to revalidate/write that exact set; tests reject additions.
- **High — one server-bound receipt could not span two different release MCP roots.** Resolved by phase-scoped absent receipt paths, prior-phase terminal-state verification, immutable succession, and preservation of both receipt hashes in the final manifest.
- **Verdict:** FAIL before this correction. A fourteenth fresh independent plan re-review is required.

### Round 14 — independent Terra re-review

- **High — receipt runtime keys conflicted with provenance.** Resolved by one canonical runtime-key set (`ATTEMPT_ID`, `PHASE_ID`, `RECEIPT_PATH`), exact phase/path derivation under the attempt root, Codex/direct attestation, and rejection of every other key/value or override.
- **Verdict:** FAIL before this correction. A fifteenth fresh independent plan re-review is required.

### Round 15 — independent Terra re-review

- No findings. The canonical runtime-key set, exact phase-specific receipt derivation, provenance attestation, prior-phase terminal verification, and complete state-machine ordering are coherent.
- **Verdict:** PASS with zero open Critical/High or execution-blocking Medium findings.
