# Swift Concurrency Rules (apps/apple)

- **ADR Number:** ADR-002
- **Date:** 2026-06-13
- **Status:** Accepted
- **Author:** GSD Phase 19 (swift-concurrency-audit-mainactor-offload-sweep-for-the-ios-app)
- **Supersedes:** None
- **Last updated:** 2026-06-13
- **Scope:** `apps/apple/` (iOS + Mac Catalyst app target + every SwiftPM package under `apps/apple/Packages/`).
- **Out of scope:** `apps/web`, `apps/mobile`, `apps/electron`, `workers/`.

## Context

Phase 19 was triggered immediately after Phase 18 Wave 1 (NavigationStack reader migration) landed: the user opened the app in the simulator and reported visible UI freezes ("app is too slow"). The hypothesis was MainActor overload, which the audit (`apps/apple/.planning/phases/19-swift-concurrency-audit-mainactor-offload-sweep-for-the-ios-app/19-RESEARCH.md`) confirmed in the first ten minutes: the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + Swift 6 strict, which makes every unannotated function in `apps/apple/rishi/rishi/**/*.swift` implicitly MainActor-bound. The cold-launch path, the library fan-out, the readers' position bindings, and the TTS observer polls were therefore all attempting to do real work on the main thread.

This ADR locks in the decisions Phase 19 made, names the patterns the project is now committed to, and gives reviewers a grep-able checklist so the same drift cannot reappear silently in a PR. Where it makes sense, each rule cites the relevant section of the Swift Concurrency book — Phase 19's load-bearing reference document.

Sibling ADR: `apps/apple/docs/SWIFTUI-NATIVE-CHOICES.md` (Phase 18 — UI surface). Phase 19 is its concurrency twin.

## Default isolation contract

The asymmetry between the app target and the packages is deliberate and stays.

| Target | `SWIFT_DEFAULT_ACTOR_ISOLATION` | `SWIFT_VERSION` | Strict concurrency | Where it is set |
|--------|---------------------------------|-----------------|--------------------|-----------------|
| `rishi` app (Debug + Release) | **MainActor** | 6.0 | Yes (approachable on) | `apps/apple/rishi/rishi.xcodeproj/project.pbxproj` lines 504-508 (Debug) and 544-548 (Release) |
| `rishiTests`, `rishiUITests` | (none) | 5.0 | (none) | Test targets opt out so legacy XCTest patterns compile |
| All 16 SwiftPM packages under `apps/apple/Packages/` | (none → nonisolated) | 6.0 | Yes (default) | Each package's `Package.swift` (e.g. `Packages/RishiLibrary/Package.swift`) |

**Why this is correct.** The app target is the UI surface; SwiftUI views, view models, and bindings are MainActor by definition and the default-MainActor setting removes ceremonial `@MainActor` annotations from every view file. The packages are libraries: their types should be nonisolated by default and opt into `@MainActor` only when they own UI state (e.g. `LibraryViewModel`, `TTSPlaybackState`).

The consequence reviewers must internalise: any closure body inside `apps/apple/rishi/rishi/**/*.swift` runs on the main actor unless it is explicitly opted out (via `nonisolated`, `Task.detached`, or an inner `await someActor.method()`). This is the inverse of the default Swift 6 behaviour outside this target. The bare-Task audits in plans 19-04 (app target) and 19-05 (packages) exist for this reason.

Swift book references: [Isolation → Default Isolation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Isolation) and [Tasks and Task Groups → Unstructured Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Unstructured-Concurrency).

## The four patterns we use

Every async call site in `apps/apple/` should fit one of the four patterns below. Reviewers can ask which pattern a new site belongs to; "none of them" is itself a checkpoint signal that the change needs ADR discussion.

### Pattern A — Pure UI work: bare `Task { }` (implicit MainActor in the app target)

When the body only mutates `@Observable` view state or fires another `@MainActor` method that itself does the off-main hops, a bare `Task { }` inside an app-target view or view model is correct. The body runs on MainActor; the inner `await` suspends back to MainActor for the assignment, which is what SwiftUI needs.

```swift
// app target — RootView or an @MainActor view model
Button("Refresh") {
    // KEEP: pure UI work; await suspends back to MainActor for state assignment.
    Task {
        await viewModel.refresh()
    }
}
```

### Pattern B — I/O on stores: `await store.read { ... }` (store owns its own queue)

GRDB stores ship as `final class @unchecked Sendable`. The lock is provided by `DatabaseQueue`, not by Swift's actor system (STATE.md Phase 2 decision). Any read or write goes through the store's async API; the store hops onto its own queue internally and returns the result.

```swift
// caller may be MainActor or nonisolated; the store hops itself
let book = try await deps.bookStore.book(bookId)
```

For library-style fan-out where each lookup is independent, wrap the loop in a `withTaskGroup` so reads run concurrently rather than serially (Plans 19-02, 19-03):

```swift
let pairs: [(BookID, URL?)] = await withTaskGroup(of: (BookID, URL?).self) { group in
    for book in books {
        group.addTask { [book] in
            let url = await viewModel.coverURL(for: book)
            return (book.id, url)
        }
    }
    var out: [(BookID, URL?)] = []
    for await pair in group { out.append(pair) }
    return out
}
```

Swift book reference: [Calling Asynchronous Functions in Parallel](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Calling-Asynchronous-Functions-in-Parallel).

### Pattern C — Heavy CPU or large decode: `Task.detached(priority:).value` + `nonisolated` helper

Anything CPU-heavy on the app target — `PDFDocument(url:)`, Readium `PublicationOpener.open(...)`, `JSONDecoder().decode(...)` of a large payload, regex strip of a chapter's worth of HTML — MUST run via `Task.detached(priority: .userInitiated)` so the work leaves MainActor. Plans 19-07 (PDFDocument), 19-08 (EPUB Publication), 19-09 (EPUB `stripHTML`), and 19-11 (scene-restore decode) are the canonical examples.

```swift
// PDFReaderViewModel.load() — plan 19-07
public func load() async {
    let doc: PDFDocument? = await Task.detached(priority: .userInitiated) { [documentURL] in
        PDFDocument(url: documentURL)
    }.value
    guard let doc else { return }
    // assignment runs back on the caller's isolation (MainActor in the app target)
    self.document = doc
}
```

When the work is referenced from MainActor code, place the heavy helper as `nonisolated private static func` so the type system makes the off-main intent explicit:

```swift
// RootView scene-restore — plan 19-11
nonisolated private static func decodeSceneRestoreCells(
    tabRaw: String,
    openBookIdRaw: String
) -> (state: RishiSceneState, path: NavigationPath?, route: ReaderRoute?, legacyId: UUID?) {
    // pure value work — Codable round-trips, no actor isolation needed
}
```

Swift book references: [Tasks and Task Groups → Unstructured Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Unstructured-Concurrency), [Isolation → Nonisolated Code](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Nonisolated-Code), [Sendable Types](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Sendable-Types) (the result of a `detached` task is `sending`, which transfers a non-Sendable value across an actor boundary safely).

### Pattern D — Shared mutable state: `actor`

When two or more concurrency domains write to the same state, model it as a Swift `actor`. Phase 19 has not added any new actors; the existing `SyncEngine`, `PositionDebouncer`, `BookFileStorage`, `PDFThumbnailCache`, and `EntitlementService` are the prior art. New shared state should follow the same pattern unless the lock-not-actor exception below applies.

**Lock-not-actor exception (kept deviation).** `GRDB` stores in `RishiDB` and `RishiSync` and the `OSAllocatedUnfairLock`-backed `KeychainBackend` implementations stay as `final class @unchecked Sendable` — see STATE.md Phase 2 and Phase 3 decisions. Wrapping them in an actor would double-hop every read/write and break the synchronous `read { db in ... }` closure ergonomics GRDB depends on.

Swift book reference: [Actors](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors).

## Annotation style for bare `Task { }` sites

Every bare `Task { }` site in `apps/apple/` MUST carry a one-line comment immediately above it explaining why it is safe. The two allowed annotations are:

- `// KEEP: <reason this body is correctly MainActor>` — the body only touches `@Observable` view state, awaits a store/actor method that hops itself, or registers a callback. The site is intentionally MainActor-bound.
- `// DETACHED: F-<finding-id>` — the body has been migrated to `Task.detached(priority: .userInitiated) { ... }.value` plus a MainActor assignment. The finding id (e.g. `// DETACHED: F-P0-08`) is the audit traceability link.

This contract is enforced mechanically by `BareTaskAuditTests`:

- App target — added in plan 19-04 (commit `0122da14e`). Test file: `apps/apple/rishi/rishiTests/Concurrency/BareTaskAuditTests.swift`.
- Packages — added in plan 19-05 (mirror), one test per package that contains a bare `Task { }`.

The audit walks every `*.swift` file in scope, finds `Task {` lines, and asserts that the preceding non-blank line matches `// KEEP:` or `// DETACHED:`. Adding a new bare `Task { }` without the annotation fails CI. To opt out of the audit for a genuine corner case, add `// KEEP: ad-hoc — <one-sentence reason>` and link the discussion in your PR.

## PR-Review Checklist (grep-able)

Reviewers run these grep / `rg` queries on any diff that touches async code under `apps/apple/`. Every match should be either expected (annotated) or replaced before merge. (Section heading retained as "PR-Review Checklist" so the audit grep in Plan 19-12 matches.)

- [ ] **No new bare `Task { }` without `// KEEP:` or `// DETACHED:` annotation in the app target.**
  ```bash
  rg -nU "Task \{(?!.*//)" apps/apple/rishi/rishi --type swift
  ```
  Every match must have a `// KEEP:` or `// DETACHED:` comment on the immediately preceding line.

- [ ] **Every `Task.detached` declares an explicit `priority:`.**
  ```bash
  rg "Task\.detached\((?!priority:)" apps/apple --type swift
  ```
  Defaulting priority is a smell — pick `.userInitiated` for foreground work or `.utility` / `.background` for prefetch / sync.

- [ ] **No new `UIImage(data:)` or `UIImage(contentsOfFile:)` on MainActor.**
  ```bash
  rg "UIImage\((data|contentsOfFile):" apps/apple --type swift
  ```
  Cover and thumbnail rendering must be wrapped in `Task.detached` or use `AsyncImage`. Existing safe sites are `NowPlayingProtocol.swift` (lock-screen artwork — once-per-book) and `EpubCoverExtractor.swift` (already inside `Task.detached(priority: .utility)`).

- [ ] **No new `JSONDecoder` / `JSONEncoder` calls inside a SwiftUI body or `Canvas`.**
  ```bash
  rg "try .*Decoder\(\)\.decode|JSONEncoder\(\)\.encode" apps/apple --type swift
  ```
  Large payload decode belongs in a view model or a `nonisolated` static helper, not in a body that re-evaluates on scroll. Pre-decode once on load.

- [ ] **No new `MainActor.run` inside hot-path loops.**
  ```bash
  rg -B2 "MainActor\.run" apps/apple --type swift | rg "Task\.sleep"
  ```
  Polling MainActor at 50ms / 100ms / 250ms cadences is the pattern Phase 19 spent three plans removing (Plans 19-06, 19-08, 19-12). Re-introducing it is a regression.

- [ ] **No new synchronous GRDB read inside `AppDependencies.init()` or a `@MainActor` SwiftUI body.**
  ```bash
  rg "try .*queue\.read|try .*queue\.write" apps/apple/rishi/rishi --type swift
  ```
  Bootstrap heavy work belongs in `AppDependencies.bootstrap()` (Plan 19-01).

- [ ] **No new `@MainActor` on a function that does not touch UI state.**
  ```bash
  rg "@MainActor (func|class|public func)" apps/apple --type swift
  ```
  An `@MainActor` annotation in a package SHOULD touch `@Observable` state, present a sheet, or write to `@AppStorage`. Otherwise it is forcing a needless hop.

- [ ] **Every `OSAllocatedUnfairLock` / `NSLock` / `DispatchSemaphore` instance is justified.**
  ```bash
  rg "OSAllocatedUnfairLock|NSLock|DispatchSemaphore" apps/apple --type swift
  ```
  Every instance must either match a kept-deviation entry below (GRDB stores, KeychainBackend, RishiSync, PDFThumbnailCache `nonisolated(unsafe) NSCache`, RishiAudio Fake helpers) or come with an actor rewrite proposal in the PR description.

- [ ] **Long `Task` bodies cooperatively check cancellation.**
  ```bash
  rg -B1 -A20 "Task \{" apps/apple/rishi/rishi --type swift | rg "Task\.checkCancellation|withTaskCancellationHandler"
  ```
  Any `Task` body with two or more `await` calls should call `try Task.checkCancellation()` between them or use `withTaskCancellationHandler`. See Rule 7 below.

- [ ] **`OSSignposter` intervals on the 5 hot paths are not removed.**
  ```bash
  rg "cold-launch\.bootstrap|library\.first-paint|reader\.(epub|pdf)\.open|reader\.chrome\.toggle|sync\.wave|position-sync" apps/apple --type swift | wc -l
  ```
  Expect at least 6 matches. Phase 19 added these intervals in Plans 19-06 and 19-08; removing them silently disables hardware-verify trace capture.

Swift book reference for cancellation: [Task Cancellation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Task-Cancellation).

## OSSignposter convention

Every package that owns a hot path declares a file-static `OSSignposter` with the subsystem `org.fidexa.rishi` and category `perf`:

```swift
import os.signpost

private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "perf"
)
```

Intervals are named with a dotted path: `cold-launch.bootstrap`, `library.first-paint`, `reader.epub.open`, `reader.pdf.open`, `reader.chrome.toggle`, `sync.wave`, `position-sync.epub.tick`, `position-sync.pdf.tick`. New hot paths follow the same naming scheme so Instruments filters work consistently across plans.

Phase 19 references:

- Plan 19-06 (commit `8ce4a24ff`) — wrapped the EPUB and PDF position-sync poll ticks.
- Plan 19-08 (commit `310bed397`) — wrapped the four remaining hot paths (cold-launch bootstrap, library first-paint, reader open, chrome toggle, sync wave).

Hardware verify (`apps/apple/docs/PHASE-19-HARDWARE-VERIFY.md`, deferred — see backlog) consumes these signposts in Instruments Time Profiler and the SwiftUI template.

## Cross-references

The following findings were addressed outside Phase 19 and MUST NOT be re-planned here. They are listed so future readers do not duplicate work.

- **F-P1-06 — TTS index box `@unchecked Sendable` cleanup** (`PDFReadAloudIndexBox`, `EPUBReadAloudIndexBox`). Closed by Phase 18 plan 18-05, **commit `ac1bc228d`**. Phase 19 does not touch these files.
- **Phase 18 reader-chrome trap fix.** Quick fix `dbc1c7d6d` set `initiallyVisible: true`; the structural fix landed in Phase 18 plan 18-01 (NavigationStack migration).

## Kept deviations

The patterns below look non-idiomatic at first glance but are defensible. Do NOT reflexively migrate them.

- **`PDFThumbnailCache.memoryCache` as `nonisolated(unsafe) NSCache`** — `NSCache` is documented thread-safe (TN1170); the `nonisolated(unsafe)` opts out of Swift 6 race checks because the lock is in `NSCache` itself, not in the actor system. Wrapping it in an actor would double-hop every cache get / set. Location: `apps/apple/Packages/RishiReader/Sources/RishiReader/PDF/PDFThumbnailCache.swift:50`. Audit verdict: "starter areas reported clean" in 19-RESEARCH.md.
- **`RishiAudio` Fake test helpers ship with `NSLock`** — `FakeAudioEngine`, `FakeAudioSessionConfigurator`, `FakeNowPlayingInfoSurface`, `FakeRemoteCommandSurface` use `NSLock` for call-count recording. Tests-only; not on the production path. Same rationale as the RishiSync `@unchecked Sendable` pattern documented in `SWIFTUI-NATIVE-CHOICES.md` Deviation 5.
- **TTS index boxes (`PDFReadAloudIndexBox`, `EPUBReadAloudIndexBox`)** — defensive `OSAllocatedUnfairLock` over a dictionary that is in practice only mutated on MainActor. Closed by Phase 18 plan 18-05 (commit `ac1bc228d`). Cross-reference F-P1-06.
- **GRDB stores as `final class @unchecked Sendable`** — STATE.md Phase 2 decision. `DatabaseQueue` already serialises access; an outer actor would double-hop every read/write.
- **`RishiSync` uploaders / fetchers / `EngineHolder` / `SyncStatus` as `@unchecked Sendable`** — STATE.md Phase 7 decision. URLSession callbacks are inherently nonisolated; forcing them onto MainActor would be wrong. Already documented in `SWIFTUI-NATIVE-CHOICES.md` Deviation 5; restated here so the concurrency story is in one place.
- **`NowPlayingController` / `TTSPassageTracker` / `ReaderTTSBridge` 50ms / 100ms polls** — deferred to v1.1 backlog below. Phase 19 elected not to migrate these because the existing transition-coalesce logic keeps user-visible call counts low; the structural fix (`withObservationTracking` re-arm) is queued as a single follow-up plan.

## v1.1 Backlog

Deferred to post-v1.0 (NOT shipping in Phase 19):

1. **F-P0-07 — Position-sync push.** Replace the 250ms poll in `EPUBReaderPositionSyncBinding` and `PDFReaderPositionSyncBinding` with a push-based `AsyncStream<Locator>` / `AsyncStream<Int>` on the respective ReaderViewModel. `SyncEngine`'s `PositionDebouncer` (1s window) absorbs the higher rate. Plan 19-06 added OSSignposter intervals around the existing poll so the v1.1 swap can be measured against a baseline.
2. **F-P1-03 / F-P1-04 / F-P1-05 — TTS observer push.** Replace the 50ms / 50ms / 100ms polls in `NowPlayingController`, `TTSPassageTracker`, and `ReaderTTSBridge.startAdvanceWatcher` with `withObservationTracking` re-arm. State is `@MainActor @Observable` so this is the documented pattern.
3. **F-P1-01 — `PDFHighlightOverlay` pre-decode.** Pre-decode highlights once on the VM; drop `JSONDecoder` from the `Canvas` body. Scroll/zoom hygiene only — no correctness risk.
4. **F-P1-07 — EPUB `stripHTML` Task.detached.** Wrap the regex-based HTML strip in `Task.detached` so it cannot accidentally land on MainActor when the caller's isolation drifts. Phase 19 plan 19-09 partially closed this for the immediate path; the audit pass is the v1.1 follow-up.
5. **F-P2-01 / F-P2-05 — Cancellation hygiene audit.** Add `try Task.checkCancellation()` to long async paths (deep-link Tasks in RootView, ReaderTTSBridge advance watcher, library refresh). The grep check above will fail until this lands; it is allow-listed for v1.0 because no observed leak has affected users.
6. **F-P2-02 — `RishiAppDelegate.shared` race window.** Replace `nonisolated(unsafe) static var` with `OSAllocatedUnfairLock<RishiAppDelegate?>` or an actor accessor. Race window is tiny but unbounded.
7. **Optional: bulk `positions(forBookIds:)` PositionStore method.** Plan 19-03 closed the worst of the serial fan-out via `withTaskGroup`; a single round-trip query would remove the residual actor-hop overhead and is the cheapest remaining library-paint win.
8. **Phase 19 + Phase 18 hardware-verify runbook.** Publish `apps/apple/docs/PHASE-19-HARDWARE-VERIFY.md` with explicit Instruments steps (Time Profiler, Hangs, SwiftUI template) and the four scenarios to capture: cold launch, library scroll, book open, read-aloud during read. Depends on a hardware device pass to capture baselines; the OSSignposter intervals from Plans 19-06 and 19-08 are the consumer surface.
9. **Swift 6 strict edges discovered in 19-07 / 19-09.** Plan 19-07's PDFDocument off-main load and 19-09's EPUB Publication off-main load both worked in practice under Swift 6 strict; if Apple's compiler tightens `sending` semantics in a future toolchain, the fallback (construct on main inside `.task(priority: .userInitiated)`) is the documented escape. Re-validate after every Xcode minor bump.

## How to use this document

**For PRs touching async code under `apps/apple/`:**

1. Identify which of the four patterns (A bare `Task`, B `await store`, C `Task.detached`, D actor) the new code belongs to. If none of them fit, the change needs ADR-level discussion before merge.
2. Run the PR-review grep checklist above on your diff. Every match is either expected (annotated) or a regression.
3. If you are adding a bare `Task { }`, prefix it with `// KEEP:` or `// DETACHED: F-<id>`. `BareTaskAuditTests` will fail without it.
4. If you discover a NEW deviation that is correct to keep (e.g. an unavoidable lock around a system framework), ADD a new bullet to the "Kept deviations" section above with the rationale. Do not let kept deviations accumulate undocumented.
5. If a v1.1 Backlog item lands, move its bullet from the backlog to the relevant rule section and tag the closing commit hash inline (same style as the Phase 18 `ac1bc228d` reference above).

**For future Phase 19 audits (post-v1.0):**

1. Re-validate the kept deviations — confirm each constraint still applies under the current Xcode / Swift / Readium / PDFKit versions.
2. Re-run the grep checklist over the full `apps/apple/` tree as a smoke audit; new violations indicate drift since this ADR was written.
3. Capture an Instruments Time Profiler trace using the OSSignposter intervals; compare against the Plan 19-01 / 19-02 / 19-03 baselines (recorded in the respective plan SUMMARYs).

## References

- Swift Concurrency book (canonical): <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/>
- 19-RESEARCH.md (this phase's audit): `apps/apple/.planning/phases/19-swift-concurrency-audit-mainactor-offload-sweep-for-the-ios-app/19-RESEARCH.md`
- Phase 18 sibling ADR: `apps/apple/docs/SWIFTUI-NATIVE-CHOICES.md`
- Commit `ac1bc228d` (Phase 18 plan 18-05 — TTS lock cleanup; cross-ref F-P1-06)
- Plan 19-01 commits `510361902`, `fa18d1ce6` (two-phase AppDependencies bootstrap)
- Plan 19-02 commit `ef79009e8` (parallel cover fan-out)
- Plan 19-03 commit `afacebdc5` (parallel position fan-out)
- Plan 19-04 commit `0122da14e` (bare-Task audit + annotations in app target)
- Plan 19-06 commit `8ce4a24ff` (position-sync OSSignposter intervals)
- Plan 19-07 commit `253e8bdd0` (PDFDocument off-main load)
- Plan 19-08 commit `310bed397` (OSSignposter wrapping of 4 remaining hot paths)
- Plan 19-09 commit `61459faf3` (EPUB publication load + parse off-MainActor)
- Plan 19-11 commit `97b655b8e` (scene-restore decode off-MainActor)
- STATE.md — `apps/apple/.planning/STATE.md` (Phase 2 GRDB decision, Phase 3 Keychain decision, Phase 7 RishiSync decision)
- Apple TN1170 — `NSCache` thread safety (cited in `PDFThumbnailCache` kept-deviation)
