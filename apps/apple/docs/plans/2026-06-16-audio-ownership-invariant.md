# Audio-Ownership Invariant Implementation Plan (Workstream 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee exactly one audio owner (TTS read-aloud OR voice chat) is ever active at a time, by making `AudioSessionCoordinator` preempt (fully stop) the previous owner before granting a new mode — fixing the read-aloud/voice echo.

**Architecture:** `AudioSessionCoordinator` (the singleton AVAudioSession owner) gains a per-mode registered preempt closure (`@Sendable () async -> Void`). When `requestActiveMode` switches owners, it `await`s the outgoing owner's closure before applying the new session configuration. `TTSEngine` registers `{ await self.stop() }`; `RealtimeVoiceSession` registers `{ await self.end() }`. RishiAudio gains no dependency on RishiVoice/app (closure seam, not protocol).

**Tech Stack:** Swift 6 strict concurrency, actors, Swift Testing. Packages: RishiAudio (coordinator + TTSEngine), RishiVoice (RealtimeVoiceSession).

**Source of truth:** `apps/apple/docs/specs/2026-06-16-voice-audio-ownership-and-book-context-design.md` (Component 1).

**Constraints (from apps/apple/CLAUDE.md):** No emojis. Swift Testing only. Default-isolation MainActor stays. Subagents must NOT run `xcodebuild rishi`; verify packages with `swift test --package-path ...`. Orchestrator runs the final full `xcodebuild` and greps for the literal `** BUILD SUCCEEDED **`. Stay on `main`; commit only under allowed paths.

---

## File Structure

- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift` — add preempt registry + invocation.
- Test: `apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/AudioSessionCoordinatorPreemptionTests.swift` — new suite for the invariant.
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift` — register `.tts` preempt in `start`.
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift` — register `.voice` preempt in `start`.
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Service/RealtimeVoiceSessionPreemptionTests.swift` — voice registers + stops when preempted.

---

## Task 1: Coordinator preempt registry + invocation

**Files:**
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift`
- Test: `apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/AudioSessionCoordinatorPreemptionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AudioSessionCoordinatorPreemptionTests.swift`:

```swift
import Testing
@testable import RishiAudio

@Suite("AudioSessionCoordinator preemption", .serialized)
struct AudioSessionCoordinatorPreemptionTests {

    // Sendable counter the preempt closures can mutate across actor hops.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("requesting voice while tts active runs the tts preempt handler once, then goes voice")
    func voicePreemptsTTS() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let ttsStops = Counter()
        await coord.registerPreemption(for: .tts) { ttsStops.bump() }

        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.voice)

        #expect(ttsStops.value == 1)
        #expect(await coord.currentMode == .voice)
    }

    @Test("requesting tts while voice active runs the voice preempt handler once, then goes tts")
    func ttsPreemptsVoice() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let voiceStops = Counter()
        await coord.registerPreemption(for: .voice) { voiceStops.bump() }

        await coord.requestActiveMode(.voice)
        await coord.requestActiveMode(.tts)

        #expect(voiceStops.value == 1)
        #expect(await coord.currentMode == .tts)
    }

    @Test("staying in the same mode does NOT run a preempt handler")
    func samesModeNoPreempt() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let ttsStops = Counter()
        await coord.registerPreemption(for: .tts) { ttsStops.bump() }

        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.tts) // passage switch, not an owner change

        #expect(ttsStops.value == 0)
        #expect(await coord.currentMode == .tts)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path apps/apple/Packages/RishiAudio --filter AudioSessionCoordinatorPreemptionTests`
Expected: compile failure — `registerPreemption(for:)` does not exist.

- [ ] **Step 3: Implement the registry + invocation**

In `AudioSessionCoordinator.swift`, add a stored registry and registration method (place after the `policy`/`interruptionTask` stored properties):

```swift
    /// Per-mode "stop the owner" closures. The coordinator invokes the
    /// OUTGOING mode's closure before granting a different mode, so the
    /// displaced owner (TTS engine / voice session) is fully torn down — not
    /// just its AVAudioSession config. Enforces the single-audio-owner
    /// invariant at the resource owner. `@Sendable` to cross actor boundaries.
    private var preemptHandlers: [ActiveMode: @Sendable () async -> Void] = [:]

    /// Register the closure that fully stops the owner of `mode`. Owners call
    /// this just before they `requestActiveMode(mode)`. Re-registering
    /// overwrites (e.g. a fresh per-session voice owner).
    public func registerPreemption(for mode: ActiveMode, handler: @escaping @Sendable () async -> Void) {
        preemptHandlers[mode] = handler
    }

    /// Await the outgoing owner's stop closure (if any). The closure typically
    /// calls back into `releaseActiveMode`, which the actor processes while
    /// this call is suspended — leaving the policy at `.idle` before the new
    /// mode is applied.
    private func preempt(_ mode: ActiveMode) async {
        guard let handler = preemptHandlers[mode] else { return }
        await handler()
    }
```

Then, in `requestActiveMode(_:)`, preempt the *other* owner before reducing. Replace the `.tts` and `.voice` cases:

```swift
        case .tts:
            // Owner change: a live voice session must be stopped first.
            if policy.mode == .voice { await preempt(.voice) }
            // Already in .tts means a passage switch (next/prev/repeat) — no preempt.
            apply(policy.reduce(policy.mode == .tts ? .switchPassage : .beginPassage))
            Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
        case .voice:
            // Owner change: live read-aloud must be stopped first.
            if policy.mode == .tts { await preempt(.tts) }
            apply(policy.reduce(.beginVoice))
            Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path apps/apple/Packages/RishiAudio --filter AudioSessionCoordinatorPreemptionTests`
Expected: PASS (3 tests). Also run the full package to confirm no regressions:
Run: `swift test --package-path apps/apple/Packages/RishiAudio`
Expected: all pass (green baseline preserved).

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/AudioSessionCoordinatorPreemptionTests.swift
git commit -m "feat(apple): coordinator preempts prior audio owner on mode switch"
```

---

## Task 2: TTSEngine registers its preempt handler

**Files:**
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift` (the `start(request:)` method that calls `coordinator.requestActiveMode(.tts)` near line 67)
- Test: extend `apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/` TTSEngine suite (find the existing TTSEngine test file; reuse its fake chunk-source / configurator setup)

- [ ] **Step 1: Write the failing test**

In the existing TTSEngine test file (mirror its existing `start`-to-playing setup with the fake chunk source already used there), add:

```swift
@Test("a voice mode request while TTS is playing stops the engine")
func voiceRequestStopsTTS() async throws {
    // GIVEN the existing harness drives `engine.start(request:)` to a playing
    // state sharing ONE AudioSessionCoordinator (the same `coordinator` the
    // engine was constructed with).
    // ... existing start-to-playing setup ...

    // WHEN another owner asks the shared coordinator for .voice
    await coordinator.requestActiveMode(.voice)

    // THEN TTSEngine tore itself down (stop() ran via the registered preempt).
    #expect(await engine.isStopped == true) // use whatever state accessor the suite already asserts on
}
```

Note: if the suite has no `isStopped`/state accessor, assert on the observable `TTSPlaybackState` the suite already uses, or on `await coordinator.currentMode == .voice` plus the engine no longer feeding (whatever the existing tests observe). Keep the assertion behavioral.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path apps/apple/Packages/RishiAudio --filter <TTSEngineSuiteName>`
Expected: FAIL — engine keeps playing because nothing stopped it.

- [ ] **Step 3: Register the preempt handler in `start`**

In `TTSEngine.start(request:)`, immediately before the existing `await coordinator.requestActiveMode(.tts)` (≈ line 67), add:

```swift
        // Single-audio-owner invariant: let the coordinator stop us if another
        // owner (voice) takes the session. `stop()` is our full teardown and
        // releases `.tts` itself, so this is safe to call any time.
        await coordinator.registerPreemption(for: .tts) { [weak self] in
            await self?.stop()
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path apps/apple/Packages/RishiAudio`
Expected: the new test + all existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSEngine.swift apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/
git commit -m "feat(apple): TTSEngine registers preempt so voice can stop read-aloud"
```

---

## Task 3: RealtimeVoiceSession registers its preempt handler

**Files:**
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift` (the `start(...)` method that calls `coordinator.requestActiveMode(.voice)` at line 122)
- Test: `apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Service/RealtimeVoiceSessionPreemptionTests.swift`

- [ ] **Step 1: Write the failing test**

Mirror the existing `RealtimeVoiceSessionTests` harness (`makeFakes(...)` builds `coordinator`, `client` (FakeRealtimeClient), `micGate` (granted), `StubEphemeralKeyFetcher`). Create `RealtimeVoiceSessionPreemptionTests.swift`:

```swift
import Testing
@testable import RishiVoice
@testable import RishiAudio

@Suite("RealtimeVoiceSession preemption", .serialized)
struct RealtimeVoiceSessionPreemptionTests {

    @Test("a tts mode request while voice is live ends the session")
    func ttsRequestEndsVoice() async {
        // GIVEN the existing makeFakes() harness with a granted mic + a keyFetch
        // success + a connectable FakeRealtimeClient, sharing ONE coordinator.
        let fakes = makeFakes(/* mic granted, keyFetch success */)
        let session = RealtimeVoiceSession(
            micGate: fakes.micGate,
            coordinator: fakes.coordinator,
            keyFetcher: fakes.fetcher,
            client: fakes.client,
            state: fakes.state
        )
        await session.start(language: "en")              // drives to .live
        #expect(await fakes.coordinator.currentMode == .voice)

        // WHEN read-aloud asks the shared coordinator for .tts
        await fakes.coordinator.requestActiveMode(.tts)

        // THEN the voice session ended (end() ran via the registered preempt):
        // the FakeRealtimeClient saw a disconnect and the mode left .voice.
        #expect(fakes.client.disconnectCalled == true)   // use the fake's existing disconnect spy
    }
}
```

Note: use the exact fake accessor the existing voice tests assert on for disconnect / ended state (e.g. `client.disconnectCallCount`, or `state.status == .ended`). Reuse `makeFakes` rather than re-declaring fakes.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path apps/apple/Packages/RishiVoice --filter RealtimeVoiceSessionPreemptionTests`
Expected: FAIL — session stays live; nothing ended it.

- [ ] **Step 3: Register the preempt handler in `start`**

In `RealtimeVoiceSession.start(...)`, immediately before `await coordinator.requestActiveMode(.voice)` (line 122), add:

```swift
        // Single-audio-owner invariant: let the coordinator end this session if
        // another owner (read-aloud TTS) takes the session. `end()` is our full
        // teardown and releases `.voice` itself. `[weak self]` so the
        // coordinator's stored closure never retains the per-session actor.
        await coordinator.registerPreemption(for: .voice) { [weak self] in
            await self?.end()
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path apps/apple/Packages/RishiVoice`
Expected: the new test + all existing RishiVoice tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift apps/apple/Packages/RishiVoice/Tests/RishiVoiceTests/Service/RealtimeVoiceSessionPreemptionTests.swift
git commit -m "feat(apple): RealtimeVoiceSession registers preempt so read-aloud can stop voice"
```

---

## Task 4: Integrated build gate (orchestrator only)

**Files:** none (verification).

- [ ] **Step 1: Full app build**

Run (orchestrator, NOT a subagent):
`xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' > /tmp/audio_build.log 2>&1`

- [ ] **Step 2: Verify the success marker**

Run: `grep -c "\*\* BUILD SUCCEEDED \*\*" /tmp/audio_build.log`
Expected: `1`. If `CNumKong.o` build-input error appears (stale fresh-DD C-target race), clear the changed packages' stale artifacts in the default DerivedData and rebuild incrementally (do NOT trust exit code — grep for the literal marker).

- [ ] **Step 3: Manual device check**

On a device/simulator with audio: start read-aloud, then tap the reader voice button. Expected: read-aloud stops the instant voice connects (no echo / no overlapping voices). End voice; start read-aloud again — works. Start voice, then start read-aloud — voice ends cleanly.

---

## Self-Review notes

- Spec coverage: implements Component 1 (single-audio-owner invariant) end-to-end (coordinator mechanism + both owners registering + behavioral tests + integrated gate).
- Type consistency: `registerPreemption(for:handler:)`, `preempt(_:)`, `preemptHandlers` used consistently across Tasks 1–3; closures are `@Sendable () async -> Void`; stop targets are `TTSEngine.stop()` and `RealtimeVoiceSession.end()` (both confirmed full-teardown methods that release their own mode).
- Reentrancy: the preempt closure calls `releaseActiveMode` back into the coordinator actor while `requestActiveMode` is suspended at `await preempt(...)`; the policy reaches `.idle` before the new mode's reducer runs — correct ordering, no double-deactivate churn.
- Owner-test setup (Tasks 2–3) intentionally reuses each package's existing TTSEngine / RealtimeVoiceSession test harness rather than re-declaring fakes; the executor adapts the exact state/spy accessor those suites already assert on.

## Workstreams 2–4 (separate plans, written after this ships)

2. Reading-context snapshot + worker book-identity (RishiReader seam → presenter → `RealtimeVoiceSession.start` params → worker prompt + redeploy).
3. RAG indexing backfill on reader-open + reindex recovery + embedder-fallback surfacing.
4. Indexing indicator chip + `BookSearchStatus` observable (voice button NOT gated).
