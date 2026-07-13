# Page-entry TTS Prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefetch the first playable paragraph after user navigation on EPUB and PDF pages when an opted-in Read Aloud session is paused or stopped, without changing playback behavior.

**Architecture:** Keep page-entry prefetch as an isolated method on `ReadAloudController`. It accepts one already-extracted paragraph, loads the active TTS settings, and submits one request to the shared `TTSPrewarmer`; it never calls player lifecycle methods. Add a second navigation callback to the unified Readium `ReaderViewModel` so the existing callback that stops playback remains separate, then wire the app destination to extract the new page's first paragraph and invoke the prefetch method. Both EPUB and PDF routes use this unified reader path.

**Tech Stack:** Swift 6, SwiftUI Observation, Readium, Swift Testing, `TTSPrewarmer`, shared cache/in-flight coalescing.

---

### Task 1: Add failing controller prefetch tests

**Files:**
- Modify: `rishi/rishiTests/ReadAloudControllerTests.swift`
- Test helper: use the existing `FakeTTSEngine`, `InMemoryTTSSettingsStore`, `AudioSessionCoordinator`, and a recording `TTSChunkSource` that records requests received by `TTSPrewarmer`.

- [x] **Step 1: Add a recording source and request polling helper.**

Add an actor-backed source beside `ControllerNoopChunkSource`:

```swift
private actor ControllerRecordingChunkSource: TTSChunkSource {
    private(set) var requests: [TTSStreamRequest] = []

    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        requests.append(request)
        return AsyncThrowingStream { $0.finish() }
    }

    func snapshot() -> [TTSStreamRequest] { requests }
}
```

Add an async polling helper that waits up to two seconds for a request count,
using `Task.sleep(for: .milliseconds(20))` between snapshots. Keep the helper
in the test file so production code has no test-only polling API.

- [x] **Step 2: Write the red tests for the session/state gate.**

Add tests with these exact behaviors:

```swift
@Test("page-entry prefetch is ignored before Read Aloud starts")
func pageEntryPrefetchRequiresSession() async {
    let source = ControllerRecordingChunkSource()
    let controller = makeController(source: source)

    #expect(controller.canPrefetchPageEntry == false)
    await controller.prefetchFirstParagraph("not started")

    #expect(await source.snapshot().isEmpty)
}

@Test("page-entry prefetch warms one paragraph while stopped")
func pageEntryPrefetchWarmsOneParagraph() async {
    let source = ControllerRecordingChunkSource()
    let controller = makeController(source: source)
    await controller.start(paragraphs: ["current"], onPassageChange: { _ in })
    await controller.stop()

    #expect(controller.canPrefetchPageEntry)
    await controller.prefetchFirstParagraph("new page first")
    let requests = await waitForRequests(source, count: 1)

    #expect(requests.map(\.text) == ["new page first"])
    #expect(requests[0].passageId == nil)
    await controller.stop()
}

@Test("page-entry prefetch is ignored while playing")
func pageEntryPrefetchSkipsPlaying() async {
    let source = ControllerRecordingChunkSource()
    let controller = makeController(source: source)
    await controller.start(paragraphs: ["current"], onPassageChange: { _ in })

    #expect(controller.canPrefetchPageEntry == false)
    await controller.prefetchFirstParagraph("playing page")
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.snapshot().isEmpty)
    await controller.stop()
}
```

Update `makeController` to accept an injected source and build
`TTSPrewarmer(source: source)`. The initial implementation should fail because
the controller has no `canPrefetchPageEntry` or `prefetchFirstParagraph` API.

- [x] **Step 3: Run the focused test and confirm the expected red failure.**

Run:

```bash
swift test --package-path rishi --filter ReadAloudControllerTests
```

Expected: compilation/test failure identifying the missing controller API,
not a package or test-discovery failure.

### Task 2: Add failing navigation callback coverage

**Files:**
- Modify: `Packages/RishiReader/Tests/RishiReaderTests/ReaderViewModelTests.swift`
- Modify: `Packages/RishiReader/Sources/RishiReader/EPUB/ReaderViewModel.swift`

- [x] **Step 1: Add a test proving user navigation emits the prefetch callback.**

Add a callback counter/locator capture to the existing `ReaderViewModel` test
fixture and assert that `didChangeLocation(locator)` invokes the new callback
once after updating `latestLocator`.

- [x] **Step 2: Add a test proving programmatic navigation does not emit it.**

Call `didChangeLocation(locator, isProgrammatic: true)` with the same callback
installed and assert the callback remains empty. This preserves the existing
read-aloud auto-follow distinction.

- [x] **Step 3: Run the focused reader test and confirm it fails for the missing callback.**

Run:

```bash
swift test --package-path Packages/RishiReader --filter ReaderViewModelTests
```

Expected: compilation failure for the new callback property until the model
implementation is added.

### Task 3: Implement the isolated controller prefetch API

**Files:**
- Modify: `rishi/rishi/Audio/ReadAloudController.swift`
- Modify: `rishi/rishiTests/ReadAloudControllerTests.swift`

- [x] **Step 1: Track opt-in without changing stop behavior.**

Add a private `hasStartedReadAloudSession` flag. Set it only after
`startReader(vm:)` creates the Readium synthesizer or `start(paragraphs:...)`
installs the bridge. Do not clear it from `stop()`; the user has still opted
into Read Aloud after stopping, which is the required stopped-state prefetch
case.

Expose a read-only computed property:

```swift
var canPrefetchPageEntry: Bool {
    hasStartedReadAloudSession
        && (ttsState.status == .paused || ttsState.status == .stopped)
}
```

- [x] **Step 2: Add the one-paragraph prefetch method.**

Implement:

```swift
func prefetchFirstParagraph(_ paragraph: String?) async {
    guard hasStartedReadAloudSession,
          let paragraph,
          !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }

    let settings = await ttsSettingsStore.load(userId: userId)
    await ttsPrewarmer.warm(requests: [
        TTSStreamRequest(
            text: paragraph,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed,
            passageId: nil
        )
    ])
}
```

This method must not call `stop`, `pause`, `resume`, `start`, `bridge`, or
`readiumSynthesizer`. `TTSPrewarmer` remains responsible for cache-hit checks
and the cache source remains responsible for in-flight coalescing.

- [x] **Step 3: Run the controller tests green.**

Run:

```bash
swift test --package-path rishi --filter ReadAloudControllerTests
```

Expected: all existing controller tests plus the three new page-entry tests
pass.

### Task 4: Implement the separate unified-reader navigation seam

**Files:**
- Modify: `Packages/RishiReader/Sources/RishiReader/EPUB/ReaderViewModel.swift`
- Modify: `Packages/RishiReader/Sources/RishiReader/EPUB/EPUBReadAloudCursor.swift`
- Modify: `rishi/rishi/Reader/ReaderDestination.swift`
- Modify: `Packages/RishiReader/Tests/RishiReaderTests/ReaderViewModelTests.swift`

- [x] **Step 1: Add a distinct prefetch callback property.**

Add:

```swift
public var onUserNavigationForTTSPagePrefetch: ((Locator) -> Void)?
```

In `didChangeLocation`, keep the existing `onUserNavigation?(locator)` call
unchanged, then invoke the new callback only inside `if !isProgrammatic`. Do
not merge it into the callback that stops read-aloud.

- [x] **Step 2: Wire the callback without controlling playback.**

In `ReaderDestination.task`, retain the existing callback:

```swift
vm.onUserNavigation = { _ in
    Task { await readAloud?.stop() }
}
```

Add a separate callback:

```swift
vm.onUserNavigationForTTSPagePrefetch = { [weak vm] locator in
    guard readAloud?.canPrefetchPageEntry == true else { return }
    Task { @MainActor [weak vm, weak readAloud] in
        guard let vm,
              let paragraph = await vm.firstParagraphForPageEntryPrefetch(at: locator)
        else { return }
        await readAloud?.prefetchFirstParagraph(paragraph)
    }
}
```

The prefetch callback must not call any playback lifecycle method. It uses the
unified Readium publication/resource path for both EPUB and PDF routes. The
view model snapshots the publication and callback locator on the main actor;
the cursor's stateless extraction helper does the resource read and paragraph
selection off-main without touching mutable reader state.

- [x] **Step 3: Run the focused reader/audio tests.**

Run:

```bash
swift test --package-path Packages/RishiReader --filter ReaderViewModelTests
swift test --package-path rishi --filter 'ReadAloudControllerTests|ReaderTTSBridgePageNavTests'
```

Expected: all focused tests pass, including the user/programmatic callback
coverage and existing playback page-navigation tests.

### Task 5: Verify cache-aware behavior and integration

**Files:**
- Modify: `rishi/rishiTests/ReadAloudControllerTests.swift` only if a cache-hit
  assertion is needed; otherwise reuse existing `TTSPrewarmerTests`.

- [x] **Step 1: Add or extend a cache-hit regression test.**

The existing `TTSPrewarmerTests` and `CachingTTSChunkSourceTests` cover cache
hits, cache misses, and identical in-flight coalescing. The page-entry method
delegates directly to `TTSPrewarmer.warm`, so it adds no cache bypass.

- [x] **Step 2: Run the affected package suites.**

Run:

```bash
swift test --package-path Packages/RishiAudio --filter 'TTSPrewarmerTests|CachingTTSChunkSourceTests'
swift test --package-path Packages/RishiReader --filter ReaderViewModelTests
swift test --package-path rishi --filter 'ReadAloudControllerTests|ReaderTTSBridgePageNavTests|ReadAheadCoordinatorTests|ReadiumTTSPrefetchCoordinatorTests'
```

The RishiAudio cache/coalescing selection passed. The standalone RishiReader
package test command remains blocked by its existing macOS deployment-target
conflicts between Readium products. No worker/shared-package files are staged
or modified by this task.

- [x] **Step 3: Run full relevant verification.**

Run:

```bash
swift test --package-path Packages/RishiAudio
swift test --package-path Packages/RishiReader
git diff --check
git status --short
```

The iOS app build with code signing disabled passed and `git diff --check` is
clean. The Mac Catalyst build remains blocked by the pre-existing
`ActivityKit`-unavailable error in `TTSPresence.swift`. Existing unrelated
worker/shared-package changes remain unstaged.

- [ ] **Step 4: Commit only the feature files.**

Stage explicit paths, never `git add -A`, because the workspace contains
unrelated worker/shared-package changes:

```bash
git add rishi/rishi/Audio/ReadAloudController.swift \
  rishi/rishi/Reader/ReaderDestination.swift \
  rishi/rishiTests/ReadAloudControllerTests.swift \
  Packages/RishiReader/Sources/RishiReader/EPUB/ReaderViewModel.swift \
  Packages/RishiReader/Sources/RishiReader/EPUB/EPUBReadAloudCursor.swift \
  Packages/RishiReader/Tests/RishiReaderTests/ReaderViewModelTests.swift \
  docs/superpowers/specs/2026-07-13-page-entry-tts-prefetch-design.md \
  docs/superpowers/plans/2026-07-13-page-entry-tts-prefetch.md
git commit -m "feat(tts): prefetch page entry paragraph"
```
