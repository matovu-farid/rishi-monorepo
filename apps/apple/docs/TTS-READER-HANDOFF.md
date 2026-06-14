# TTS / Read-Aloud Reader — Session Handoff

Hand this whole file to a fresh session. It captures the full state of the
read-aloud (TTS) work, the next primary task (an `AudioSessionPolicy`
extraction), and **all** remaining work.

---

## 0. How to work in this repo (read first)

From `apps/apple/CLAUDE.md` and repo `CLAUDE.md`:

- **Build-first rule.** Before any review/audit, confirm the build is green; a
  broken build is finding #1.
- **Never run `xcodebuild rishi` in a subagent** (600s watchdog kills agents).
  Subagents verify with:
  - `swift test --package-path apps/apple/Packages/<Pkg>` per touched package.
  - `xcrun --sdk iphonesimulator swiftc -typecheck <file>` for app-target files
    under `apps/apple/rishi/` (these aren't in a SwiftPM package).
  - The **main orchestrator** runs the full `xcodebuild` on the **iPhone 17**
    simulator as the end gate:
    `xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/<Suite>`
- **Commit scope:** only under `apps/apple/Packages/`, `apps/apple/rishi/`,
  `apps/apple/scripts/`, `apps/apple/fastlane/`, `apps/apple/docs/`. **Never**
  commit `.planning/` (gitignored) or `apps/mobile/` (a large unrelated set of
  deletions sits uncommitted in the tree — leave it).
- **Swift Testing only** (not XCTest). **No emojis.** Default-isolation =
  MainActor stays the project default.
- **TDD is mandatory**, including for debugging: write a failing test that
  *reproduces* the bug first, watch it fail, then fix. Assert
  **completeness/correctness**, never mere non-emptiness (`> 0`, "not nil").
  Vary input shape (whole vs sliced) for streaming code.

---

## 1. The big architectural lesson (why the next task exists)

Every TTS bug this session was a **policy** bug. The ones TDD caught were caught
because we extracted the policy into a **pure, unit-tested decision**:

| Bug | Pure seam that catches it |
|-----|---------------------------|
| Decoder truncated to ~200ms | `MP3StreamDecoderCompletenessTests` (assert full-duration + slicing-invariance) |
| `isFinal` on a 0-frame buffer | decoder "terminal chunk carries audio" test |
| Adapter finished its stream before buffers rendered | `PlaybackCompletionAccountant` (pure reducer) |
| Advance-watcher race / index crash | `repeatCurrent` test |
| Bluetooth `-50` (HFP on playback) | `bluetoothRouting()` pure rule |

The **one bug TDD missed** — next/prev plays silently on device — missed because
(a) the audio-**session** policy was entangled across `bridge.jump → engine.stop
→ coordinator.releaseActiveMode`, with no single place to assert "a switch must
not churn the session", and (b) the *consequence* (churn loses the route) is
device-only and our fakes don't model it.

**Principle: separate policy (pure, testable) from mechanism (device, thin).**
The session is the last lifecycle piece not yet extracted. Extracting it makes
the bug a one-line unit test and retro-covers the `-50` bug under one tested
lifecycle.

---

## 2. PRIMARY NEXT TASK — extract `AudioSessionPolicy` (TDD)

**Goal:** model the audio session as a pure reducer so all session *decisions*
are unit-tested; the `AudioSessionCoordinator` becomes a thin actor that only
*applies* effects to the real `AVAudioSession`. This supersedes the quick fix in
§4 (keep behaviour identical, just make it tested + centralized).

**Files:**
- `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift`
  (actor: holds `ActiveMode` .idle/.tts/.voice; calls `configurator.configure` /
  `setActive`). This is where the churn lives today: `releaseActiveMode(.tts)` →
  `setActive(false)`, `requestActiveMode(.tts)` → `configure + setActive(true)`.
- `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionConfigurator.swift`
  (protocol `AudioSessionConfigurator`; `AVAudioSessionConfigurator` iOS impl;
  `FakeAudioSessionConfigurator` records `configureCalls` + `activeCalls`).
  Already contains the extracted pure `bluetoothRouting(category:options:)` +
  `BluetoothRouting` enum (tested in `AudioSessionBluetoothRoutingTests`).

**Design (mirror `PlaybackCompletionAccountant`):**

```swift
enum AudioSessionEvent { case beginPassage, switchPassage, endPlayback,
                              beginVoice, endVoice, interrupted, resume }
enum AudioSessionEffect: Equatable {
    case configure(category: AudioSessionCategory, mode: AudioSessionMode, options: AudioSessionOptions)
    case activate
    case deactivate(notifyOthers: Bool)
}
struct AudioSessionPolicy {
    private(set) var mode: ActiveMode = .idle
    mutating func reduce(_ event: AudioSessionEvent) -> [AudioSessionEffect]
}
```

**Invariants to assert in `AudioSessionPolicyTests` (RED first):**
- `reduce(.beginPassage)` from idle → `[.configure(.playback,.spokenAudio,…), .activate]`.
- `reduce(.switchPassage)` while tts-active → `[]` (NO `.deactivate`, NO
  reconfigure). **This is the bug-catching invariant.**
- `reduce(.endPlayback)` → `[.deactivate(notifyOthers: true)]`.
- voice transitions tear down tts first, etc. (port current behaviour).

**Then:** `AudioSessionCoordinator` calls `policy.reduce(event)` and applies the
effects via the configurator. Replace `requestActiveMode`/`releaseActiveMode`
call sites in `TTSEngine` with the event vocabulary:
- `TTSEngine.start()` for a fresh session → `.beginPassage`.
- A passage **switch** (next/prev/repeat) must map to `.switchPassage` (no
  churn). Today `TTSEngine.start()` is called for both fresh start and switch —
  you may need the bridge/engine to distinguish "switch" from "fresh start"
  (e.g. a `switchPassage(request:)` entry that skips re-activation), or have the
  coordinator treat "request .tts while already .tts" as `.switchPassage`.
- `TTSEngine.stop()` → `.endPlayback`.

**Second lever (optional but recommended):** make `FakeAudioSessionConfigurator`
*high-fidelity* — model the known device gotcha so an integration test catches
the class pre-device: after `setActive(false)` immediately followed by
`setActive(true)`, expose `routeIsActive == false` (or record the churn) so a
full-flow test can assert "a passage switch never produces an inactive route."

**Acceptance:** all session decisions unit-tested with no device; the
`switchPassage`-no-churn invariant is locked; existing behaviour for fresh
start / stop / voice unchanged; full `xcodebuild` green on iPhone 17.

---

## 3. Committed work this session (all on `main`)

| Commit | What | Verified |
|--------|------|----------|
| `ac50522fc` | Decoder decodes the **full** MP3 stream (was ~200ms "first word") | host tests + device |
| `094b0d69f` | A2DP (not HFP) bluetooth for playback → kills `audio.session.mode.failed -50` | host rule test |
| `9281816d2` | Terminal playback completion → **auto-advance works** | **device-confirmed** |
| `7d4edf269` | `ReaderTTSBridge.next()/previous()` + tests | host |
| `c37eeffaf` | Made flaky 29-03 advance/page-nav tests robust | host |
| `196e2985b` | `repeatCurrent()` + **advance-watcher race / index-crash fix** | host |
| `af53d1a56` | **WIP snapshot**: bug-4 page-follow, player buttons, RootView wiring, + pre-existing reader/PDF/footer WIP | builds |
| `bc3a28a42` | Declutter player (icon-only "Voice & Speed", tighter row) + stop→start contract test | builds + device looks good |

**`af53d1a56` caveat:** `apps/apple/rishi/rishi/RootView.swift` carried ~200
lines of **pre-existing uncommitted** read-aloud-UI WIP (overlay refactor,
passage wiring) that were swept into that WIP commit. Not individually reviewed.
Flag to the user if touching RootView.

---

## 4. Uncommitted in the tree RIGHT NOW (the session-churn quick fix)

The orchestrator was committing this when the handoff was written. If not yet
committed, commit it (verify `swift test --package-path
apps/apple/Packages/RishiAudio` first, then `xcodebuild` the bridge suites):

- `AudioEngineProtocol.swift` — added offline-render **test seam** to
  `AVAudioEngineAdapter`: `enableOfflineRendering`, `renderOffline`,
  `manualRenderingFormat`.
- `TTSEngine.swift` — `start()` now calls `engine.stop()` (halts old player node)
  right after `teardown()`, so a passage switch stops old audio **without
  releasing the session**.
- `ReaderTTSBridge.swift` — `jump()` **no longer calls `engine.stop()`** (which
  released the session). Relies on `engine.start()`'s single-session teardown.
- `ReaderTTSBridgeNextPrevTests.swift` — `nextDoesNotStopEngine` contract test
  (RED on the old code; asserts a switch issues no full engine stop).
- `AVAudioEngineAdapterRenderTests.swift` (untracked) — drives the **real**
  `AVAudioEngine` via offline rendering through mid-stream-stop → re-play and
  asserts non-silent output. Proves the adapter itself is correct (eliminated it
  as the cause). Keep as a regression test.

**This quick fix is a hypothesis-driven fix for the next/prev silence** (the
session deactivate→immediate-reactivate route loss). It is **NOT device-verified
yet.** The §2 `AudioSessionPolicy` refactor is the principled version and should
supersede it — but keep the fix until the refactor lands so device testing isn't
blocked.

---

## 5. ALL remaining work

### Read-aloud (TTS) — finish these
1. **AudioSessionPolicy extraction (§2)** — primary next task.
2. **Device-verify the next/prev/repeat silence fix** (§4 / §2). Symptom was:
   pressing next/prev → audio stops, UI shows "Playing", no sound. Expected:
   the new paragraph plays. If still silent, capture device logs on tap —
   specifically whether `audio.session.mode.failed` and `tts.engine.first_buffer`
   fire (existing `Log.event` instrumentation).
3. **Bug 2 — manual page-turn doesn't reset TTS.** `EPUBReaderViewModel`
   `didChangeLocation` (≈ line 194, `Packages/RishiReader/.../EPUB/EPUBReaderViewModel.swift`)
   updates `latestLocator` but never tells the bridge to stop/reload, so audio
   from the old page keeps playing when the user manually pages. Wire a
   locator-change → `bridge.stop()` (or reload paragraphs for the new resource).
   Watch for a feedback loop with **bug-4 auto-follow** (which navigates the view
   *to* the audio): manual nav should win and stop TTS.
4. **Bug 3 — two reader sessions can play at once (singleton).** `ttsEngine` and
   `ttsState` are **app-singletons** built once in `AppDependencies`
   (`buildServices` / `makeReaderTTSBridge`) and shared by every
   `ReaderTTSBridge`. Overlapping starts can double-play. The jump race fix
   (`196e2985b`) and the session fix likely reduced it — **verify**, then enforce
   single active session (one bridge, guard concurrent starts). Add a test: two
   bridges over one engine must not interleave passages.
5. **Bug 4 — device-verify** the view-follows-audio / auto page-turn (committed
   in `af53d1a56`: `EPUBNavigatorCoordinator.navigateToReadAloudParagraph` +
   `EPUBReaderScreen.applyReadAloudHighlight` wiring). User confirmed auto-play
   page-change works; re-confirm after the session refactor and watch for
   re-centering jank on every paragraph.
6. **Feature 5 — device-verify** prev/repeat/next buttons actually move audio +
   turn pages at boundaries. UI committed; bridge `next/previous/repeatCurrent`
   committed. Cross-**resource** (chapter) boundary is a deferred edge:
   `paragraphsForReadAloud()` spans one Readium resource; next at the very end
   currently clamps (no load-next-chapter).

### Separate initiative
7. **Task 6 — remove the bottom tab bar app-wide + restyle the reader with native
   Apple components + Liquid Glass.** User decision: **remove tab bar entirely**
   (they have other navigation). Then make the reader chrome use built-in
   SwiftUI components adopting the iOS 26 **Liquid Glass** look the current
   bottom bar already has. First: confirm the iOS deployment target / SDK
   supports Liquid Glass, and inspect the current tab bar (`RootView.swift`).
   Design-heavy; aligns with Phase 18/19/20 native-SwiftUI direction. Needs
   device iteration. Propose the replacement navigation before deleting the bar.

### Hygiene / known issues
8. **Flaky test:** `CachingTTSChunkSourceTests` "cancelled stream leaves no .mp3
   and next call is a miss" fails in the full RishiAudio run but **passes in
   isolation** (cancellation/filesystem timing race). Not caused by this work.
   Worth hardening (it's about a cancelled stream leaving a `.partial`/`.mp3`).
9. **RootView WIP** (see §3 caveat) — ~200 lines of pre-existing read-aloud UI
   were committed in `af53d1a56`; surface to the user if it matters.

---

## 6. Key files & seams (map)

- **Bridge (app target):** `apps/apple/rishi/rishi/Audio/ReaderTTSBridge.swift`
  — `@MainActor`. `start/stop/pause/resume/jump/next/previous/repeatCurrent`,
  `AdvanceWatcherDecision` (pure, tested), `startAdvanceWatcher` (100ms poll),
  `playCurrent`, `advance`. Holds `any TTSPlaying`.
- **Engine (RishiAudio):** `Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift`
  — actor. `streamer → decoder → AudioEngineProtocol`. Single-session.
- **Adapter:** `.../TTS/AudioEngineProtocol.swift` — `AudioEngineProtocol`,
  `AVAudioEngineAdapter` (real, iOS/macOS), `FakeAudioEngine`,
  `PlaybackCompletionAccountant` (pure, tested), offline-render test seam.
- **Decoder:** `.../TTS/MP3StreamDecoder.swift` (+ `CompressedBufferSizing.swift`
  pure/tested). One-chunk lookahead so the terminal chunk carries audio.
- **Session:** `.../Coordinator/AudioSessionCoordinator.swift` +
  `AudioSessionConfigurator.swift` (`bluetoothRouting` pure/tested). **← §2 work.**
- **Fakes / harness:** `FakeTTSEngine` (scripts: `.normal/.prewarmedFast/.error/.holds`),
  `FakeAudioEngine`, `FakeAudioSessionConfigurator`, `FakeTTSChunkSource`.
  Bridge test harness: `rishi/rishiTests/Audio/ReaderTTSBridgeAdvanceTests.swift`
  (`makeBridge`, `waitUntil`, `PassageChangeRecorder`).
- **EPUB read-aloud:** `rishi/rishi/Audio/EPUBReaderTTSExtension.swift`
  (`paragraphsForReadAloud()` — spans one resource),
  `Packages/RishiReader/.../EPUB/EPUBNavigatorCoordinator.swift`
  (`navigateToReadAloudParagraph`, `highlightReadAloudParagraph`, `go(to:)`),
  `EPUBReadAloudDecorationBuilder.locator(forParagraph:href:mediaType:)` (tested),
  `Packages/RishiReader/.../UI/EPUBReaderScreen.swift` (`applyReadAloudHighlight`).
- **Player UI:** `Packages/RishiAudio/Sources/RishiAudio/UI/ReadAloudControlsView.swift`
  (play/pause, stop, prev, repeat, next, settings-icon). Wired in
  `rishi/rishi/RootView.swift` `readAloudControlsOverlay` (≈ line 892).

## 7. Verify commands

```bash
# package suites (fast)
swift test --package-path apps/apple/Packages/RishiAudio
swift test --package-path apps/apple/Packages/RishiCore
# app-target bridge suites (orchestrator only — NOT in a subagent)
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/ReaderTTSBridgeNextPrevTests \
  -only-testing:rishiTests/ReaderTTSBridgeAdvanceTests \
  -only-testing:rishiTests/ReaderTTSBridgePageNavTests
# full integrated build gate
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Known-flaky in the full RishiAudio run: `CachingTTSChunkSource "cancelled
stream…"` (passes alone). The bridge suites had a latent flake (now fixed in
`c37eeffaf`): `start()` fires `onPassageChange(nil)` immediately, so wait on real
forwarded passage indices, never on `sawTeardown`/bare event counts.
