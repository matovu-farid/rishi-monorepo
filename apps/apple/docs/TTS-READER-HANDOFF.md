# TTS / Read-Aloud Reader — Session Handoff (2026-06-15)

Hand this whole file to a fresh session. The hard bug is FIXED and
device-confirmed by the user ("It works."). What remains is small cleanup plus
some previously-deferred items.

---

## 0. TL;DR

- **Read-aloud next/previous paragraph now works on device** (user confirmed).
- Root cause was a **lock-ordering deadlock** in `AVAudioEngineAdapter`, fixed in
  commit `c8ff9b9a8`. See §2.
- An **XCUITest that reproduces it on the simulator** was built (the real
  `AVAudioEngine` path — no fake can hit the deadlock). It reaches the reader +
  starts read-aloud but its FINAL assertion needs a 1-line selector fix (§3.1).
- Two cleanup tasks remain (§3) + deferred items (§4).

---

## 1. How to work in this repo (read first)

From repo `CLAUDE.md` and `apps/apple/CLAUDE.md`:

- **Build-first** before any review/audit. Broken build is finding #1.
- **Subagents must NOT run `xcodebuild rishi`** (600s watchdog kills agents).
  - Per-package: `swift test --package-path apps/apple/Packages/<Pkg>`.
  - App-target files: `xcrun --sdk iphonesimulator swiftc -typecheck <file>` (unreliable with many deps; prefer the orchestrator gate).
  - **RishiReader cannot `swift test` on macOS** (Readium is iOS-only → dependency-resolution fatalError). Verify it via the iPhone 17 `xcodebuild` gate.
  - The MAIN orchestrator runs the iPhone 17 `xcodebuild` as the end gate.
- **Destination:** `platform=iOS Simulator,name=iPhone 17`.
- **Commit scope:** only `apps/apple/{Packages,rishi,scripts,fastlane,docs}`. NEVER commit `.planning/` (gitignored) or `apps/mobile/` (large unrelated uncommitted deletions sit in the tree — leave them).
- **Swift Testing** for unit tests; **XCTest only for the XCUITest** (`XCUIApplication` requires it). **No emojis.** Default-isolation = MainActor stays.
- **TDD / debug-via-failing-test:** reproduce with a failing test FIRST, watch it fail, then fix. Assert completeness, not non-emptiness. The user enforces "revert, watch it fail, apply, watch it pass."

---

## 2. THE FIX (committed `c8ff9b9a8`) — the deadlock

`AVAudioEngineAdapter.resetPlayerNode()` and `stop()` (in
`Packages/RishiAudio/Sources/RishiAudio/TTS/AudioEngineProtocol.swift`) called
`playerNode.stop()` / `engine.stop()` **while holding the adapter's `lock`**.
`playerNode.stop()` blocks until the audio render thread drains; the buffer
completion handlers in `play(_:)` run on that render thread and acquire the
**same `lock`** (`box.value.didComplete()`). Classic lock-ordering deadlock →
the read-aloud player latched on "Loading…" on a passage switch.

Invisible to every unit test because `FakeAudioEngine` has no real render thread
firing completion handlers. **Only a UI test on the real `AVAudioEngine`
reproduces it.**

Fix: call `playerNode.stop()/reset()` and `engine.stop()` OUTSIDE the lock (the
lock only needs to guard the `PlaybackCompletionAccountant` box; those
AVFoundation calls are internally thread-safe).

### How we got here (earlier fixes this session, all still valid + committed)
- `d8a5a9881` — Bug: Play started from page 1, not the current page. Fixed via pure `ParagraphChunker.startIndex(forProgression:count:)` + locator-aware `EPUBReaderViewModel.paragraphsForReadAloud()`.
- `f63735900` — **Long-lived AVAudioEngine**: the engine is brought up ONCE per read-aloud session and only the player node is reset per passage (`resetPlayerNode()`), never stop/attach/start. `onBufferComplete(isFinal)` no longer stops the engine/session (only sets `.stopped`). This was necessary groundwork but exposed the deadlock above. `ReaderTTSBridge.jump()` no longer calls `engine.stop()`.
- Superseded interim attempts (kept in history, do not revert): `796565d43`, `9a04ac434` (AudioSessionPolicy reducer — still in use), `cdeac0cc1`.
- `9dd3d63b9` — manual page-turn stops stale read-aloud (`EPUBReaderViewModel.onUserNavigation` + coordinator `isProgrammaticNavigation` flag).

---

## 3. REMAINING CLEANUP (small, do these first)

### 3.1 Finish the XCUITest (make it green = permanent regression guard)
File: `apps/apple/rishi/rishiUITests/ReadAloudNextParagraphUITests.swift`
(currently has ONE UNCOMMITTED diagnostic change — a hierarchy XCTAttachment).

The test launches with `RISHI_UITEST=1`, opens the sample book (alice), taps
Read Aloud, and should assert playback returns to "Playing" after Next. It now
gets all the way into the reader and starts read-aloud, but the FINAL step asserts
on the `tts-status` `Text` element, which XCUITest does not expose as queryable.
**Fix:** assert on the player BUTTONS instead — wait for `tts-play`/`tts-pause`
or `tts-next-paragraph` to exist (the hierarchy DOES expose those), tap
`tts-next-paragraph`, and assert the controls are still present / not stuck.
The controls overlay IS appearing (hierarchy showed a bottom element at
`{{0,726},{402,148}}`); only the status-Text selector fails.
Run: `xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiUITests/ReadAloudNextParagraphUITests -resultBundlePath /tmp/ui.xcresult` then
`xcrun xcresulttool get test-results summary --path /tmp/ui.xcresult`.
(See `reference_apple_uitest_bypass` memory for all the XCUITest gotchas already solved: scheme membership, coordinate taps, onboarding seed, chrome-visible, entitlement bypass, attachment-based diagnostics.)

### 3.2 Strip the debug breadcrumbs (now that root cause is found)
Remove the `Log.event` debugging breadcrumbs added this session:
- `tts.bridge.jump`, `tts.bridge.jump.clamped`, `tts.bridge.play_current` in `rishi/rishi/Audio/ReaderTTSBridge.swift`.
- `tts.engine.start.enter/.running/.spawned` in `Packages/RishiAudio/.../TTS/TTSEngine.swift`.
- `tts.adapter.reset.enter/.stopped/.done` in `Packages/RishiAudio/.../TTS/AudioEngineProtocol.swift` (KEEP the deadlock fix + comment; just drop the three Log lines).
Keep the production `tts.engine.first_buffer`, `tts.stream.*`, `audio.session.mode*` events.

### 3.3 The UI-test bypass scaffolding — decide whether to keep
`rishi/rishi/UITestSupport.swift` (+ `Resources/uitest-tts.mp3`, the `RISHI_UITEST`
wiring in `AppDependencies`, the `EPUBReaderScreen` chrome-visible flag, the
`RootView` entitlement bypass) are all `#if DEBUG` + env-gated, so they never
ship. Keep them — they power the regression UI test. The `tts-status` /
`library-book-cell` accessibilityIdentifiers are harmless to keep.

---

## 4. PREVIOUSLY-DEFERRED WORK (not started)

- **Bug 3 (double-play)** — RESOLVED BY ANALYSIS (not reachable: one visible reader; `RootView.startReadAloud` stops the old bridge first; `TTSEngine` actor serialises). No code change.
- **Device-verify**: view-follows-audio across page boundaries (Bug 4); prev/repeat/next at page boundaries (Feature 5). User confirmed next/prev audio works now; re-confirm page-following.
- **Task 6 — remove the bottom tab bar app-wide + restyle the reader with native SwiftUI / iOS 26 Liquid Glass.** User decision: remove the tab bar entirely (Library/Chats — they have other navigation). Propose the replacement navigation BEFORE deleting. The UI-test hierarchy confirmed the tab bar (`books.vertical`/`bubble.left.and.bubble.right`) still shows even in the reader. Design-heavy; needs device iteration.
- **Auth bypass for real (non-test) dev use** — the user once asked for a general dev/test auth bypass to test on simulators. The `RISHI_UITEST` bypass partially covers this (signed-out + offline). If they want an interactive dev bypass, extend it.
- **Hygiene:** known-flaky `CachingTTSChunkSourceTests "cancelled stream…"` (passes alone, fails in full RishiAudio run). Not caused by this work.

---

## 5. KEY CONTEXT / MAP

- **Property-based testing** is now adopted: `x-sheep/swift-property-based`, wired into RishiCore + RishiReader package test targets and the `rishiTests` xcodeproj target (added via the `xcodeproj` Ruby gem). See `reference_property_based_testing` memory. Pure logic → package `swift test`; stateful → iPhone 17 gate.
- **Audio pipeline:** `ReaderTTSBridge` (app target, `@MainActor`, `start/stop/jump/next/previous/repeatCurrent`, advance watcher) → `TTSEngine` (actor, RishiAudio, long-lived engine) → `AudioEngineProtocol`/`AVAudioEngineAdapter` (+ `FakeAudioEngine`) + `AudioSessionCoordinator`/`AudioSessionPolicy` (pure reducer) + `MP3StreamDecoder` + `TTSPassageTracker` (drives the in-text highlight via `currentPassageId`).
- **Fixtures:** `alice.epub` (shipped sample, auto-seeds on first launch via `SampleBookInstaller`) and `purple-cow.epub` (TEST-ONLY, in `RishiReader/Tests/.../Fixtures`). `alice-p0.mp3` real TTS fixture in `RishiAudio/Tests/.../Fixtures` (and copied to the app bundle as `uitest-tts.mp3`).
- The `-50` (`audio.session.mode.failed`) on device is non-fatal (passage 0 plays); it is the bluetooth/category config and was NOT the next/prev cause. Leave unless it surfaces a real symptom.

## 6. Verify commands
```bash
swift test --package-path apps/apple/Packages/RishiAudio   # 113 tests
swift test --package-path apps/apple/Packages/RishiCore    # incl. property-based startIndex
# iPhone 17 gates (orchestrator only):
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/ReaderTTSBridgeLongLivedEngineTests \
  -only-testing:rishiTests/ReaderTTSBridgeNextPrevTests \
  -only-testing:rishiTests/ReaderTTSBridgeAdvanceTests
xcodebuild test ... -only-testing:RishiReader/... (RishiReaderTests/EPUBReadAloudStartIndexTests) via -scheme RishiReader
xcodebuild test ... -only-testing:rishiUITests/ReadAloudNextParagraphUITests -resultBundlePath /tmp/ui.xcresult
```
