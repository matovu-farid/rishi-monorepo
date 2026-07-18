# TTS Skip Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Readium TTS from advancing past an utterance that did not actually play — by making `speak` completion depend on an **engine-owned** finish/fail signal that requires a real `didStart`, not shared `TTSPlaybackState` dual-written by `PublicationSpeechSynthesizer`.

**Architecture:** Extend `TTSPlaying` with `waitUntilFinished() async throws`. `ChunkedAudioPlayerTTSEngine` stores a per-generation pending `Result<Void, Error>?` plus an optional waiter continuation so finish-before-wait and wait-before-finish both work. Success is resumed **only** if `didStart` fired for that generation; otherwise failure. `CustomTTSEngine` awaits `waitUntilFinished()` after each `start` and **deletes** status polling. `ReadAloudController` may keep writing `ttsState` for UI; speak must ignore it.

**Tech Stack:** Swift 6, Swift Testing, `TTSPlaying`, `ChunkedAudioPlayerTTSEngine`, `FakeTTSEngine`, `CustomTTSEngine`, Readium `PublicationSpeechSynthesizer`.

## Global Constraints

- This plan fixes the **remaining dual-writer skip**. Do not substitute `2026-07-19-tts-oversize-sentence-chunk-mode.md` (observability-only).
- **Must-have scope = Tasks 1–2 only.** Optional hardening (≤4000 pathological tokens, extra empty-stream counter) is Appendix A — do not block skip fix on it.
- Do not change `CustomTTSTokenizer` or worker `TTS_MAX_CHARS_PER_REQUEST` (already 4000).
- Prefer `swift test --package-path apps/apple/Packages/RishiAudio`. Do not run full `xcodebuild rishi` from a subagent; main session may build the app.
- Stay under `apps/apple/Packages/RishiAudio/` and `apps/apple/rishi/`. No emojis. Commits only if the user asks.

## Remaining skip (code-proven)

```
play(utterance)
  → synthesizer state = .playing          // before audio
  → ReadAloudController stamps ttsState = .playing
  → CustomTTSEngine.waitForPlaybackToFinish sees .playing
       → sawEnginePlaying = true          // FALSE confidence
  → engine didFinish without didStart (empty / failed-as-complete)
  → ttsState = .stopped
  → waiter returns success
  → speak .success → playNextUtterance    // SKIP
```

Key sites:

- `ReadAloudController.swift` — synthesizer `.playing` → `ttsState.update(.playing)`
- `CustomTTSEngine.swift` — `waitForPlaybackToFinish` trusts shared `.playing`
- `PublicationSpeechSynthesizer.play` — `.success` → `playNextUtterance(.forward)`

The “ended during loading without playing” guard does **not** help once synthesizer already stamped `.playing`.

## File Structure

| File | Role |
|------|------|
| `Packages/RishiAudio/.../TTSPlaying.swift` | Add `waitUntilFinished()` |
| `Packages/RishiAudio/.../ChunkedAudioPlayerTTSEngine.swift` | Pending result + continuation; require `didStart` for success |
| `Packages/RishiAudio/.../TTSEngine.swift` | Conform (legacy path) |
| `Packages/RishiAudio/.../FakeTTSEngine.swift` | Conform; drive waiter from scripts |
| `Packages/RishiAudio/Tests/.../TTSPlayingCompletionTests.swift` | **Create** |
| `rishi/rishi/Audio/CustomTTSEngine.swift` | Await waiter; delete status poll |
| `rishi/rishiTests/Audio/CustomTTSEngineTests.swift` | Update doubles; dual-writer regression |

---

### Task 1: Engine-owned `waitUntilFinished`

**Files:**
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSPlaying.swift`
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/ChunkedAudioPlayerTTSEngine.swift`
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift`
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/FakeTTSEngine.swift`
- Create: `apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/TTSPlayingCompletionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol TTSPlaying: Sendable {
      func start(request: TTSStreamRequest) async
      func pause() async
      func resume() async
      func stop() async
      /// Waits until the latest `start` completes successfully or fails.
      /// - Success only if playback actually started (`didStart`) then finished.
      /// - Throws on failure, stop, or finish-without-start.
      /// - Safe if finish happens before this call (pending result).
      func waitUntilFinished() async throws
  }
  ```

**Completion state machine (required — do not improvise):**

Per `playbackGeneration` on `ChunkedAudioPlayerTTSEngine`:

```swift
private var playbackGeneration = 0
private var didStartForGeneration = 0
private var pendingResult: Result<Void, Error>?   // set when finish/fail/stop settles
private var waiter: CheckedContinuation<Void, Error>?
```

Rules:

1. `start` begins: `playbackGeneration += 1`; clear `pendingResult`; `failWaiterIfAny(superseded)`; reset `didStartForGeneration` tracking for new gen.
2. `markPlaying(generation)`: if `generation == playbackGeneration`, set `didStartForGeneration = generation`, update UI status `.playing`.
3. Successful finish (`handlePlaybackFinished` non-failed):  
   - if `didStartForGeneration == generation` → `settle(.success(()))`  
   - else → `settle(.failure(TTSEnginePlaybackError.finishedWithoutPlaying))`
4. Failed finish / `markFailed` → `settle(.failure(...))`
5. `stop()` → `settle(.failure(CancellationError()))` or dedicated `stopped` error (must not hang waiters)
6. `settle(_ result)`:
   - if `waiter != nil` → resume it once, clear waiter, clear pending  
   - else → store `pendingResult = result` (finish-before-wait)
7. `waitUntilFinished()`:
   - if `pendingResult != nil` → throw/return it immediately and clear  
   - else → `withCheckedThrowingContinuation` store as `waiter` (assert previous waiter nil or fail it)

Never double-resume. All mutations on the engine actor.

- [ ] **Step 1: Write failing Fake tests**

Create `TTSPlayingCompletionTests.swift`:

```swift
import Testing
@testable import RishiAudio

@Suite("TTSPlaying waitUntilFinished")
struct TTSPlayingCompletionTests {
    @Test("waitUntilFinished succeeds after .normal script (loading→playing→stopped)")
    func waitSucceedsOnNormal() async throws {
        let state = await MainActor.run { TTSPlaybackState() }
        let engine = FakeTTSEngine(state: state, script: .normal)
        await engine.start(
            request: TTSStreamRequest(text: "hi", voice: "ash", speed: 1.0)
        )
        try await engine.waitUntilFinished()
    }

    @Test("waitUntilFinished throws on .error script")
    func waitThrowsOnError() async {
        let state = await MainActor.run { TTSPlaybackState() }
        let engine = FakeTTSEngine(state: state, script: .error)
        await engine.start(
            request: TTSStreamRequest(text: "x", voice: "ash", speed: 1.0)
        )
        await #expect(throws: (any Error).self) {
            try await engine.waitUntilFinished()
        }
    }

    @Test("waitUntilFinished throws on .prewarmedFast (stopped without playing)")
    func waitThrowsOnPrewarmedFast() async {
        // .prewarmedFast jumps to .stopped with no .playing — must NOT count as success.
        let state = await MainActor.run { TTSPlaybackState() }
        let engine = FakeTTSEngine(state: state, script: .prewarmedFast)
        await engine.start(
            request: TTSStreamRequest(text: "cached", voice: "ash", speed: 1.0)
        )
        await #expect(throws: (any Error).self) {
            try await engine.waitUntilFinished()
        }
    }
}
```

**Do not** use `.prewarmedFast` as the success case.

- [ ] **Step 2: Run tests — expect compile/link failure**

```bash
swift test --package-path apps/apple/Packages/RishiAudio --filter TTSPlayingCompletion
```

Expected: `waitUntilFinished` missing on `TTSPlaying` / conformers.

- [ ] **Step 3: Implement protocol + Fake + Chunked engine**

**`TTSPlaying.swift`** — add `func waitUntilFinished() async throws`.

**`FakeTTSEngine`:** After applying each script in `start`, call internal `settleWaiter`:

| Script | `waitUntilFinished` |
|--------|---------------------|
| `.normal` | success (had playing) |
| `.error` | throw |
| `.prewarmedFast` | throw `finishedWithoutPlaying` |
| `.holds` | do not settle until `stop()` (then throw/cancel) |

Implement the same pending-result / continuation pattern as production (can be a small private helper on the fake).

**`ChunkedAudioPlayerTTSEngine`:** Implement state machine above; wire `handlePlaybackFinished` / `markFailed` / `stop` through `settle`. Keep updating `TTSPlaybackState` for UI (loading/playing/stopped/error) — that is fine; waiters must not poll it.

**`TTSEngine` (legacy):** Implement `waitUntilFinished` by observing its own completion path (buffer final / error) with the same pending-result pattern, or a simple status loop **only inside TTSEngine** that does not share synthesizer stamps (legacy is not the EPUB production path; prefer minimal compile-correct implementation that succeeds after its natural stop and fails on error).

- [ ] **Step 4: Re-run package tests**

```bash
swift test --package-path apps/apple/Packages/RishiAudio --filter TTSPlayingCompletion
```

Expected: PASS.

Also run existing Fake/bridge-related suites if quick:

```bash
swift test --package-path apps/apple/Packages/RishiAudio --filter FakeTTSEngine
```

- [ ] **Step 5: Commit** (only if user asked)

```bash
git add apps/apple/Packages/RishiAudio
git commit -m "$(cat <<'EOF'
Add engine-owned waitUntilFinished requiring real playback start.

EOF
)"
```

---

### Task 2: `CustomTTSEngine` awaits engine completion (delete status poll)

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift`
- Modify: `apps/apple/rishi/rishiTests/Audio/CustomTTSEngineTests.swift`
- Modify (comment only): `apps/apple/rishi/rishi/Audio/ReadAloudController.swift` dual-write NOTE

**Interfaces:**
- Consumes: `player.waitUntilFinished()`
- Deletes: `waitForPlaybackToFinish` polling of `TTSPlaybackState`

- [ ] **Step 1: Update test doubles + add regression**

Update `RecordingTTSPlayer` / `CacheHitRaceTTSPlayer` in `CustomTTSEngineTests.swift` to implement `waitUntilFinished()`:

- `RecordingTTSPlayer`: after loading→playing→stopped in `start`, settle success for waiter.
- `CacheHitRaceTTSPlayer`: `waitUntilFinished` waits until `finishPlayback()` then success (or hang until finish — match existing test timing).

Add:

```swift
private actor FinishWithoutPlayPlayer: TTSPlaying {
    let state: TTSPlaybackState
    init(state: TTSPlaybackState) { self.state = state }

    func start(request: TTSStreamRequest) async {
        // Mimic synthesizer dual-write contamination on shared UI state:
        await MainActor.run {
            state.update(status: .playing) // synthesizer stamp
            state.update(status: .stopped) // empty finish
        }
    }

    func waitUntilFinished() async throws {
        // Engine contract: no didStart → failure (do not inspect state.status)
        throw NSError(
            domain: "TTSEnginePlayback",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "finished without playing"]
        )
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}
}

@Test("speak fails when engine reports finish without play even if ttsState was .playing")
func speakFailsWhenEngineRejectsFinishWithoutPlay() async {
    let state = TTSPlaybackState()
    state.update(status: .playing) // dual-writer already stamped
    let engine = CustomTTSEngine(
        player: FinishWithoutPlayPlayer(state: state),
        state: state,
        settingsStore: InMemoryTTSSettingsStore(),
        userId: UserID(),
        voices: [englishVoice]
    )
    let result = await engine.speak(
        TTSUtterance(
            text: "Must not advance.",
            delay: 0,
            voiceOrLanguage: .left(englishVoice)
        )
    ) { _ in }
    guard case .failure = result else {
        Issue.record("Expected failure so Readium does not playNextUtterance")
        return
    }
}
```

- [ ] **Step 2: Run app tests if feasible; otherwise implement then build**

Known issue: full `rishiTests` may fail unrelated UITest/`TTSPresenceController` compile. Prefer building app + package tests.

- [ ] **Step 3: Replace speak wait path**

In `CustomTTSEngine.speak`, for each piece:

```swift
await player.start(request: request)
try await player.waitUntilFinished()
```

**Delete** `waitForPlaybackToFinish` entirely (no leftover poll).

Keep speak begin/end/piece diagnostic logs.

Update `ReadAloudController` comment to:

```swift
// UI only: synthesizer lifecycle mirrors into ttsState for controls.
// CustomTTSEngine completion uses TTSPlaying.waitUntilFinished — not this field.
ttsState.update(status: .playing)
```

- [ ] **Step 4: Build app**

```bash
cd apps/apple && xcodebuild -project rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,id=EAEEC3B3-C5AB-41B7-AB05-2942AEF6E1CC' build
```

Expected: **BUILD SUCCEEDED** (every `TTSPlaying` conformer implements `waitUntilFinished`).

- [ ] **Step 5: Manual smoke**

1. Read Aloud on EPUB preface; swipe mid page-crossing paragraph.
2. Confirm no jump after paragraph ends.
3. On forced failure (airplane mode mid-utterance): expect pause/error, **not** advance to a later `nth-child`.

- [ ] **Step 6: Commit** (only if user asked)

---

## Appendix A — Optional follow-ups (NOT required for skip)

Do **not** expand Tasks 1–2 into these unless explicitly requested.

### A1. Pathological piece `> 4000`

`ParagraphChunker.hardWordSplit` can emit a single token longer than `maxChars` (`ParagraphChunker.swift`). Today that yields worker `http_400` → speak **failure** → Readium **pauses** (not skip). Optional: stride-split monster tokens and remove `pieces.isEmpty ? [text]` fallback in `CustomTTSEngine.requestPieces`.

### A2. Extra empty-byte counter in `makeAudioStream`

`TTSStreamer` already throws on empty response. Task 1’s finish-without-`didStart` already fails the waiter. Optional belt-and-suspenders only.

### A3. Sentence `chunkMode` observability

See `2026-07-19-tts-oversize-sentence-chunk-mode.md` — observability only; ship after this plan if desired.

---

## Self-Review

1. **Coverage:** Dual-writer success skip → Tasks 1–2. Pending-result hang → Task 1 state machine. Fake script correctness → Task 1 tests. Status poll removal → Task 2.
2. **Demoted:** ≤4000 / empty counter / chunkMode → Appendix A.
3. **Consistency:** Single completion API `waitUntilFinished()`; success requires real start; Fake `.normal` / `.error` / `.prewarmedFast` roles are explicit.

## Disposition (from adversarial review)

Execute **Tasks 1–2 only**. Treat Appendix A as separate PRs. Do not execute the sentence-chunk-mode plan as a skip fix.
