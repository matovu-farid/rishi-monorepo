//


//






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


    @Test("next() at the last paragraph crosses into the next chapter (reuses auto-advance)")
    func nextAtEndCrossesChapter() async {
        let source = ExhaustionSource([["next-a", "next-b"]]) 
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onExhausted: { source.next() }
        )
        await env.bridge.start(paragraphs: ["only-a", "only-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        
        
        await env.bridge.next()
        await waitUntil(timeout: 3) { startIds(env.engine) == ["0", "1", "0"] }

        await env.bridge.stop()
        #expect(source.callCount >= 1, "next() at the boundary must request the next chapter")
        #expect(startIds(env.engine) == ["0", "1", "0"])
    }


    @Test("next() at the last paragraph of the last chapter does not start out-of-range")
    func nextAtEndOfBookStops() async {
        let source = ExhaustionSource([]) 
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


    @Test("previous() at the first paragraph crosses into the previous chapter's LAST paragraph")
    func previousAtStartCrossesIntoPreviousBatch() async {
        let source = ExhaustionSource([["prev-a", "prev-b", "prev-c"]]) 
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onBeforeStart: { source.next() }
        )
        await env.bridge.start(paragraphs: ["cur-a", "cur-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        
        
        
        await env.bridge.previous()
        await waitUntil(timeout: 3) { startIds(env.engine).last == "2" }

        await env.bridge.stop()
        #expect(source.callCount >= 1, "previous() at the start must request the previous chapter")
        #expect(startIds(env.engine) == ["0", "2"],
                "previous() must land on the previous batch's last paragraph (id 2)")
    }


    @Test("previous() at the first paragraph of the first chapter stays put (no previous chapter)")
    func previousAtBookStartStaysPut() async {
        let source = ExhaustionSource([]) 
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

        
        
        
        
        
        #expect(stopsAfter == stopsBefore, "next() must NOT stop the engine on a switch (long-lived engine)")
        #expect(startIds(env.engine).last == "1", "next() must start the new passage")
        await env.bridge.stop()
    }


    @Test("next()/previous() land the engine START on the adjacent passage id (property-based)")
    func navigationLandsAdjacentPassage() async {
        await propertyCheck(count: 12, input: Gen.int(in: 3 ... 10), Gen.int(in: 0 ... 8)) { pageCount, rawStart in
            let startIndex = max(0, min(rawStart, pageCount - 2))
            let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
            await env.bridge.start(paragraphs: (0..<pageCount).map { "p\($0)" })
            await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

            
            for target in 1...max(startIndex, 1) where target <= startIndex {
                await env.bridge.next()
                await waitUntil(timeout: 2) { startIds(env.engine).last == String(target) }
            }
            #expect(startIds(env.engine).last == String(startIndex))

            
            await env.bridge.next()
            await waitUntil(timeout: 2) { startIds(env.engine).last == String(startIndex + 1) }
            #expect(startIds(env.engine).last == String(startIndex + 1),
                    "next() from \(startIndex) must START passage \(startIndex + 1)")

            
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


    @Test("next() does NOT re-activate the audio session — activated exactly once for the session")
    func nextDoesNotReactivateSession() async {
        let fakeConfig = FakeAudioSessionConfigurator()
        let bridge = makeRealEngineBridge(configurator: fakeConfig)

        await bridge.start(paragraphs: ["alpha", "bravo", "charlie"])
        await waitUntil(timeout: 2) { fakeConfig.activeCalls.contains { $0.active } }
        #expect(fakeConfig.activeCalls.filter { $0.active }.count == 1,
                "session must be activated exactly once on session start; activeCalls=\(fakeConfig.activeCalls)")

        
        await bridge.next()
        
        
        await waitUntil(timeout: 1) { false }

        #expect(fakeConfig.activeCalls.filter { $0.active }.count == 1,
                "next() must NOT re-activate the session on a switch; activeCalls=\(fakeConfig.activeCalls)")
        await bridge.stop()
    }
}


private struct InfiniteChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { _ in }
    }
}


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
        coordinator: coordinator,
        onPassageChange: { _ in }
    )
}
