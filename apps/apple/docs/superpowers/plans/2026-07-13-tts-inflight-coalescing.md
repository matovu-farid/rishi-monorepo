# TTS In-Flight Request Coalescing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) to implement this plan task-by-task.

**Goal:** Ensure concurrent identical TTS cache misses share one upstream synthesis while every caller receives the streamed audio.

**Architecture:** Keep completed audio in `TTSAudioCacheStore`. Add a per-cache-key in-flight entry inside `CachingTTSChunkSource`; the first caller produces and writes the audio, while later callers subscribe to the same ordered chunk broadcast. Insert the reservation before any suspension, and remove it only after producer completion/failure/cancellation.

**Tech Stack:** Swift 6 actors, `AsyncThrowingStream`, `Testing`, file-backed MP3 cache.

---

### Task 1: Add the regression test

**Files:**
- Modify: `Packages/RishiAudio/Tests/RishiAudioTests/CachingTTSChunkSourceTests.swift`

- [ ] **Step 1: Add a blocking upstream fixture and test two concurrent identical streams.**

The test must use one real `CachingTTSChunkSource`, start two consumers for the same request before the upstream finishes, wait until both consumers finish, and assert:

```swift
#expect(await upstream.requests().count == 1)
#expect(firstBytes == expectedBytes)
#expect(secondBytes == expectedBytes)
```

The upstream fixture must yield at least one chunk immediately, then suspend until both consumers have subscribed, then finish. This proves the second caller joins an active producer rather than merely benefiting from a completed disk hit.

- [ ] **Step 2: Run only the new test and verify it fails because upstream receives two requests.**

Run:

```bash
swift test --package-path Packages/RishiAudio --filter CachingTTSChunkSourceTests
```

Expected: the new concurrency assertion fails before the production implementation changes.

### Task 2: Implement shared in-flight broadcasting

**Files:**
- Modify: `Packages/RishiAudio/Sources/RishiAudio/TTS/CachingTTSChunkSource.swift`

- [ ] **Step 1: Add actor-owned in-flight state keyed by `TTSCacheKey.compute(...)`.**

Each entry must contain a producer task and subscriber continuations. The first caller reserves the key before any `await`; later callers attach to that entry. Subscriber streams must preserve chunk order and use the request’s cache key for stable chunk IDs.

- [ ] **Step 2: Keep producer lifecycle separate from subscriber cancellation.**

When one subscriber terminates, remove only that subscriber. Cancel the producer and discard its partial file only when no subscribers remain. Producer completion must commit once, finish all subscribers, and remove the same in-flight entry.

- [ ] **Step 3: Preserve existing behavior for hits, empty responses, storage failures, and fail-open paths.**

Completed non-empty files remain disk hits. Empty upstream output must not commit. If partial-file creation/opening fails, use the existing direct-upstream fallback. Do not change prefetch window behavior or cache-key format.

- [ ] **Step 4: Run the focused cache tests and verify green.**

Run:

```bash
swift test --package-path Packages/RishiAudio --filter CachingTTSChunkSourceTests
swift test --package-path Packages/RishiAudio --filter TTSPrewarmerTests
```

### Task 3: Review and broader verification

**Files:**
- Review only the implementation and test diff.

- [ ] **Step 1: Confirm no direct production path bypasses the shared cache when the cache initializes successfully.**
- [ ] **Step 2: Confirm existing sequential-hit, cancellation, empty-response, and concurrent-writer tests remain covered.**
- [ ] **Step 3: Run the complete RishiAudio test suite.**

Run:

```bash
swift test --package-path Packages/RishiAudio
```

- [ ] **Step 4: Run `git diff --check` and report exact test results.**
