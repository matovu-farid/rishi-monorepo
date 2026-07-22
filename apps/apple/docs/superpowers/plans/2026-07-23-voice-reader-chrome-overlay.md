# Voice Reader Chrome Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-screen voice session cover with a draggable pill-shaped reader chrome (matching Read Aloud) so users keep the book visible during back-and-forth voice chat, with smooth TTS ↔ voice transitions and speaking waveform animation.

**Architecture:** Generalize `ReadAloudControlsOverlay` into a mode-aware `ReaderAudioChromeOverlay` in the app target that composes either `ReadAloudControlsView` (RishiAudio) or `VoiceControlsView` (RishiVoice) inside the same pill shell (drag, glass, position). Move voice presentation from `SignedInView.fullScreenCover` to `ReaderDestination.overlay`. Add TTS pause/resume handoff on `ReadAloudController` so voice entry preserves read-aloud position. Drive waveform animation from a new `VoiceActivityPhase` on `VoiceSessionState` (transcript-event derived in v1; optional audio-level reactive upgrade later).

**Tech Stack:** Swift 6, SwiftUI, RishiVoice, RishiAudio, RishiReader, RishiUIKit, Swift Testing.

**Design reference:** Brainstorm decisions from 2026-07-22 session (pill chrome matching TTS, bidirectional handoff, state-driven waveform, hide allowance until `isFinalInterval`, no transcript in chrome, back-and-forth conversations with book visible).

## Global Constraints

- **No CallKit / system call UI** (VOICE-08) — End is a plain SwiftUI button in the pill.
- **Single audio owner** — `AudioSessionCoordinator` invariant unchanged; TTS must pause (not stop) on voice handoff when read-aloud was active.
- **Layering** — RishiReader must not import RishiVoice; chrome composition stays in app target (`rishi/rishi/Reader/`).
- **Allowance copy** — Do not show remaining minutes/credits in chrome unless `VoiceSessionState.isFinalInterval == true` (server `session_ending` / final-interval warning). Then show `"Ending soon"` only — no numeric countdown unless product adds it later.
- **No live transcript in chrome** — Transcripts still persist via `VoiceTranscriptBridge`; UI does not render them in the pill.
- **Optimistic End** — Keep existing `VoiceSessionPresenter.requestEnd()` behavior (instant dismiss, background end delivery).
- **Failure surface** — Keep native `.alert` on `SignedInView` for `VoiceFailureAlert`; do not block the book.
- **iOS build gate** — `swift test` per touched package; orchestrator `xcodebuild` scheme `rishi` before handoff.
- **Design tokens** — RishiUIKit only in package UI (`RishiSpacing`, `RishiTypography`, `RishiColor`, `RishiRadius`); app overlay uses existing `GlassCardBackground`.
- **Accessibility** — Every control gets `accessibilityIdentifier` + `accessibilityLabel`; waveform is `accessibilityHidden(true)` with status text on the combined element.
- **Reader exit policy** — Leaving the reader (`ReaderDestination.onDisappear`) ends an active voice session (same effective behavior as today’s cover dismiss).

---

## File map (created / modified)

| File | Responsibility |
|------|----------------|
| `Packages/RishiVoice/Sources/RishiVoice/State/VoiceActivityPhase.swift` | **Create** — `.connecting`, `.listening`, `.speaking`, `.reconnecting` |
| `Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift` | **Modify** — add `activityPhase`, helpers |
| `Packages/RishiVoice/Sources/RishiVoice/Service/VoiceTranscriptBridge.swift` | **Modify** — update `activityPhase` from transcript events |
| `Packages/RishiVoice/Sources/RishiVoice/UI/VoiceWaveformView.swift` | **Create** — animated bar waveform |
| `Packages/RishiVoice/Sources/RishiVoice/UI/VoiceControlsView.swift` | **Create** — compact pill content (TTS button, waveform, status, End) |
| `Packages/RishiVoice/Tests/RishiVoiceTests/...` | **Modify/Create** — phase, bridge, controls smoke tests |
| `rishi/rishi/Reader/ReaderAudioChromeOverlay.swift` | **Create** — shared draggable pill shell + mode switch |
| `rishi/rishi/Reader/ReadAloudControlsOverlay.swift` | **Delete or thin wrapper** — replaced by `ReaderAudioChromeOverlay` |
| `rishi/rishi/Audio/ReadAloudController.swift` | **Modify** — pause/resume handoff + Readium preemption |
| `rishi/rishi/Reader/ReaderDestination.swift` | **Modify** — unified overlay, TTS↔voice wiring, text-chat sheet |
| `rishi/rishi/Views/SignedInView.swift` | **Modify** — remove voice `fullScreenCover`; keep failure alert |
| `rishi/rishi/Views/VoiceSessionHost.swift` | **Delete** — text-chat sheet moves to `ReaderDestination`; no remaining callers |
| `rishi/rishiTests/Reader/ReaderAudioChromeVisibilityTests.swift` | **Create** — voice-only path (no prior TTS) shows overlay |
| `rishi/rishiUITests/ReadAloudNextParagraphUITests.swift` | **Modify** — if tests assume full-screen voice, update for pill |
| `apps/apple/docs/features/voice.md` | **Modify** — document new chrome UX |
| `apps/apple/docs/architecture/voice-chat-pipeline-current.md` | **Modify** — presentation layer |

---

### Task 1: Voice activity phase (transcript-driven)

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceActivityPhase.swift`
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift`
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceTranscriptBridge.swift`
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/State/VoiceActivityPhaseTests.swift`
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Service/VoiceTranscriptBridgeTests.swift`

**Interfaces:**
- Produces: `VoiceActivityPhase` enum; `VoiceSessionState.activityPhase`; `VoiceSessionState.apply(activityPhase:)`; bridge sets phase on ingest.

- [ ] **Step 1: Write failing tests**

```swift
// VoiceActivityPhaseTests.swift
@Test("apply maps connecting statuses to .connecting")
func connectingStatuses() {
    let s = VoiceSessionState()
    s.apply(status: .connecting)
    #expect(s.activityPhase == .connecting)
}

// VoiceTranscriptBridgeTests.swift — add cases
@Test("assistant partial sets activityPhase speaking")
func assistantPartialSetsSpeaking() async { /* emit .assistant partial */ }

@Test("user partial sets activityPhase listening")
func userPartialSetsListening() async { /* emit .user partial */ }
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceActivityPhase`
Run: `swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceTranscriptBridge`

- [ ] **Step 3: Implement**

```swift
// VoiceActivityPhase.swift
public enum VoiceActivityPhase: Sendable, Equatable {
    case connecting
    case listening
    case speaking
    case reconnecting
}

// VoiceSessionState.swift — add:
public var activityPhase: VoiceActivityPhase = .connecting

public func apply(activityPhase: VoiceActivityPhase) {
    self.activityPhase = activityPhase
}

// In apply(status:): map .reconnecting → .reconnecting; pre-live → .connecting; .live → .listening (default idle wait)

// VoiceTranscriptBridge.ingest — after role known:
//   .assistant non-empty partial → state.apply(activityPhase: .speaking)
//   .assistant isFinal → state.apply(activityPhase: .listening)  // waiting for user
//   .user non-empty partial → state.apply(activityPhase: .listening)  // mic active; label "Listening…"
// reset() clears activityPhase to .connecting
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceActivityPhase.swift \
        apps/apple/Packages/RishiVoice/Sources/RishiVoice/State/VoiceSessionState.swift \
        apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/VoiceTranscriptBridge.swift \
        apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/State/VoiceActivityPhaseTests.swift \
        apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Service/VoiceTranscriptBridgeTests.swift
git commit -m "feat(voice): add VoiceActivityPhase for chrome waveform"
```

---

### Task 2: VoiceWaveformView + VoiceControlsView

**Files:**
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceWaveformView.swift`
- Create: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceControlsView.swift`
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/RishiVoice+API.swift` (export surface comment)
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceControlsViewTests.swift`
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift`

**Interfaces:**
- Consumes: `VoiceSessionState` (`status`, `activityPhase`, `isFinalInterval`)
- Produces: `VoiceControlsView` with closures `onEnd`, `onOpenReadAloud`, optional `onOpenTextChat`
- Produces: `VoiceControlsView.openReadAloudAccessibilityIdentifier = "voice-open-read-aloud"`
- Produces: `VoiceControlsView.endAccessibilityIdentifier = "voice-end"`
- Produces: `VoiceControlsView.openTextChatAccessibilityIdentifier = "voice.openTextChat"` (move from `VoiceSessionView`)

- [ ] **Step 1: Write failing construction tests**

```swift
@Test("VoiceControlsView constructs for every activityPhase")
func constructsAllPhases() {
    for phase in [VoiceActivityPhase.connecting, .listening, .speaking, .reconnecting] {
        let state = VoiceSessionState()
        state.apply(status: .live)
        state.apply(activityPhase: phase)
        _ = VoiceControlsView(state: state, onEnd: {}, onOpenReadAloud: {}).body
    }
}

@Test("VoiceControlsView shows Ending soon only when isFinalInterval")
func endingSoonLabel() {
    let state = VoiceSessionState()
    state.apply(status: .live)
    state.applySessionEndingWarning()
    _ = VoiceControlsView(state: state, onEnd: {}, onOpenReadAloud: {}).body
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `swift test --package-path apps/apple/Packages/RishiVoice --filter VoiceControlsView`

- [ ] **Step 3: Implement VoiceWaveformView**

```swift
// VoiceWaveformView.swift — 5 vertical bars, heights animated via TimelineView / phase:
//   .speaking → fast varying heights (sin wave + random seed per bar)
//   .listening → slow gentle pulse
//   .connecting / .reconnecting → staggered indeterminate pulse
// Uses RishiColor.accent / RishiColor.textSecondary only.
public struct VoiceWaveformView: View {
    public let phase: VoiceActivityPhase
    // barCount = 5, frame ~56×40 centered in pill
}
```

- [ ] **Step 4: Implement VoiceControlsView layout**

```
HStack (mirror ReadAloudControlsView spacing):
  Spacer
  [Read Aloud]  speaker.wave.2.fill  — id: voice-open-read-aloud
  [Waveform + status label]           — center cluster
  [End]  phone.down.fill destructive  — id: voice-end
  Spacer
```

Status label mapping (caption, `RishiTypography.caption`):
- connecting statuses → `"Connecting…"`
- `.live` + `.listening` → `"Listening…"`
- `.speaking` → `"Speaking…"`
- `.reconnecting` → `"Reconnecting…"`
- `isFinalInterval` → append/show `"Ending soon"` in `RishiColor.danger` (replaces numeric allowance)

Do **not** render `remainingVoiceChatSeconds` / trial credits unless `isFinalInterval`.

Optional trailing `bubble.left.and.bubble.right` only if `onOpenTextChat != nil` (preserve `voice.openTextChat` id for selection-quote flow).

- [ ] **Step 5: Run tests — expect PASS**

- [ ] **Step 6: Commit**

---

### Task 3: TTS pause/resume handoff

**Files:**
- Modify: `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- Test: `apps/apple/rishi/rishiTests/Audio/ReadAloudVoiceHandoffTests.swift`

**Interfaces:**
- Produces:
  - `var wantsAutoResumeAfterVoice: Bool { get }`
  - `func pauseForVoiceHandoff() async`
  - `func resumeAfterVoiceIfNeeded() async`
  - `func openReadAloudFromVoice(vm: ReaderViewModel) async` — resume if flagged, else `startReader(vm:)`

- [ ] **Step 1: Write failing tests**

```swift
@Test("pauseForVoiceHandoff pauses playing Readium session and sets wantsAutoResume")
func pausePlayingSetsFlag() async { /* start synthesizer playing → pauseForVoiceHandoff → paused + flag true */ }

@Test("pauseForVoiceHandoff when idle does not set wantsAutoResume")
func idleHandoffNoFlag() async { /* showControls false, not playing → flag false */ }

@Test("resumeAfterVoiceIfNeeded resumes only when flag set")
func resumeWhenFlagged() async { /* flag true → playing; flag false → no-op */ }

@Test("manual pause during voice clears wantsAutoResume")
func manualPauseClearsFlag() async { /* set flag, togglePlayback to pause → flag false */ }
```

- [ ] **Step 2: Run — expect FAIL**

Run: `swift test --filter ReadAloudVoiceHandoff --package-path apps/apple/rishi`

- [ ] **Step 3: Implement**

```swift
// ReadAloudController.swift
private(set) var wantsAutoResumeAfterVoice = false

func pauseForVoiceHandoff() async {
    let wasPlaying = ttsState.status == .playing || isActivelySpeaking
    guard wasPlaying else {
        wantsAutoResumeAfterVoice = false
        return
    }
    wantsAutoResumeAfterVoice = true
    if let readiumSynthesizer {
        if case .playing = readiumState { readiumSynthesizer.pauseOrResume() } // → paused
    } else if let bridge {
        await bridge.pause()
    }
    // keep showControls true so pill can morph back
}

func resumeAfterVoiceIfNeeded() async {
    guard wantsAutoResumeAfterVoice else { return }
    wantsAutoResumeAfterVoice = false
    await togglePlayback() // resumes
}

func openReadAloudFromVoice(vm: ReaderViewModel) async {
    if wantsAutoResumeAfterVoice {
        await resumeAfterVoiceIfNeeded()
    } else {
        await startReader(vm: vm)
    }
}

// Register TTS preemption in BOTH playback paths (Readium + legacy bridge):
private func registerTTSPreemption() async {
    await coordinator.registerPreemption(for: .tts) { [weak self] in
        await self?.pauseForVoiceHandoff()
    }
}
// Call registerTTSPreemption() from startReader (after synthesizer created)
// AND from start(paragraphs:...) (after bridge created) — ReaderTTSBridge
// already registers pause internally; ReadAloudController's register wraps
// Readium and must run before any voice requestActiveMode(.voice) preempt.

// Manual pause clears auto-resume intent:
func togglePlayback() async {
    let wasPlaying = ttsState.status == .playing
    // ... existing pause/resume ...
    if wasPlaying && ttsState.status == .paused {
        wantsAutoResumeAfterVoice = false
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

---

### Task 4: ReaderAudioChromeOverlay (shared shell)

**Files:**
- Create: `apps/apple/rishi/rishi/Reader/ReaderAudioChromeOverlay.swift`
- Modify: `apps/apple/rishi/rishi/Reader/ReadAloudControlsOverlay.swift` — delete body; re-export typealias or remove file after migration
- Test: `apps/apple/rishi/rishiTests/Reader/ReaderAudioChromeOverlayTests.swift` (mode + visibility logic only — no snapshot)

**Interfaces:**
- Consumes: `ReaderAudioChromeMode` enum `.tts(ReadAloudControlsView bindings…)` / `.voice(VoiceControlsView bindings…)`
- Produces: `ReaderAudioChromeOverlay` — same drag/position/`GlassCardBackground` as today’s `ReadAloudControlsOverlay`
- Produces: `isVisible: Bool` parameter — **not** tied to `ReadAloudController.showControls` alone (today's overlay gates on `controller.showControls` internally; the new overlay must not).
- Produces: `@State private var location` persisted across `mode` changes (do not reset on TTS↔voice morph).

- [ ] **Step 1: Extract shell**

Move drag gesture, `committedLocation`, `GlassCardBackground(cornerRadius: RishiRadius.pill)`, mac Catalyst max width, size measurement from `ReadAloudControlsOverlay` into `ReaderAudioChromeOverlay`.

- [ ] **Step 2: Mode switch with transition**

```swift
enum ReaderAudioChromeMode: Equatable { case tts, voice }

@ViewBuilder
private var content: some View {
    switch mode {
    case .tts: /* ReadAloudControlsView ... */
    case .voice: /* VoiceControlsView ... */
    }
}
// Wrap content:
content
    .animation(.easeInOut(duration: 0.25), value: mode)
    .contentTransition(.interpolate) // iOS 17+
```

Keep pill `.position` stable when `mode` changes.

- [ ] **Step 3: Visibility**

Overlay shown when `isVisible == true` (computed upstream: TTS `showControls || voicePresenter.isPresenting`).

`.transition(.move(edge: .bottom).combined(with: .opacity))` on appear/disappear (reuse existing).

- [ ] **Step 4: Commit**

---

### Task 5: Wire ReaderDestination + remove fullScreenCover

**Files:**
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestination.swift` — add `import RishiVoice`
- Modify: `apps/apple/rishi/rishi/Views/SignedInView.swift`
- Delete: `apps/apple/rishi/rishi/Views/VoiceSessionHost.swift`
- Test: `apps/apple/rishi/rishiTests/Reader/ReaderAudioChromeVisibilityTests.swift`

**Interfaces:**
- Produces: `ensureReadAloudController() -> ReadAloudController` — lazy-init controller (same deps as `onReadAloud` block today) so voice-only and voice→TTS paths always have a target.
- TTS → Voice: `await ra.pauseForVoiceHandoff()` then `voiceEntry.presentVoice(...)` — never `ra.stop()`.
- Voice → TTS (`onOpenReadAloud`): `Task { await voicePresenter.requestEnd(); let ra = ensureReadAloudController(); await ra.openReadAloudFromVoice(vm: vm) }`
- Voice End: `Task { await voicePresenter.requestEnd(); await readAloud?.resumeAfterVoiceIfNeeded() }` — auto-resume TTS when `wantsAutoResumeAfterVoice`.
- Reader disappear: `Task { await services.voicePresenter.requestEnd(); await readAloud?.stop() }`
- Failure promotion: when `isPresenting` flips false, call `promotePendingFailure()` (replaces `fullScreenCover.onDismiss`).

- [ ] **Step 1: Add `ensureReadAloudController()` to ReaderDestination**

```swift
@MainActor
private func ensureReadAloudController() -> ReadAloudController {
    if let readAloud { return readAloud }
    let ra = ReadAloudController(
        ttsEngine: services.ttsEngine,
        ttsState: services.ttsState,
        ttsSettingsStore: services.ttsSettingsStore,
        ttsPrewarmer: services.ttsPrewarmer,
        ttsPresence: services.ttsPresenceController,
        coordidator: services.audioCoordinator,
        userId: userId
    )
    readAloud = ra
    return ra
}
```

- [ ] **Step 2: Replace overlay — voice must NOT depend on `readAloud != nil`**

```swift
.overlay {
    let voiceActive = services.voicePresenter.isPresenting
    let ttsVisible = readAloud?.showControls == true
    if voiceActive || ttsVisible {
        ReaderAudioChromeOverlay(
            isVisible: true,
            mode: voiceActive ? .voice : .tts,
            voiceState: services.voicePresenter.state,
            ttsState: services.ttsState,
            readAloud: readAloud, // nil on voice-only toolbar entry — do NOT eager-create here
            onOpenVoiceChat: {
                Task {
                    let controller = ensureReadAloudController()
                    await controller.pauseForVoiceHandoff()
                    voiceEntry.presentVoice(bookId: vm.book.id, context: vm.voiceContext(), initialQuote: nil)
                }
            },
            onOpenReadAloud: {
                Task {
                    await services.voicePresenter.requestEnd()
                    await ensureReadAloudController().openReadAloudFromVoice(vm: vm)
                }
            },
            onEndVoice: {
                Task {
                    await services.voicePresenter.requestEnd()
                    await readAloud?.resumeAfterVoiceIfNeeded()
                }
            },
            ...
        )
    }
}
```

`ensureReadAloudController()` is called only from handoff callbacks — not when rendering voice-only chrome (avoids spinning up TTS engine for toolbar-only voice).

- [ ] **Step 3: Text chat sheet for `pendingInitialQuote`**

Move from `VoiceSessionHost.onAppear` to `ReaderDestination`:

```swift
.sheet(isPresented: $showVoiceTextChat) {
    // same ChatPanelView wiring as VoiceSessionHost.textChatSheet
}
.onChange(of: services.voicePresenter.pendingInitialQuote) { _, quote in
    if quote != nil { showVoiceTextChat = true }
}
```

- [ ] **Step 4: Remove SignedInView fullScreenCover** (lines 55–74). Delete `VoiceSessionHost` and its import sites.

Add failure promotion (replaces cover `onDismiss`):

```swift
.onChange(of: services.voicePresenter.isPresenting) { _, presenting in
    if !presenting {
        services.voicePresenter.promotePendingFailure()
    }
}
```

Keep `.alert` for failures unchanged.

- [ ] **Step 5: Indexing chip collision**

When chrome visible, add extra bottom padding to `IndexingIndicatorChip` or hide chip while `voicePresenter.isPresenting` — pick hide-when-voice (simpler, less overlap risk).

- [ ] **Step 6: Write visibility test**

```swift
@Test("voice overlay visible when isPresenting even without prior TTS")
func voiceOnlyShowsChrome() {
    // voicePresenter.isPresenting == true, readAloud == nil → isVisible == true
}
```

- [ ] **Step 7: Manual test checklist**

1. Open book → start Read Aloud → tap Voice Chat → pill morphs, book visible, TTS pauses at paragraph.
2. Tap Read Aloud on voice pill → voice ends, TTS resumes same paragraph.
3. Open voice from toolbar (no TTS) → voice pill appears; Read Aloud starts from current page.
4. End voice while TTS was not active → pill disappears.
5. Selection "Ask about this" → voice pill + text chat sheet opens; book visible.
6. Allowance: no minutes shown until server sends final interval → `"Ending soon"` appears.
7. Leave reader → voice session ends.

8. Voice start failure (mic denied) → pill dismisses, alert promotes via `onChange(isPresenting)`.
9. Toolbar voice while TTS paused (not playing) → no auto-resume on End.

- [ ] **Step 8: Commit**

---

### Task 6: Deprecate full-screen VoiceSessionView from production path

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/UI/VoiceSessionView.swift` — add deprecation comment; keep for previews/tests OR trim to preview-only
- Modify: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/UI/VoiceUISnapshotTests.swift` — add `VoiceControlsView` cases; keep `VoiceSessionView` smoke tests optional

- [ ] **Step 1:** Mark `VoiceSessionView` as legacy full-screen surface in doc comment; production uses `VoiceControlsView`.
- [ ] **Step 2:** Update `VoiceUISnapshotTests` — add `VoiceControlsView` cases; migrate `openTextChatAccessibilityIdentifier` expectation to `VoiceControlsView`.
- [ ] **Step 3:** Update `VoiceUISnapshotTests` `VoiceSessionView` tests — keep as legacy smoke only.
- [ ] **Step 4:** Commit

---

### Task 7: Documentation + build gate

**Files:**
- Modify: `apps/apple/docs/features/voice.md`
- Modify: `apps/apple/docs/architecture/voice-chat-pipeline-current.md`

- [ ] **Step 1:** Document pill chrome, TTS↔voice handoff, allowance policy, text-chat sheet trigger.
- [ ] **Step 2:** Package tests

```bash
swift test --package-path apps/apple/Packages/RishiVoice
swift test --package-path apps/apple/Packages/RishiAudio
```

- [ ] **Step 3:** App tests

```bash
swift test --package-path apps/apple/rishi --filter ReadAloudVoiceHandoff
swift test --package-path apps/apple/rishi --filter ReaderAudioChrome
```

- [ ] **Step 4:** Orchestrator build gate

```bash
xcodebuild -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 16' build
```

- [ ] **Step 5:** Commit docs

---

## Out of scope (explicit)

- **Audio-level reactive waveform** (tap WebRTC output buffers) — follow-up task after v1 state-driven animation ships.
- **Live Activity / Dynamic Island** — future enhancement.
- **VoiceCharacterView artwork** — unchanged; not in pill v1.
- **Electron reader** — Apple-only plan.

---

## Adversarial review log

### Round 1 — FAIL (issues found, fixed above)

| Severity | Finding | Fix |
|----------|---------|-----|
| **Critical** | Task 5 gated overlay on `if let readAloud` — toolbar voice with no prior TTS (`readAloud == nil`) would show **no chrome** | Overlay visibility = `isPresenting \|\| showControls`; add `ensureReadAloudController()` |
| **Critical** | Current `ReadAloudControlsOverlay` only renders when `controller.showControls` — voice-only sessions never visible | New overlay takes explicit `isVisible` param |
| **Critical** | `fullScreenCover.onDismiss` called `promotePendingFailure()` — removing cover without replacement loses failure alerts after `enterFailure` | `SignedInView.onChange(isPresenting)` → `promotePendingFailure()` |
| **Important** | Readium TTS path had no `registerPreemption` on `ReadAloudController` — coordinator preempt could miss pause | `registerTTSPreemption()` in both `startReader` and legacy `start(paragraphs:)` |
| **Important** | `ReaderDestination` missing `import RishiVoice` for `VoiceControlsView` / state types | Added to Task 5 |
| **Important** | `VoiceSessionView.openTextChatAccessibilityIdentifier` used by tests — must migrate to `VoiceControlsView` | Task 6 |
| **Important** | `onDisappear` only stopped TTS, not voice | Explicit `voicePresenter.requestEnd()` in Task 5 |
| **Minor** | Assistant-final should flip phase to `.listening` (waiting for user), not stay `.speaking` | Task 1 bridge rules updated |
| **Important** | Eager `ensureReadAloudController()` in overlay body would init TTS for voice-only sessions | Lazy-create only in handoff callbacks |

### Round 2 — PASS WITH NOTES

All Round 1 critical/important items have explicit tasks. Residual notes (non-blocking):

- **UITests:** Run `ReadAloudNextParagraphUITests` after wiring; update if they target full-screen voice identifiers.
- **Audio-level waveform:** Explicitly deferred to out-of-scope follow-up.
- **Connecting pill:** `isPresenting = true` from first line of `VoiceSessionPresenter.start()` — pill appears during connect (desired "started" signal).
- **End auto-resume:** Matches Electron preserve-TTS-position spec; manual pause during voice clears flag (Task 3 test).

**Verdict: Plan ready for implementation.**
