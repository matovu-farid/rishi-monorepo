import Testing
import Foundation
@testable import RishiAudio
#if canImport(AVFAudio)
import AVFAudio

@Suite("TTSEngine", .serialized)
struct TTSEngineTests {

    @MainActor
    private func makeFixture(
        chunks: [Data] = [Data([0xFF, 0xFB, 0x90, 0x00]), Data([0x01, 0x02, 0x03, 0x04])],
        throwAfter: Int? = nil
    ) -> (engine: TTSEngine, fakeEngine: FakeAudioEngine, state: TTSPlaybackState, coordinator: AudioSessionCoordinator) {
        let fakeAudioSession = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: fakeAudioSession)
        let chunkSource = FakeTTSChunkSource(chunks: chunks, throwAfter: throwAfter)
        let streamer = TTSStreamer(source: chunkSource)
        let fakeEngine = FakeAudioEngine()
        let decoderFactory: TTSEngine.DecoderFactory = { format in
            try MP3StreamDecoder(targetFormat: format)
        }
        let state = TTSPlaybackState()
        let engine = TTSEngine(
            streamer: streamer,
            decoderFactory: decoderFactory,
            engine: fakeEngine,
            coordinator: coordinator,
            state: state
        )
        return (engine, fakeEngine, state, coordinator)
    }

    @Test("start() attaches + starts the engine and requests .tts mode")
    func startAttachesAndStarts() async {
        let (engine, fakeEngine, _, coordinator) = await MainActor.run { makeFixture() }
        let request = TTSStreamRequest(text: "hello", voice: "alloy", speed: 1.0, passageId: "p-1")
        await engine.start(request: request)
        // Check mode IMMEDIATELY after start() returns — start() awaits
        // coordinator.requestActiveMode(.tts) synchronously before spawning
        // the streaming/decoder Tasks, so the mode is .tts at this point.
        // (If we sleep first, the tiny garbage stream may complete and the
        // final-chunk drain in onBufferComplete will have released the mode
        // already — exactly the production contract we want.)
        let modeRightAfterStart = await coordinator.currentMode
        #expect(modeRightAfterStart == .tts)
        let calls = fakeEngine.calls
        #expect(calls.contains(.attach))
        #expect(calls.contains(.start))
        await engine.stop()
    }

    @Test("pause() then resume() toggles engine.play/pause and state")
    func pauseResumeToggles() async {
        let (engine, fakeEngine, state, _) = await MainActor.run { makeFixture() }
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        await engine.start(request: request)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await engine.pause()
        let paused = await MainActor.run { state.status }
        #expect(paused == .paused)
        #expect(fakeEngine.calls.contains(.pause))
        await engine.resume()
        let playing = await MainActor.run { state.status }
        #expect(playing == .playing)
        await engine.stop()
    }

    @Test("stop() releases mode and flips state to .stopped")
    func stopReleasesMode() async {
        let (engine, fakeEngine, state, coordinator) = await MainActor.run { makeFixture() }
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        await engine.start(request: request)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await engine.stop()
        let stopped = await MainActor.run { state.status }
        #expect(stopped == .stopped)
        #expect(fakeEngine.calls.contains(.stop))
        let mode = await coordinator.currentMode
        #expect(mode == .idle)
    }

    @Test("Streamer error transitions state to .error or .stopped")
    func streamerErrorTransitionsState() async {
        // throwAfter: 0 makes the FakeTTSChunkSource throw on the very first chunk.
        let (engine, _, state, _) = await MainActor.run {
            makeFixture(chunks: [Data([0xFF])], throwAfter: 0)
        }
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        await engine.start(request: request)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let final = await MainActor.run { state.status }
        // Either .error (preferred) or .stopped (if test completes too fast)
        #expect(final == .error || final == .stopped)
    }
}
#endif
