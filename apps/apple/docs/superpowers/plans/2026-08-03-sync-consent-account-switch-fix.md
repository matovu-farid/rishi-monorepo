# Apple Sync Consent and Account-Switch Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure Apple sync never starts before the signed-in account grants data-use consent, reliably retries after consent, refreshes the visible library after any completed sync, and cannot cross account boundaries during sign-out/sign-in.

**Architecture:** Consent is an explicit state prerequisite at the signed-in shell, while the sync engine keeps its existing fail-closed consent guard as a defense for background and manual entry points. The mounted library observes sync completion through `SyncStatus` and refreshes its user-scoped view model. `SyncEngine` tracks active waves and makes account-switch reset wait for them to finish before auth state changes; inbound application also verifies the exact wave account.

**Tech Stack:** Swift 6, SwiftUI Observation, Swift Testing, existing `RishiSync`, `RishiDB`, `RishiSettings`, and Apple app target.

---

## Files and responsibilities

| File | Responsibility in this change |
|---|---|
| `apps/apple/rishi/rishi/Views/SignedInView.swift` | Resolve consent state before enabling initial library sync; rerun the bootstrap when consent is granted. |
| `apps/apple/rishi/rishi/Library/LibraryTabView.swift` | Gate initial sync on consent and refresh the mounted library after a sync wave completes. |
| `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift` | Start a sync only after the Settings consent grant has been persisted. |
| `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift` | Publish a consent-blocked status, track active waves, and wait for active work during account reset. |
| `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/ChangeApplier.swift` | Reject inbound changes when the wave’s account is no longer the current account. |
| `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/ChatInboundMerger.swift` | Keep direct conversation/message store writes inside the same active-wave account barrier. |
| `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/OutboundDrainer.swift` | Check the wave account before draining outbound records. |
| `apps/apple/rishi/rishi/ServiceGraphFactory.swift` | Supply the current-user provider to the sync engine and inbound/outbound collaborators. |
| `apps/apple/rishi/rishiTests/SignedInViewModelTests.swift` | Verify bootstrap does not run before consent and runs after consent becomes available. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/SyncEngineTests.swift` | Verify consent blocking, active-wave account reset waiting, and exact-account inbound protection. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/ChangeApplierConflictTests.swift` | Verify an inbound change is rejected when the expected account differs from the active account. |
| `apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests.swift` | Verify Settings grants consent before invoking the sync callback. |

## Implementation order

### Task 1: Consent-gated initial sync and consent-triggered retry

**Files:**
- Modify: `apps/apple/rishi/rishi/Views/SignedInView.swift`
- Modify: `apps/apple/rishi/rishi/Library/LibraryTabView.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift`
- Test: `apps/apple/rishi/rishiTests/SignedInViewModelTests.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests.swift`

- [ ] **Step 1: Add the failing signed-in bootstrap test.**

Extend the existing `SignedInViewModelTests` with a consent-gate test whose sync closure records calls but whose consent state starts false. Assert that the initial bootstrap does not call sync while consent is false, then set consent true and invoke the bootstrap trigger again; assert the order is `refresh`, `sync`, `refresh` only after consent.

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/SignedInViewModelTests
```

Expected: the new test fails because `performInitialLibrarySync` currently has no consent input.

- [ ] **Step 2: Add the failing Settings consent-order test.**

Extract the consent-grant sequence used by `SettingsScreen` into a small internal async helper (set current user → grant → verify current consent → invoke the sync callback). Test that helper with `InMemoryDataUseConsentStore` and an event recorder, asserting the callback observes `isCurrent == true` and that no callback event occurs before the grant event. The view’s Allow action must call this helper.

Run the focused Settings test target and confirm the new assertion fails because the current Allow handler only records consent and closes the sheet.

- [ ] **Step 3: Implement the minimum consent gate.**

In `SignedInContent`, add an observable state flag initialized to `false`. In the existing `.task(id: user.id)`:

```swift
await dependencies.dataUseConsentStore.setCurrentUser(user.id.uuidString)
dataUseConsentGranted = await dependencies.dataUseConsentStore.isCurrent(for: user.id.uuidString)
showDataUseConsent = !dataUseConsentGranted
```

Set `dataUseConsentGranted = true` only after the signed-in consent sheet has completed `setCurrentUser` and `grant`. Pass the flag to `LibraryTabView`.

Change the library bootstrap task to use an ID containing both the user ID and consent flag, and return before calling `performInitialLibrarySync` when the flag is false:

```swift
.task(id: "\(user.id.uuidString)-\(dataUseConsentGranted)") {
    guard dataUseConsentGranted else { return }
    await model.performInitialLibrarySync(
        refresh: { await vm.refresh() },
        sync: {
            if dependencies.readerDefaults.autoSync {
                _ = await dependencies.syncEngine.runOnce()
            }
        }
    )
}
```

In `SettingsScreen`’s `onAllow` handler, await `setCurrentUser` and `grant`, update the local consent state, close the sheet, and invoke `onSyncNow()` only after the grant returns. This covers Settings-based consent recovery without bypassing the engine’s consent guard.

- [ ] **Step 4: Run the focused Apple tests.**

Run `SignedInViewModelTests`, Settings consent tests, and the existing sync-status tests. Expected: all pass, with no sync callback observed before consent.

### Task 2: Refresh the visible library after manual, background, or menu sync

**Files:**
- Modify: `apps/apple/rishi/rishi/Library/LibraryTabView.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/ViewModel/LibraryViewModelRefreshTests.swift`

- [ ] **Step 1: Add a failing completion-refresh test.**

Drive a `SyncStatus` transition from `isRunning == true` to `false` after changing the backing `BookStore` to contain a book. Assert the mounted library refresh callback is invoked and the new book becomes visible. The test must exercise the status transition, not just call `LibraryViewModel.refresh()` directly.

- [ ] **Step 2: Implement completion-driven refresh.**

Add an `onChange(of: dependencies.settings.syncStatus.isRunning)` handler to `LibraryTabView` that refreshes only on the `true -> false` transition. The existing focused test file is `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/ViewModel/LibraryViewModelRefreshTests.swift`; add a small completion-observer seam to the view model or status bridge so the test can drive the transition without relying on a UI inspection framework:

```swift
.onChange(of: dependencies.settings.syncStatus.isRunning) { wasRunning, isRunning in
    guard wasRunning, !isRunning else { return }
    Task { await vm.refresh() }
}
```

This covers iOS Settings, Catalyst’s Sync menu, BGTask, silent-push, and sign-in-triggered waves without coupling `SyncEngine` to a view model.

- [ ] **Step 3: Verify refresh behavior and avoid duplicate initial work.**

Run the focused library tests and confirm the initial `refresh → sync → refresh` remains valid while a completed wave causes exactly one additional refresh.

### Task 3: Make account switching wait for active sync work and enforce the wave account

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/ChangeApplier.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/OutboundDrainer.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/ChatInboundMerger.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/SyncEngineTests.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/ChangeApplierConflictTests.swift`

- [ ] **Step 1: Add a failing active-wave reset test.**

Use the existing sync-engine test stubs to hold the remote fetch open. Start `runOnce()` for account A, call `resetForAccountSwitch()`, and assert reset does not complete until the held fetch is released. After release, assert the old wave cannot drain outbound work and the metadata store is reset.

- [ ] **Step 2: Add a failing exact-account inbound test.**

Call `ChangeApplier.apply(_:expectedUserId:)` with an expected account A while the injected current-user provider returns account B. Assert no book/position/highlight store is mutated and the result contains an account-switch error.

- [ ] **Step 3: Implement the active-wave barrier.**

Add `activeWaveCount` to `SyncEngine`. Increment it and capture the current user/generation before the first suspension in `runOnce()`, and decrement it in a `defer` that covers every early return (including the consent-blocked path). `resetForAccountSwitch()` must increment `accountGeneration`, cancel debounced positions, then yield until `activeWaveCount == 0` before clearing the queue and metadata. Because sign-out calls this before clearing `userIdBox` and Keychain, in-flight A work completes while A is still the active identity; B cannot begin until old work has exited. Add a test for a wave suspended in each inbound collaborator, not only the primary book fetch, so the barrier covers the direct chat store writes too.

- [ ] **Step 4: Implement exact-account guards.**

Add a current-user provider to `SyncEngine.Dependencies`, pass it from `ServiceGraphFactory`, and capture the wave user ID at the beginning of `runOnce()`.

Extend `ChangeApplier.apply` with an optional `expectedUserId` parameter. When supplied, require both `accountIsActive()` and `currentUserId() == expectedUserId` before each change, after any awaited book materialization, and immediately before each local store mutation. Return an account-switch error without marking the change clean when the check fails.

Extend `OutboundDrainer.drain` with the same expected-user check before each dequeued item. Stop and re-enqueue remaining items if the current user no longer matches. `SyncEngine` must refuse to enter the drain when the generation or current-user check fails.

Pass the expected wave user into `ChatInboundMerger.merge` and check it before each conversation/message fetch result is upserted and before each metadata mark-clean. If the account changes, return an account-switch error and leave the remaining rows retryable. The active-wave barrier is the primary protection; these checks are the defense against any future caller that violates the sign-out ordering.

- [ ] **Step 5: Run focused sync tests and inspect all callers.**

Run `SyncEngineTests`, `ChangeApplierConflictTests`, `SyncQueueTests`, and `SyncMetadataStoreTests`. Search for every `ChangeApplier.apply`, `OutboundDrainer.drain`, and `SyncEngine.Dependencies` construction to ensure test defaults preserve existing behavior while production passes the account provider.

### Task 4: Surface consent-blocked status without performing network sync

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/SyncEngineTests.swift`

- [ ] **Step 1: Add a failing consent-blocked status test.**

Inject a consent provider returning false, invoke `runOnce()`, and assert no fetch request occurs and `SyncStatus.lastError` says consent is required.

- [ ] **Step 2: Implement the fail-closed status update.**

Keep the consent guard as the first operation in `runOnce()`. When it returns false, call `statusReporter.snapshotStatus(error: "Sync requires data-use consent", on: status)` and return an empty wave. Do not set `isRunning`, refresh the queue, call the Worker, or drain outbound work.

- [ ] **Step 3: Run all focused sync tests.**

Expected: the consent test passes, and existing AlwaysAllow tests remain unchanged.

### Task 5: Final verification and review

- [ ] Run the focused Apple sync, settings, library, and auth tests.
- [ ] Run an Apple build for the touched app target.
- [ ] Review the final diff for every sync entry point: sign-in bootstrap, Settings Sync Now, Catalyst Sync Now, BGTask, silent push, import-triggered sync, and account deletion/sign-out. Confirm every path reaches the same actor-level consent guard and that sign-out awaits `resetForAccountSwitch()` before clearing the current identity.
- [ ] Run an independent adversarial implementation review. Fix and re-review every Critical or High finding before completion.

## Consumer / call-site audit

| Behavior | Consumers |
|---|---|
| Consent-gated initial sync | `SignedInContent`, `LibraryTabView`, Settings consent sheet |
| Completed-wave library refresh | `LibraryTabView` status observer; all engine triggers share `SyncStatus` |
| Account reset barrier | `AppDependencies.performSignOut`, account deletion purge, `SyncEngine.resetForAccountSwitch` |
| Exact account inbound guard | `SyncEngine`, `ChangeApplier`, all inbound store mutations |
| Exact account outbound guard | `SyncEngine`, `OutboundDrainer`, `BookUploader`/position/highlight/bookmark uploaders |
| Consent-blocked status | Settings Sync section, Catalyst Sync menu, background/silent-push diagnostics |

## Explicitly out of scope

- Electron’s separate legacy sync protocol and database model; the supplied reproduction screenshots are Apple iOS/Mac Catalyst and the requested fix targets that shared Apple sync engine.
- Changing the Worker’s authenticated user scoping or R2 schema; the investigation found those routes correctly user-scoped for the Apple client.
- Deleting ordinary users’ local books on sign-out; local book rows remain intentionally account-filtered so A can reappear when A signs back in.
- Reworking the stale historical documentation that describes Apple IDs as non-UUID strings; the active Worker currently returns UUID-backed user IDs and this is not the reported failure path.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | Gating only the initial task would leave Settings, BGTask, silent push, and import-triggered paths able to call sync before consent. | Task 4 preserves an engine-level fail-closed guard; Task 1 makes the UI bootstrap wait for consent; all entry points are listed in the call-site audit. |
| 2 | High | Resetting `accountGeneration` without waiting lets an in-flight wave apply account A work after account B signs in. | Task 3 adds an active-wave barrier and requires sign-out to finish reset before clearing A’s identity. |
| 3 | High | Refreshing only the iOS Settings callback would leave Catalyst menu and background sync with stale UI. | Task 2 observes shared `SyncStatus` completion in `LibraryTabView`, covering every trigger. |
| 4 | High | A status guard alone could still mark consent-blocked sync as successful or drain queued records. | Task 4 explicitly asserts no fetch, no queue refresh, no running state, and no outbound drain. |
| 5 | High | Exact-account validation could break existing test collaborators and miss a caller. | Task 3 requires optional/default-compatible APIs plus a repository-wide caller audit. |

**Round 1 result:** Re-review required; the plan now contains concrete resolutions for all blocking findings.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The initial plan did not state what happens when consent is granted from Settings after the shell’s initial consent task already completed. | Task 1 makes Settings invoke the sync callback only after the persisted grant; Task 2 refreshes the library after that wave. |
| 2 | Medium | A wave could be account-safe but still leave old queued records after reset. | Task 3 orders generation increment, active-wave drain, then queue and metadata reset, and requires remaining outbound items to be re-enqueued on identity mismatch. |
| 3 | Medium | A consent-blocked background attempt could be invisible in diagnostics. | Task 4 records a user-visible sync status error without making a network request. |

**Round 2 result:** PASS — 0 open Critical/High findings. Medium findings are resolved in the plan; implementation review remains required.

### Round 3 — Cold re-review after plan tightening

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The first version named `ChangeApplier` and the outbound drainer but did not account for `ChatInboundMerger`, which writes conversations/messages directly from the engine. | Added `ChatInboundMerger.swift` to the owned files and requires expected-user checks around every direct chat upsert and metadata mutation. |
| 2 | High | A barrier that only counted waves after the consent await could miss a run that interleaves with account reset before its first suspension. | The plan now requires incrementing the active-wave count and capturing generation/user before the first suspension, including the consent-blocked early-return path. |
| 3 | Medium | The Settings and library tests were underspecified and could devolve into UI-framework-dependent smoke tests. | The plan now requires a testable consent-grant helper and names the existing `LibraryViewModelRefreshTests.swift` file plus a status/completion seam. |
| 4 | Medium | Final entry-point review did not explicitly verify that sign-out awaits the reset before clearing identity. | Added this ordering assertion to the final audit. |

**Round 3 result:** PASS — 0 open Critical/High findings. The plan is implementation-ready; implementation review remains required.

### Implementation review — Round 1

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | An outbound identity mismatch inside the book bucket could re-enqueue only the current book and then lose later buckets. | The drainer now re-enqueues the current and all remaining buckets before returning the account-switch error. |
| 2 | High | Waiting for active waves without a reset gate would allow a new wave to start between the wait and queue/metadata clearing. | `resetInProgress` blocks new waves and coalesces concurrent reset callers; cleanup happens before the gate is released. |
| 3 | High | A cancelled position-debouncer task could commit after reset and repopulate the cleared queue. | Position commits capture the account generation and abort before enqueueing when reset has started or generation changed. |
| 4 | Medium | The first test patch referred to production seams that did not exist yet and one helper test was not directly callable. | Added the consent helper, completion-observer seam, and compatible consent-gated bootstrap overload; corrected the test factory wiring. |

**Round 1 result:** Re-review required; all Critical/High findings were fixed in the working tree.

### Implementation review — Round 2

Re-checked the complete production diff and all changed regression tests for consent ordering, shared status completion refresh, reset reentrancy, exact-account checks, queue re-enqueue behavior, and Swift syntax. No remaining Critical/High issue was found. `swiftc -frontend -parse` and `git diff --check` pass.

**Round 2 result:** PASS — 0 open Critical/High findings.

### Final verification audit

- The escalated Xcode app build completed successfully using the local package cache (`** BUILD SUCCEEDED **`), compiling the changed sync, settings, library, and signed-in view sources.
- The focused test invocation compiled the changed test files but the shared `rishiTests` target could not finish compiling because unrelated existing RishiVoice/realtime and ParagraphChunker tests fail to compile. Test execution was cancelled by those unrelated target errors; no changed-file compiler error was reported.
- The current worktree passes `git diff --check` and Swift frontend parsing for all changed Swift files.

## Status

> **Status:** Plan and implementation adversarial review loops complete — **PASS** (plan: 3 rounds; implementation: 2 rounds; 0 open Critical/High findings)
