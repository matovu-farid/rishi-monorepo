# Readium TTS Prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefetch the next five Readium paragraph requests into the existing cache without changing `PublicationSpeechSynthesizer` playback behavior.

**Architecture:** Add cache-hit filtering to `TTSPrewarmer`, then add an app-side `ReadiumTTSPrefetchCoordinator` that independently walks the publication content from the active utterance locator, applies `CustomTTSTokenizer`, and submits only future requests to the prewarmer. `ReadAloudController` starts, refreshes, and stops this coordinator while Readium remains the sole playback iterator.

**Tech Stack:** Swift 6, Readium `Publication`/`ContentIterator`, `PublicationSpeechSynthesizer`, `TTSChunkSource`, `CachingTTSChunkSource`, Swift Testing.

---

### Task 1: Make the prewarmer cache-aware

**Files:**
- Modify: `Packages/RishiAudio/Sources/RishiAudio/TTS/TTSPrewarmer.swift`
- Test: `Packages/RishiAudio/Tests/RishiAudioTests/TTSPrewarmerTests.swift`

- [x] **Step 1: Write the failing test**

Add a source test double whose `shouldShowLoading(for:)` returns `false` for a known request and whose `stream(request:)` records calls. Assert that `warm(requests:)` never streams the cached request and still streams a cache miss.

```swift
@Test("warm skips requests already present in the source cache")
func warmSkipsCachedRequests() async throws {
    let cached = makeRequest(text: "cached")
    let missing = makeRequest(text: "missing")
    let source = CacheAwareFakeSource(cachedRequests: [cached])
    let prewarmer = TTSPrewarmer(source: source)

    await prewarmer.warm(requests: [cached, missing])
    #expect(await source.waitForRequests() == [missing])
}
```

- [x] **Step 2: Run the test to verify it fails**

Run:

```bash
swift test --package-path Packages/RishiAudio --filter TTSPrewarmerTests/warmSkipsCachedRequests
```

Expected: FAIL because `TTSPrewarmer.warm` currently streams every request.

- [x] **Step 3: Implement the minimal cache check**

In `TTSPrewarmer.warm`, check the source before creating an in-flight task:

```swift
for req in requests {
    guard await source.shouldShowLoading(for: req) else { continue }
    // existing task creation and registration
}
```

The source remains responsible for cache semantics; the prewarmer only skips requests reported as already available.

- [x] **Step 4: Run the focused tests**

Run:

```bash
swift test --package-path Packages/RishiAudio --filter TTSPrewarmerTests
```

Expected: PASS, including the new cache-hit test and existing cancellation tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/RishiAudio/Sources/RishiAudio/TTS/TTSPrewarmer.swift Packages/RishiAudio/Tests/RishiAudioTests/TTSPrewarmerTests.swift
git commit -m "fix(audio): skip cached TTS prewarms"
```

### Task 2: Add the Readium look-ahead coordinator

**Files:**
- Create: `rishi/rishi/Audio/ReadiumTTSPrefetchCoordinator.swift`
- Test: `rishi/rishiTests/Audio/ReadiumTTSPrefetchCoordinatorTests.swift`

- [x] **Step 1: Write the failing request-window test**

Test the coordinator’s pure request extraction seam with a fixture publication/content provider. Assert that it returns five requests after the current utterance, excludes the current text, and copies voice/model/speed into every request.

```swift
@Test("prefetch window excludes current paragraph and uses active settings")
func prefetchWindowUsesNextFiveParagraphs() async throws {
    let result = ReadiumTTSPrefetchRequestBuilder.makeRequests(
        paragraphs: ["one", "two", "three", "four", "five", "six", "seven"],
        after: "two",
        settings: .init(voice: "alloy", model: "gpt-4o-mini-tts", speed: 1.1),
        limit: 5
    )

    #expect(result.map(\.text) == ["three", "four", "five", "six", "seven"])
    #expect(result.allSatisfy { $0.voice == "alloy" && $0.speed == 1.1 })
}
```

- [x] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild -quiet -project rishi/rishi.xcodeproj -scheme rishi -destination 'generic/platform=iOS Simulator' -only-testing:rishiTests/ReadiumTTSPrefetchCoordinatorTests test
```

Expected: FAIL because the coordinator and request-window seam do not exist.

- [x] **Step 3: Implement the coordinator**

Create a `@MainActor` coordinator with `readAhead = 5`, a cancellable discovery task, and these responsibilities:

```swift
@MainActor
final class ReadiumTTSPrefetchCoordinator {
    private let prewarmer: TTSPrewarmer
    private let readAhead: Int
    private var task: Task<Void, Never>?

    func update(
        publication: Publication,
        utterance: PublicationSpeechSynthesizer.Utterance,
        settings: TTSSettings
    )

    func stop() async
}
```

`update` cancels only the coordinator’s iterator task, starts an independent `publication.content(from: utterance.locator)?.iterator()`, tokenizes elements with `CustomTTSTokenizer`, skips the current utterance, builds up to five `TTSStreamRequest`s, and calls `prewarmer.warm(requests:)`. Errors and cancellation are best-effort and never propagate into playback.

- [x] **Step 4: Run coordinator tests**

Run the focused test command again. Expected: PASS with exactly five future requests and no current-paragraph request.

- [ ] **Step 5: Commit**

```bash
git add rishi/rishi/Audio/ReadiumTTSPrefetchCoordinator.swift rishi/rishiTests/Audio/ReadiumTTSPrefetchCoordinatorTests.swift
git commit -m "feat(reader): add Readium TTS prefetcher"
```

### Task 3: Wire prefetch lifecycle into ReadAloudController

**Files:**
- Modify: `rishi/rishi/Audio/ReadAloudController.swift`
- Test: `rishi/rishiTests/ReadAloudControllerTests.swift`

- [ ] **Step 1: Write the failing lifecycle test**

Add a controller test seam that records prewarmer requests and verifies that starting Readium playback creates a prefetch coordinator, receiving a playing utterance warms future requests, and stopping cancels it without invoking a second playback request.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild -quiet -project rishi/rishi.xcodeproj -scheme rishi -destination 'generic/platform=iOS Simulator' -only-testing:rishiTests/ReadAloudControllerTests test
```

Expected: FAIL because `ReadAloudController` does not own or update a Readium prefetch coordinator.

- [x] **Step 3: Wire the coordinator**

In `ReadAloudController`:

- Create the coordinator when `startReader` creates the Readium synthesizer.
- In the delegate’s `.playing` case, call `update` with the active publication, utterance, and current `pickerInitial` settings.
- Stop and clear the coordinator in `stopCurrentPlayback`.
- Restart the look-ahead window after `applySettings` when an utterance is active.
- Keep `PublicationSpeechSynthesizer.start`, `next`, `previous`, pause, and resume unchanged.

- [x] **Step 4: Run focused tests and build**

Run:

```bash
xcodebuild -quiet -project rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Expected: exit 0. The controller test may require the existing test-target setup; report any unrelated target failure separately.

- [ ] **Step 5: Commit**

```bash
git add rishi/rishi/Audio/ReadAloudController.swift rishi/rishiTests/ReadAloudControllerTests.swift
git commit -m "feat(reader): prefetch Readium paragraphs"
```

### Task 4: Final verification

**Files:**
- Verify: `docs/superpowers/specs/2026-07-12-readium-tts-prefetch-design.md`
- Verify: all files changed by Tasks 1–3

- [x] **Step 1: Run formatting and repository checks**

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors and only intentional changes.

- [x] **Step 2: Run the final iOS build**

```bash
xcodebuild -quiet -project rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Expected: exit 0.

- [ ] **Step 3: Commit verification if needed**

If Task 4 changes no files, do not create an empty commit. Report the verified commit hashes and any environment-blocked tests.
