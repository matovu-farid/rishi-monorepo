# Apple Book Import Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make imported books appear without waiting for a full network sync, while preserving sync correctness and reducing avoidable post-import serialization.

**Architecture:** Local import remains ordered where data dependencies require it, but the production import callback only marks books dirty and requests a coalesced background sync. `SyncEngine` gains single-flight protection so direct callers share one active wave rather than overlapping network/database work. Library refresh starts independent position and cover resolution together; prewarming starts independently of sync.

**Tech Stack:** Swift 6 concurrency, Swift actors/tasks, SwiftData-backed sync, Swift Testing, Xcode/iOS and Catalyst targets.

---

## Scope and invariants

- Import completion must not await network fetch, upload, projection verification, or remote sync.
- Every imported book must still be marked dirty and eventually observed by a sync request.
- Concurrent sync callers must share one active wave. A request arriving during a wave must cause one follow-up wave, not an overlapping wave.
- Search indexing, chapter indexing, and EPUB/PDF prewarming remain background work and must not become import blockers.
- Do not parallelize arbitrary book imports yet: deterministic IDs can map different source files to the same directory, and `BookFileStorage` does not serialize filesystem collisions. Any future batch parallelism needs per-book identity coordination.
- Existing direct `runOnce()` callers (background task, silent push, foreground refresh, manual sync) retain their awaitable semantics.

## Files

- Modify `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift` to add a single-flight `runOnce()` wrapper and a non-blocking coalesced `requestSync()` entry point.
- Modify `apps/apple/rishi/rishi/ServiceGraphFactory.swift` so the shared callback used by picker imports, `SampleBookInstaller`, and `SampleReaderInstaller` marks dirty, requests sync, and launches prewarm without awaiting the network.
- Modify `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryViewModel.swift` so independent position and cover fan-outs begin together.
- Test `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/SyncEngineTests.swift` for single-flight and queued-follow-up behavior.
- Test `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/ViewModel/LibraryViewModelRefreshTests.swift` for concurrent position/cover refresh work.
- Add no new migration or database schema work; this change uses existing sync metadata and book stores.

### Task 1: Lock down single-flight sync behavior

**Files:**

- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiSync/RishiSyncTests/SyncEngineTests.swift`

- [x] **Step 1: Add a failing test for concurrent `runOnce()` calls.**

Add a test using the existing `EngineMockURLProtocol`, with the `/api/sync/changes` response blocked by a semaphore. Start one `engine.runOnce()` task, wait until its request is captured, start a second `engine.runOnce()` task, and assert that only one `/api/sync/changes` request exists before releasing the gate. Await both tasks after releasing the gate.

Expected pre-change result: FAIL because actor reentrancy permits the second `runOnce()` to start another wave while the first is suspended in network I/O.

- [x] **Step 2: Add a failing test for non-blocking `requestSync()` and a follow-up request.**

Add a test that starts a gated `runOnce()` wave, calls `await engine.requestSync()` while that wave is active, releases the gate, and verifies the queued request runs only after the first wave completes. Assert that the captured `/api/sync/changes` sequence never has two active waves and that the follow-up is not dropped.

Expected pre-change result: FAIL because `requestSync()` does not exist.

- [x] **Step 3: Run only the sync engine tests and verify the failures are behavioral.**

Run from `/Users/faridmatovu/projects/rishi-monorepo`:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/SyncEngineTests
```

Expected: the two new tests fail for the intended missing/single-flight behavior; existing sync tests continue to compile and run.

### Task 2: Implement single-flight and coalesced background sync

**Files:**

- Modify: `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift`

- [x] **Step 1: Rename the current full-wave body to `performRunOnce()`.**

Keep the existing wave implementation unchanged except for its name. It remains the only function that increments `activeWaveCount`, performs network work, applies changes, drains outbound work, verifies the projection, and updates sync status.

- [x] **Step 2: Add an actor-owned active-wave task.**

Add:

```swift
private var activeWaveTask: Task<Wave, Never>?
private var scheduledSyncTask: Task<Void, Never>?
private var syncRequestPending = false
private var activeWaveWaiterCount = 0
```

Implement `runOnce()` with a small cancellation-aware waiter. A canceled caller must stop awaiting the shared task immediately, while the shared task is canceled only when the last waiter has left, so a canceled background-task waiter cannot cancel a wave still needed by a manual or import-triggered waiter:

```swift
public func runOnce() async -> Wave {
    guard !resetInProgress else { return Wave() }
    // Reuse/create activeWaveTask and increment the waiter count for its
    // generation token.
    // Bridge task.value through a cancellation-aware waiter that returns an
    // empty Wave immediately when this caller is canceled. On return, remove
    // this waiter; cancel the shared task only if it was the last waiter. Keep
    // the task stored until an identity-checked completion cleanup runs, so a
    // canceled but still-running wave cannot overlap a replacement wave.
}

private func cancelActiveWaveIfLastWaiter() {
    if activeWaveWaiterCount <= 1 {
        activeWaveTask?.cancel()
    }
}
```

This preserves the caller-facing result while preventing a second wave from entering the reentrant actor during the first wave’s awaits.

- [x] **Step 3: Add `requestSync()` and its draining loop.**

Implement a non-blocking actor method that records a request, creates at most one scheduler task, and drains requests serially:

```swift
public func requestSync() {
    guard !resetInProgress else { return }
    syncRequestPending = true
    guard scheduledSyncTask == nil else { return }

    let task = Task { [weak self] in
        await self?.drainSyncRequests()
    }
    scheduledSyncTask = task
}

private func drainSyncRequests() async {
    while syncRequestPending {
        syncRequestPending = false
        _ = await runOnce()
    }
    scheduledSyncTask = nil
}
```

Requests arriving while a wave is active set `syncRequestPending` and become one follow-up wave. Requests arriving while the scheduler is draining do not create another task. Keep `syncNow()` as ` _ = await runOnce()` so manual sync still waits for completion while sharing the single-flight task.

- [x] **Step 4: Make account reset cancel queued scheduler work.**

At the beginning of `resetForAccountSwitch()`, set the reset guard before clearing and cancelling the scheduler. `requestSync()` and direct `runOnce()` calls must return while that guard is set, so a stale callback cannot install a new scheduler or wave during the reset:

```swift
resetInProgress = true
syncRequestPending = false
let scheduledTask = scheduledSyncTask
scheduledSyncTask = nil
scheduledTask?.cancel()
let activeTask = activeWaveTask
activeWaveTask = nil
activeTask?.cancel()
await activeTask?.value
await scheduledTask?.value
accountGeneration += 1
await debouncer.cancelAll()
```

Then retain the existing `while activeWaveCount > 0` wait and metadata reset. Set `resetInProgress = false` only after the reset completes. A scheduled import request must not start against the new account after the reset completes. Add a test that gates a wave, requests another sync, starts account reset, releases the active wave, and asserts reset completes without a second post-reset `/api/sync/changes` request.

- [x] **Step 5: Run the focused sync tests and verify green.**

Run the command from Task 1. Expected: the new single-flight and follow-up tests pass, and all existing `SyncEngineTests` pass.

### Task 3: Remove network sync from the import completion boundary

**Files:**

- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift:308-329`
- Modify: `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Import/ImportCoordinator.swift` documentation only if needed to describe non-blocking sync scheduling accurately.

- [x] **Step 1: Change the production import callback.**

Replace the callback’s awaited full sync with:

```swift
await syncEngine.markBookDirty(bookId)

Task.detached(priority: .userInitiated) {
    guard let book = try? await bookStore.book(bookId) else { return }
    let url = bookFileStorage.absoluteFileURL(for: book)
    await bookPrewarmer.prewarm(book: book, fileURL: url)
}

await syncEngine.requestSync()
```

The import callback still waits for the local dirty marker, but returns without waiting for network I/O. Prewarming is launched independently of sync. The request is sent after dirty marking so the sync queue contains the book before the wave begins.

The same closure is passed to `SampleBookInstaller` and `SampleReaderInstaller` at `ServiceGraphFactory.swift:333-339`, so those flows receive the same behavior automatically; do not create a second callback with different sync semantics.

- [x] **Step 2: Update callback comments and import docs.**

Change comments that describe `onBookImported` as a synchronous sync hook so they state that the callback marks the local book dirty and schedules/coalesces background sync.

- [x] **Step 3: Preserve dirty-mark failure handling.**

Change `markBookDirty` to return `Bool` while retaining source compatibility for callers that ignore the result. If account reset is active, defer until reset completes; count in-flight dirty-mark operations so reset waits for metadata and queue mutations to finish before clearing account state; capture the account generation and re-check it after the metadata write so stale work cannot enqueue against a changed account. Retry the metadata mark/enqueue once after a short cooperative delay when the first attempt fails. Return `false` and log after the retry fails. The import callback must launch prewarm regardless, but call `requestSync()` only after a successful dirty mark; this avoids claiming that an unsaved dirty record will sync while retaining a bounded retry for transient persistence failures. Add a focused `SyncEngineTests` case using a metadata stub that fails once and then succeeds, asserting the second attempt enqueues the book.

- [x] **Step 4: Run focused library and sync tests.**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/ImportCoordinatorTests -only-testing:rishiTests/BookImporterTests -only-testing:rishiTests/SyncEngineTests
```

Expected: all selected tests pass and import tests still observe successful outcomes without requiring a real sync wave.

### Task 4: Overlap independent refresh work

**Files:**

- Modify: `apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryViewModel.swift:176-190`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiLibrary/RishiLibraryTests/ViewModel/LibraryViewModelRefreshTests.swift`

- [x] **Step 1: Add a failing timing test with the existing concrete storage path.**

Add a `SlowCoverExtractor` test fixture in the existing `LibraryViewModelRefreshTests.swift` file. It conforms to `CoverExtractor`, sleeps for a configured duration, and returns small arbitrary `Data`; `CoverCache` will use its PNG fallback when the data is not encodable as HEIC. Extend the existing `makeVM` helper with an optional `coverExtractors` dictionary, create one real source file per test book under the storage root, and pass `["pdf": SlowCoverExtractor(...)]`. A refresh with delayed position reads and delayed cover resolution must prove the two independent operations overlap. The test must assert total time is near the slower operation, not the sum, while preserving the existing position and cover mappings.

Expected pre-change result: FAIL because refresh awaits position resolution before starting cover resolution.

- [x] **Step 2: Run the focused refresh tests and verify the timing failure.**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/LibraryViewModelRefreshTests
```

- [x] **Step 3: Start both fan-outs before assigning MainActor state.**

Change the refresh body to:

```swift
async let positionsTask = positionLoader.positions(for: loaded)
async let coversTask = coverResolver.coverURLs(for: loaded)
let positionsByBook = await positionsTask
let resolvedCovers = await coversTask
self.books = loaded
self.positionsByBookId = positionsByBook
self.coverURLs = resolvedCovers
```

Both operations begin before either result is awaited and both results are assigned together. Do not add a new protocol or new test file; the existing concrete `BookCoverResolver`/`BookFileStorage` path is the fixture seam.

- [x] **Step 4: Run the focused refresh tests and the existing cover regression tests.**

Expected: timing and mapping tests pass, including `LibraryViewModelImportCoverRegressionTests`.

### Task 5: Adversarial implementation review and verification

- [x] **Step 1: Inspect the complete diff for requirement coverage.**

Confirm the diff contains no arbitrary parallel filesystem writes, no change to deterministic book ID semantics, no network await in the import callback, and no loss of dirty-book scheduling.

- [x] **Step 2: Dispatch an independent reviewer.**

Ask a reviewer to inspect the implementation against this plan, specifically checking actor reentrancy, task lifetime, cancellation/account switching, sync follow-up behavior, import callback ordering, and refresh state consistency. Fix every Critical/High finding, then request a second review until no Critical/High findings remain.

- [x] **Step 3: Run final verification.**

Run the focused tests from Tasks 2–4, then run the Apple app build:

```bash
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: exit code 0 with no compiler errors. Report any unavailable simulator or environment limitation explicitly rather than treating it as passing.

## Adversarial review loop of this plan

### Research review findings

- **Critical:** The import callback awaited a full `syncNow()` per successful book. Covered by Tasks 1–3.
- **High:** Actor isolation alone did not prevent overlapping sync waves across suspension points. Covered by Task 2’s active-wave task and tests.
- **High:** Naive batch parallelism could race deterministic book directories and per-book index artifacts. Explicitly excluded from this plan until identity coordination exists.
- **Medium:** Prewarming was delayed until after sync. Covered by Task 3.
- **Medium:** Refresh awaited position and cover fan-outs sequentially. Covered by Task 4.
- **Medium:** Import timing lacked end-to-end instrumentation. Existing logs remain useful for follow-up, but instrumentation is deferred until the critical latency fix is landed and verified; no performance claim will be made without fresh timing evidence.

### Plan re-review verdict

**PASS WITH NOTES after revision:** The plan closes the review findings by covering all shared import callbacks, defining bounded dirty-mark retry/defer behavior with reset-safe in-flight tracking, making wave waiters cancellation-aware with identity-checked task cleanup, canceling and awaiting active/queued sync work during account reset, and specifying an existing-file delayed cover fixture. The remaining note is that arbitrary multi-file import parallelism is intentionally deferred because the current deterministic identity model cannot safely support it; the plan instead removes the dominant per-file network serialization and overlaps independent refresh/prewarm work.

## Adversarial implementation review loop

- Round 1: BLOCK — reviewer found that cancellation could leave a caller waiting, reset could finish before a queued wave started, and the callback needed an explicit dirty-mark success guard. Fixed with cancellation-aware waiters, reset guards, active-task cancellation/awaiting, and conditional `requestSync()`.
- Round 2: NOT PASS — reviewer found that canceled tasks could be replaced before completion, old waiter cleanup could affect a later reset generation, and dirty marking could race reset. Fixed with UUID-scoped wave identity, completion-only task cleanup, reset deferral, and generation checks.
- Round 3: NOT PASS — reviewer found that an in-flight dirty mark could enqueue after reset cleanup. Fixed by tracking active dirty marks and waiting for them before reset clears queue/metadata.
- Round 4: PASS — independent re-review found no remaining Critical, High, or Important issues.
