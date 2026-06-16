//
//  ReaderTTSBridgeNextPrevTests.swift
//  rishiTests
//
//  Feature 5 — user-driven previous/next PARAGRAPH navigation on the read-aloud
//  player. These tests are written before ReaderTTSBridge.next()/previous()
//  exist (TDD red). The FakeTTSEngine `.holds` script keeps the engine in
//  `.playing` so the auto-advance watcher never fires; only the explicit
//  next()/previous() calls move the play head, which makes the navigation
//  deterministic. Assertions read the fake's ordered start-call log.
//

import Foundation
import Testing
import PropertyBased
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge next/previous")
@MainActor
struct ReaderTTSBridgeNextPrevTests {

    /// The passage ids the engine was asked to START, in order.
    private func startIds(_ engine: FakeTTSEngine) -> [String?] {
        engine.calls.compactMap { call in
            if case .start(let passageId) = call { return passageId }
            return nil
        }
    }

    @Test("next() advances one paragraph, previous() goes back, each plays the target")
    func nextAndPreviousNavigate() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "2" }

        await env.bridge.previous()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0", "1", "2", "1"])
    }

    /// Parity with auto-advance: pressing Next on the LAST paragraph of a chapter
    /// must cross into the next chapter (reusing the same continuation source as
    /// auto-advance), not clamp. Reproduces the reported bug where the forward
    /// button refused to cross the chapter boundary while auto-advance did.
    @Test("next() at the last paragraph crosses into the next chapter (reuses auto-advance)")
    func nextAtEndCrossesChapter() async {
        let source = ExhaustionSource([["next-a", "next-b"]]) // one more chapter
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onExhausted: { source.next() }
        )
        await env.bridge.start(paragraphs: ["only-a", "only-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        // At the last paragraph: cross into the next chapter (its index resets to
        // "0"), rather than clamping at "1".
        await env.bridge.next()
        await waitUntil(timeout: 3) { startIds(env.engine) == ["0", "1", "0"] }

        await env.bridge.stop()
        #expect(source.callCount >= 1, "next() at the boundary must request the next chapter")
        #expect(startIds(env.engine) == ["0", "1", "0"])
    }

    /// At the last paragraph of the LAST chapter (continuation source dry), Next
    /// must not fabricate an out-of-range passage; it stops cleanly.
    @Test("next() at the last paragraph of the last chapter does not start out-of-range")
    func nextAtEndOfBookStops() async {
        let source = ExhaustionSource([]) // no further chapter
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onExhausted: { source.next() }
        )
        await env.bridge.start(paragraphs: ["only-a", "only-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.next()
        await waitUntil(timeout: 2) { source.callCount >= 1 }

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0", "1"], "must not start an out-of-range passage at end of book")
    }

    /// Backward parity with `nextAtEndCrossesChapter`: pressing Previous on the
    /// FIRST paragraph of a chapter must cross into the PRECEDING chapter and
    /// land on its LAST paragraph (where a listener expects narration to resume),
    /// not clamp at index 0. Reproduces the reported bug — Previous at the top of
    /// a page/chapter is a silent no-op instead of crossing the boundary.
    @Test("previous() at the first paragraph crosses into the previous chapter's LAST paragraph")
    func previousAtStartCrossesIntoPreviousBatch() async {
        let source = ExhaustionSource([["prev-a", "prev-b", "prev-c"]]) // one preceding chapter
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onBeforeStart: { source.next() }
        )
        await env.bridge.start(paragraphs: ["cur-a", "cur-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        // At the first paragraph: cross BACKWARD into the previous chapter and
        // land on its LAST paragraph (index 2 of a 3-paragraph batch), rather
        // than clamping at "0".
        await env.bridge.previous()
        await waitUntil(timeout: 3) { startIds(env.engine).last == "2" }

        await env.bridge.stop()
        #expect(source.callCount >= 1, "previous() at the start must request the previous chapter")
        #expect(startIds(env.engine) == ["0", "2"],
                "previous() must land on the previous batch's last paragraph (id 2)")
    }

    /// At the first paragraph of the FIRST chapter (backward source dry), Previous
    /// must NOT fabricate an out-of-range passage NOR tear the session down — it
    /// stays put on the current paragraph so playback is uninterrupted.
    @Test("previous() at the first paragraph of the first chapter stays put (no previous chapter)")
    func previousAtBookStartStaysPut() async {
        let source = ExhaustionSource([]) // no preceding chapter
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onBeforeStart: { source.next() }
        )
        await env.bridge.start(paragraphs: ["cur-a", "cur-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.previous()
        try? await Task.sleep(nanoseconds: 300_000_000)

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0"],
                "previous() at book start must not fabricate a passage or tear down playback")
    }

    @Test("next() does NOT stop the engine on a switch but DOES start the new passage (long-lived engine)")
    func nextDoesNotStopEngineButPlaysNewPassage() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        let stopsBefore = env.engine.calls.filter { $0 == .stop }.count
        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }
        let stopsAfter = env.engine.calls.filter { $0 == .stop }.count

        // Long-lived engine: a passage switch must NOT stop the engine (the old
        // per-passage stop+restart HUNG mid-render on device and the restarted
        // engine had no live route). The bridge no longer calls engine.stop() on
        // jump; the in-place switch happens inside TTSEngine.start() via
        // resetPlayerNode. The bridge still START-s the new passage id.
        #expect(stopsAfter == stopsBefore, "next() must NOT stop the engine on a switch (long-lived engine)")
        #expect(startIds(env.engine).last == "1", "next() must start the new passage")
        await env.bridge.stop()
    }

    /// PROPERTY-BASED navigation (PropertyBased): for ANY generated page size and
    /// valid start index, next() from i lands the engine START on passage id
    /// String(i+1) and previous() from i+1 lands String(i). Uses the `.holds`
    /// harness so only explicit navigation moves the head (no auto-advance race).
    @Test("next()/previous() land the engine START on the adjacent passage id (property-based)")
    func navigationLandsAdjacentPassage() async {
        await propertyCheck(count: 12, input: Gen.int(in: 3 ... 10), Gen.int(in: 0 ... 8)) { pageCount, rawStart in
            let startIndex = max(0, min(rawStart, pageCount - 2))
            let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
            await env.bridge.start(paragraphs: (0..<pageCount).map { "p\($0)" })
            await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

            // Walk forward to startIndex so the play head sits there.
            for target in 1...max(startIndex, 1) where target <= startIndex {
                await env.bridge.next()
                await waitUntil(timeout: 2) { startIds(env.engine).last == String(target) }
            }
            #expect(startIds(env.engine).last == String(startIndex))

            // next() from startIndex -> startIndex+1.
            await env.bridge.next()
            await waitUntil(timeout: 2) { startIds(env.engine).last == String(startIndex + 1) }
            #expect(startIds(env.engine).last == String(startIndex + 1),
                    "next() from \(startIndex) must START passage \(startIndex + 1)")

            // previous() from startIndex+1 -> startIndex.
            await env.bridge.previous()
            await waitUntil(timeout: 2) { startIds(env.engine).last == String(startIndex) }
            #expect(startIds(env.engine).last == String(startIndex),
                    "previous() from \(startIndex + 1) must START passage \(startIndex)")

            await env.bridge.stop()
        }
    }

    @Test("repeatCurrent() replays the current paragraph from its start")
    func repeatCurrentReplays() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.repeatCurrent()
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0", "0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.repeatCurrent()
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0", "0", "1", "1"] }

        await env.bridge.stop()
    }

    @Test("previous() at the first paragraph is a clamped no-op")
    func previousAtStartClamps() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.previous()
        try? await Task.sleep(nanoseconds: 250_000_000)

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0"])
    }

    /// LONG-LIVED-ENGINE INVARIANT (inverts the former nextReactivatesSession).
    /// Drives the REAL TTSEngine over FakeAudioEngine + FakeAudioSessionConfigurator
    /// so the actual AVAudioSession decisions are exercised.
    ///
    /// A passage switch must NOT churn the session: the session is activated ONCE
    /// for the read-aloud session (first passage's beginPassage) and a switch
    /// (AudioSessionPolicy.switchPassage -> []) issues no further setActive(true).
    /// So `activeCalls.filter { $0.active }.count` stays == 1 across next(). The
    /// old per-passage release+re-acquire (which this asserts AGAINST) hung on
    /// device and produced no live route.
    @Test("next() does NOT re-activate the audio session — activated exactly once for the session")
    func nextDoesNotReactivateSession() async {
        let fakeConfig = FakeAudioSessionConfigurator()
        let bridge = makeRealEngineBridge(configurator: fakeConfig)

        await bridge.start(paragraphs: ["alpha", "bravo", "charlie"])
        await waitUntil(timeout: 2) { fakeConfig.activeCalls.contains { $0.active } }
        #expect(fakeConfig.activeCalls.filter { $0.active }.count == 1,
                "session must be activated exactly once on session start; activeCalls=\(fakeConfig.activeCalls)")

        // NEXT while passage 0 is still in flight == a true mid-passage switch.
        await bridge.next()
        // Give the switch time to run playCurrent -> engine.start() (in-place
        // switch via resetPlayerNode, no session work).
        await waitUntil(timeout: 1) { false }

        #expect(fakeConfig.activeCalls.filter { $0.active }.count == 1,
                "next() must NOT re-activate the session on a switch; activeCalls=\(fakeConfig.activeCalls)")
        await bridge.stop()
    }
}

/// Yields nothing and never finishes, so a started passage stays "in flight" —
/// no natural completion releases the audio session. Lets a test fire next() as
/// a TRUE mid-passage switch (the only condition under which the re-activation
/// bug manifests; a completed passage would already be back to .idle).
private struct InfiniteChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
}

/// Builds a bridge over the REAL TTSEngine so the genuine AudioSessionCoordinator
/// decisions are exercised against the recording FakeAudioSessionConfigurator.
@MainActor
private func makeRealEngineBridge(configurator: FakeAudioSessionConfigurator) -> ReaderTTSBridge {
    let state = TTSPlaybackState()
    let coordinator = AudioSessionCoordinator(configurator: configurator)
    let engine = TTSEngine(
        streamer: TTSStreamer(source: InfiniteChunkSource()),
        decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
        engine: FakeAudioEngine(),
        coordinator: coordinator,
        state: state
    )
    return ReaderTTSBridge(
        engine: engine,
        state: state,
        tracker: TTSPassageTracker(),
        prewarmer: TTSPrewarmer(source: InfiniteChunkSource()),
        settingsStore: InMemoryTTSSettingsStore(),
        userId: UserID(),
        onPassageChange: { _ in }
    )
}
