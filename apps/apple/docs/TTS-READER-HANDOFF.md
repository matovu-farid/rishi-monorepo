# TTS / Read-Aloud Reader — Session Handoff (2026-06-15)

Hand this whole file to a fresh session. The hard bug is FIXED and
device-confirmed by the user ("It works."). What remains is small cleanup plus
some previously-deferred items.

---

## 0. TL;DR

- **Read-aloud next/previous paragraph now works on device** (user confirmed).
- Root cause was a **lock-ordering deadlock** in `AVAudioEngineAdapter`, fixed in
  commit `c8ff9b9a8`. See §2.
- The **XCUITest now passes and is stable** (`5b36fa8ee`) — it drives the real
  `AVAudioEngine` on the simulator (no fake can hit the deadlock). The cleanup
  tasks in §3 are DONE; remaining work is the deferred items in §4.
- Debug breadcrumbs stripped (`2948b80d2`).

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

## 3. CLEANUP — DONE (`2948b80d2`, `5b36fa8ee`)

### 3.1 XCUITest — DONE & stable (`5b36fa8ee`)
File: `apps/apple/rishi/rishiUITests/ReadAloudNextParagraphUITests.swift`.
Passes on `name=iPhone 17` (ran green twice; ~23–31s). Three blockers were
fixed — the handoff's "1-line selector fix" was wrong; it took real infra:
- Assert on the `tts-pause`/`tts-play` TOGGLE button, not the `tts-status`
  Text (XCUITest cannot read the Text's value).
- Pin the reader chrome visible under `RISHI_UITEST` — it auto-hides after 4s,
  removing the Read Aloud toolbar button mid-test
  (`EPUBReaderScreen` passes a large `autoHideDelay`).
- Hide Readium's WKWebView accessibility at the UIKit level under
  `RISHI_UITEST` (`EPUBReaderView`: `navigator.view.accessibilityElementsHidden`).
  A SwiftUI `.accessibilityHidden` does NOT reach the web-content process; its
  Link/StaticText nodes abort XCUITest's app snapshot and make the SwiftUI
  controls unqueryable.
- The book opens on the cover (no paragraphs) so the test turns pages until a
  session starts; a page-turn's user-nav callback is delayed and can stop the
  fresh session, so the test drains each turn and restarts once if a straggler
  slips through. Investigation (live os_log capture) CONFIRMED the app's
  programmatic-nav suppression for auto-follow page turns works correctly — the
  stop was a test-side race, not Bug 4.
Run: `xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiUITests/ReadAloudNextParagraphUITests`.
(See `reference_apple_uitest_bypass` memory for the XCUITest gotchas.)

### 3.2 Strip debug breadcrumbs — DONE (`2948b80d2`)
Removed the `tts.bridge.jump*`/`play_current`, `tts.engine.start.*`,
`tts.adapter.reset.*` breadcrumbs (+ now-unused `RishiLogging` imports). Kept
the deadlock fix/comment and the production `tts.engine.first_buffer`,
`tts.stream.*`, `audio.session.mode*` events.

### 3.3 The UI-test bypass scaffolding — KEPT
`rishi/rishi/UITestSupport.swift` (+ `Resources/uitest-tts.mp3`, the `RISHI_UITEST`
wiring in `AppDependencies`, the `EPUBReaderScreen` chrome-visible flag, the
`RootView` entitlement bypass) are all `#if DEBUG` + env-gated, so they never
ship. Keep them — they power the regression UI test. The `tts-status` /
`library-book-cell` accessibilityIdentifiers are harmless to keep.

---

## 4. PREVIOUSLY-DEFERRED WORK (not started)

- **Bug 3 (double-play)** — RESOLVED BY ANALYSIS (not reachable: one visible reader; `RootView.startReadAloud` stops the old bridge first; `TTSEngine` actor serialises). No code change.
- **Device-verify**: view-follows-audio across page boundaries (Bug 4); prev/repeat/next at page boundaries (Feature 5). User confirmed next/prev audio works now; re-confirm page-following. NOTE: the §3.1 UI-test investigation (live os_log) showed the auto-follow programmatic-nav suppression works on the simulator — 4 consecutive `navigateToReadAloudParagraph` page turns each held `isProgrammaticNavigation` correctly and fired NO spurious `onUserNavigation`. So Bug 4 is largely de-risked; device re-confirm is the only open part.
- **Task 6 — DONE (`49afaa0df`).** iPhone (compact) bottom tab bar removed: Library is the single home with a "Chats" toolbar button (`library.toolbar.chats`) that pushes the conversations list onto Library's NavigationStack (`ConversationsRoute`). iPad/Mac keep the `NavigationSplitView` sidebar (so `selectedTab`/menu commands stay valid there). Read-aloud controls card restyled to iOS 26 Liquid Glass (`GlassCardBackground`, `#available(iOS 26)` + `.regularMaterial` fallback; deployment target is iOS 18). Guarded by `LibraryNavigationUITests`. OPEN follow-ups if wanted: remove the iPad/Mac sidebar too (currently kept); extend Liquid Glass to the progress indicator / TOC sheet; device-iterate the reader visuals.
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
