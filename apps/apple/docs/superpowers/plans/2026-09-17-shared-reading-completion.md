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
| 4 | Luna, registration operator | Task 3 only; machine-local Swift MCP registration and isolated Codex smoke | Registration identity, binary digest, concise transcript evidence |
| 5 | Terra, live-run controller | Tasks 4 and 5; resource gate and exact two-account flow | 0/1/2/0 instance ledger, evidence paths, failure details if any |
| 6 | Luna, final evidence auditor | Task 6 release artifacts and process cleanup, read-only | Requirement-by-requirement completion matrix |
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

The test must feed a fake host process command containing a secret-like argument and require an empty process array for `snapshot(match: "")`:

```swift
let result = try await snapshot.snapshot(match: "")
XCTAssertEqual(result["matchingProcesses"]?.arrayValue, [])
```

- [ ] **Step 2: Verify the test fails without the implementation**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1 \
  --filter MemorySnapshotTests.testUnfilteredSnapshotDoesNotExposeHostProcessCommands
```

Expected before the fix: failure showing the fake `/usr/bin/example --secret-value` process in `matchingProcesses`.

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

- [ ] **Step 1: Reproduce from a clean worktree with a hard outer bound**

Run the full suite once while recording elapsed time and process descendants:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1
```

Expected current failure: the test process remains sleeping beyond five minutes with no completion output. Do not repeatedly launch it.

- [ ] **Step 2: Find the order-dependent pair**

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

- [ ] **Step 3: Fix lifecycle ownership, not the timeout value**

The fix must ensure every `ManagedProcess` monitor, pipe reader, continuation, timeout task, child process, and process group reaches one terminal state. Do not increase sleeps or weaken cleanup assertions.

- [ ] **Step 4: Prove one-process suite completion and no orphans**

Run:

```bash
swift test --package-path apps/apple/rishi-mcp --jobs 1
pgrep -fl 'RishiAppleMCPTests|rishi-apple-mcp|xcodebuild|rishiUITests|rishi.app'
```

Expected: all tests pass in one invocation; `pgrep` prints nothing after completion.

- [ ] **Step 5: Review and commit**

Require spec review, code-quality review, and re-review after fixes. Commit only the proven lifecycle files and tests.

### Task 3: Make Swift MCP registration durable and isolated

**Machine-local configuration:** Codex MCP configuration.

- [ ] **Step 1: Build the exact PR-head binary**

From a clean worktree at the current PR head:

```bash
swift build --package-path apps/apple/rishi-mcp --jobs 1
shasum -a 256 apps/apple/rishi-mcp/.build/debug/rishi-apple-mcp
```

Record the absolute executable path, commit SHA, and binary digest in the acceptance evidence directory.

- [ ] **Step 2: Replace the stale Node registration**

`codex mcp get rishi-apple` must no longer show `node` or `src/index.mjs`. Register the Swift executable and these environment values:

```text
RISHI_MCP_PROJECT=<clean-worktree>/apps/apple/rishi/rishi.xcodeproj
RISHI_MCP_DERIVED_DATA_CATALYST=<verified Catalyst derived data>
RISHI_MCP_DERIVED_DATA_IPHONE17=<verified iPhone derived data>
RISHI_MCP_TEST_WITHOUT_BUILDING=1
```

Set `mcp_servers.rishi-apple.default_tools_approval_mode = "approve"` only for this local test server. Do not initialize unrelated external MCP servers during acceptance.

- [ ] **Step 3: Prove a real Codex read-only connection**

Run `codex exec --ignore-user-config` with invocation-scoped configuration containing only `rishi-apple`. Require `list_app_instances` and `memory_snapshot`.

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

### Task 4: Restore enough host capacity for exactly two app targets

**Files:** none.

- [ ] **Step 1: Inventory without launching**

Run MCP `list_app_instances`, MCP `memory_snapshot`, `df -g /private/tmp`, and a read-only top-RSS process inventory.

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

### Task 5: Run real two-account shared-reading acceptance

**Files/evidence:**
- Use: `apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh`
- Use: `scripts/test-integrity/run-rishi-mcp-acceptance.ts`
- Produce under: `/private/tmp/rishi-shared-reading-acceptance-<PR_HEAD>/`

- [ ] **Step 1: Start exactly two MCP-owned targets**

Call `start_app(catalyst)`, then `start_app(iphone17)`, sequentially. After each call, assert instance counts `1` then `2`; abort if a third instance or a duplicate appears.

- [ ] **Step 2: Prove basic Codex action control**

Through an actual isolated `codex exec` client, call `inspect_app_state(catalyst)`, `select_book(catalyst, identifier: "library-book-cell#0", action: "open")`, `send_reader_action(catalyst, action: "close")`, and inspect again.

Expected: reader state becomes visible, then the library returns. This is the required proof that Codex can perform app actions, not merely list tools.

- [ ] **Step 3: Create and join the reading session**

Run the full MCP acceptance with:

```bash
RISHI_E2E_BOOK_IDENTIFIER='library-book-cell#0' \
apps/apple/rishi-mcp/Scripts/run-shared-reading-acceptance.sh \
  --mcp-binary '<absolute Swift binary>' \
  --mcp-client '<repo>/scripts/test-integrity/run-rishi-mcp-acceptance.ts' \
  --owner catalyst \
  --participant iphone17 \
  --sync-timeout-ms 120000 \
  --sha '<40-character PR head>' \
  --evidence-root '/private/tmp/rishi-shared-reading-acceptance-<PR_HEAD>'
```

Expected visible sequence:

1. Catalyst opens the context menu and chooses `Start Shared Reading`.
2. Catalyst creates exactly one canonical invite.
3. iPhone opens the supported deep link and joins under the second account.
4. Both targets expose the same stable session ID and roster `2/2`.
5. A Catalyst page advance changes the owner's progress and then the participant reaches the same newer fingerprint.
6. Catalyst ends for everyone; both targets lose active-session state.
7. Rejoining with the ended token is rejected.

- [ ] **Step 4: Verify cleanup and evidence**

Require:

```text
shared-reading-mcp-evidence.json exists and hashes correctly
shared-reading-apple-e2e-evidence.json has failed == 0
peakInstances == 2
cleanup.zeroInstances == true
cleanup.memoryChecked == true
no invite token or account credential appears in stored evidence
no Rishi/XCTest/xcodebuild/MCP descendant remains
```

### Task 6: Review, push, merge, and deploy only proven runtime changes

**Files:**
- Update: `apps/apple/docs/superpowers/plans/2026-09-17-shared-reading-completion.md`
- Update evidence manifest only if commands or required artifacts changed.

- [ ] **Step 1: Run the adversarial review loop**

Use one independent Terra review for spec/security/process ownership and one independent Luna review for tests/runtime evidence. Fix all Critical/High findings and re-review until both return PASS or PASS WITH NOTES with explicitly accepted non-blocking notes.

- [ ] **Step 2: Re-run release gates from the exact final SHA**

Run Swift MCP tests, four iPhone semantic tests, four Catalyst semantic tests, release-integrity tests, and the live two-account acceptance. GitHub's required checks must pass for the same SHA.

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
- **Verdict:** PASS for dispatch; zero open Critical/High findings. Independent Terra and Luna review results must be appended as completed rounds before Task 6 can pass.
