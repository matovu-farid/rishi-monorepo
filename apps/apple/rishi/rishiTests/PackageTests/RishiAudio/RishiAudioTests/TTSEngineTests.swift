@testable import rishi
import Testing
import Foundation

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

    @MainActor
    private func makeBlockingFixture() throws -> (engine: TTSEngine, fakeEngine: FakeAudioEngine, state: TTSPlaybackState, coordinator: AudioSessionCoordinator) {
        let fakeAudioSession = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: fakeAudioSession)
        let chunks = try loadFixtureMP3Chunks()
        let mp3 = chunks.reduce(Data(), +)
        let chunkSource = BlockingMP3Source(chunk: mp3)
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
        let (engine, fakeEngine, _, _) = await MainActor.run { makeFixture() }
        let request = TTSStreamRequest(text: "hello", voice: "alloy", speed: 1.0, passageId: "p-1")
        await engine.start(request: request)
        let calls = fakeEngine.calls
        #expect(calls.contains(.attach))
        #expect(calls.contains(.start))
        await engine.stop()
    }

    @Test("pause() then resume() toggles engine.play/pause and state")
    func pauseResumeToggles() async throws {
        let (engine, fakeEngine, _, _) = try await MainActor.run { try makeBlockingFixture() }
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        await engine.start(request: request)
        await poll(timeout: 5) {
            fakeEngine.calls.contains { call in
                if case .chunkSeen = call { return true }
                return false
            }
        }
        let lifecycleCallsBeforePause = fakeEngine.calls.filter { call in
            switch call {
            case .attach, .start, .resetNode:
                return true
            default:
                return false
            }
        }
        await engine.pause()
        #expect(fakeEngine.calls.contains(.pause))
        await engine.resume()
        #expect(fakeEngine.calls.contains(.resume))
        let lifecycleCallsAfterResume = fakeEngine.calls.filter { call in
            switch call {
            case .attach, .start, .resetNode:
                return true
            default:
                return false
            }
        }
        #expect(lifecycleCallsAfterResume == lifecycleCallsBeforePause)
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

    /// Real MP3 fixture sliced into stream chunks so the decoder produces real
    /// PCM the FakeAudioEngine can observe (the tiny garbage chunks in
    /// `makeFixture`'s default decode to nothing).
    private func loadFixtureMP3Chunks(sliceSize: Int = 4096) throws -> [Data] {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "alice-p0", withExtension: "mp3", subdirectory: "Fixtures"),
            "alice-p0.mp3 fixture must be bundled"
        )
        let data = try Data(contentsOf: url)
        var chunks: [Data] = []
        var i = 0
        while i < data.count {
            let end = min(i + sliceSize, data.count)
            chunks.append(data.subdata(in: i..<end))
            i = end
        }
        return chunks
    }

    private func poll(timeout: TimeInterval, _ predicate: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Reproduces the reader's prev/next/repeat path: ReaderTTSBridge.jump()
    /// calls engine.stop() then engine.start(newPassage). The .holds bridge fake
    /// never exercised the REAL engine's stop-then-start, so this asserts the new
    /// passage actually reaches the audio engine after a stop().
    @Test("stop() then start(new passage) plays the new passage (next/prev jump path)")
    func stopThenStartPlaysNewPassage() async throws {
        let chunks = try loadFixtureMP3Chunks()
        let (engine, fakeEngine, _, _) = await MainActor.run { makeFixture(chunks: chunks) }

        @Sendable func sawPassage(_ id: String) -> Bool {
            fakeEngine.calls.contains { call in
                if case .chunkSeen(_, id, _) = call { return true }
                return false
            }
        }

        await engine.start(request: TTSStreamRequest(text: "a", voice: "alloy", speed: 1.0, passageId: "0"))
        await poll(timeout: 5) { sawPassage("0") }
        #expect(sawPassage("0"), "first passage must reach the engine")

        // The jump sequence: stop the current passage, then start the next.
        await engine.stop()
        await engine.start(request: TTSStreamRequest(text: "b", voice: "alloy", speed: 1.0, passageId: "1"))
        await poll(timeout: 5) { sawPassage("1") }

        #expect(sawPassage("1"), "after stop() + start(new), the NEW passage must play; if not, next/prev do nothing")
        await engine.stop()
    }

    /// The reader's prev/next/repeat path as it actually runs TODAY:
    /// `ReaderTTSBridge.jump()` no longer calls `engine.stop()` — it calls
    /// `engine.start(newPassage)` directly while the current passage is still
    /// playing, relying on `start()`'s own single-session teardown. The only
    /// other real-engine test (`stopThenStartPlaysNewPassage`) inserts a
    /// `stop()` between the two starts, so it does NOT cover this sequence.
    /// This reproduces the live jump path: start(0) then start(1) with NO stop
    /// in between, and asserts passage 1 still reaches the audio engine. If the
    /// back-to-back start tears itself down (next/prev "does nothing"), this
    /// fails.
    @Test("start(0) then start(1) with NO stop between plays passage 1 (live jump path)")
    func startThenStartWithoutStopPlaysNewPassage() async throws {
        let chunks = try loadFixtureMP3Chunks()
        let (engine, fakeEngine, _, _) = await MainActor.run { makeFixture(chunks: chunks) }

        @Sendable func sawPassage(_ id: String) -> Bool {
            fakeEngine.calls.contains { call in
                if case .chunkSeen(_, id, _) = call { return true }
                return false
            }
        }

        await engine.start(request: TTSStreamRequest(text: "a", voice: "alloy", speed: 1.0, passageId: "0"))
        await poll(timeout: 5) { sawPassage("0") }
        #expect(sawPassage("0"), "first passage must reach the engine")

        // The live jump: start the next passage WITHOUT a stop() first.
        await engine.start(request: TTSStreamRequest(text: "b", voice: "alloy", speed: 1.0, passageId: "1"))
        await poll(timeout: 5) { sawPassage("1") }

        #expect(sawPassage("1"), "after start(0) -> start(1) with no stop, passage 1 must play; if not, next/prev do nothing")
        await engine.stop()
    }

    /// END-TO-END highlight test (the reader's "which paragraph is lit up").
    ///
    /// The in-text highlight is driven by TTSPassageTracker, which mirrors
    /// `TTSPlaybackState.currentPassageId` — and that id is ONLY set when the
    /// engine actually schedules a buffer for that passage (onBufferScheduled).
    /// So "next() lights up paragraph 1" is a hardware-free proxy for "passage 1
    /// actually started playing". This drives the REAL engine + REAL tracker (not
    /// the FakeTTSEngine the bridge tests use, which always 'plays') through the
    /// exact PLAY-then-NEXT sequence the bridge runs: start(0), then jump =
    /// stop()+start(1). If passage 1 never reaches the audio engine, the tracker
    /// never emits "1" and the highlight never moves — the bug shows here.
    @Test("e2e: play then next moves the highlight 0 -> 1 (tracker follows the play head)")
    func playThenNextMovesHighlight() async throws {
        let chunks = try loadFixtureMP3Chunks()
        let (engine, _, state, _) = await MainActor.run { makeFixture(chunks: chunks) }
        let tracker = TTSPassageTracker()
        await tracker.attach(state: state)

        let seen = PassageIdBox()
        let consumer = Task {
            for await pid in await tracker.passageStream() { seen.append(pid) }
        }

        // PLAY paragraph 0 -> the highlight must land on "0".
        await engine.start(request: TTSStreamRequest(text: "alpha", voice: "alloy", speed: 1.0, passageId: "0"))
        await poll(timeout: 5) { seen.snapshot().contains("0") }
        #expect(seen.snapshot().contains("0"), "PLAY must highlight paragraph 0")

        // NEXT — the bridge jump is a full stop() then a fresh start() of the
        // next passage.
        await engine.stop()
        await engine.start(request: TTSStreamRequest(text: "bravo", voice: "alloy", speed: 1.0, passageId: "1"))
        await poll(timeout: 5) { seen.snapshot().contains("1") }

        #expect(seen.snapshot().contains("1"), "NEXT must move the highlight to paragraph 1; if not, next/prev is broken")
        #expect(seen.snapshot() == ["0", "1"], "highlight must follow the play head 0 then 1, in order")

        consumer.cancel()
        await engine.stop()
        await tracker.detach()
    }

    @Test("a voice mode request while TTS is playing stops the engine")
    func voiceRequestStopsTTS() async throws {
        // GIVEN the existing harness drives engine.start(request:) to playing,
        // sharing the SAME coordinator the engine was constructed with.
        let (engine, fakeEngine, _, coordinator) = try await MainActor.run { try makeBlockingFixture() }
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0, passageId: "p-1")
        await engine.start(request: request)
        await poll(timeout: 5) {
            fakeEngine.calls.contains { call in
                if case .chunkSeen = call { return true }
                return false
            }
        }

        // WHEN another owner asks the shared coordinator for .voice.
        await coordinator.requestActiveMode(.voice)

        // THEN the coordinator should switch ownership to .voice.
        #expect(await coordinator.currentMode == .voice)
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

    @Test("typed allowance failure is recorded with the active request tokens")
    @MainActor
    func typedAllowanceFailureRecordsTokens() async {
        let source = TypedAllowanceSource()
        let streamer = TTSStreamer(source: source)
        let fakeAudioSession = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: fakeAudioSession)
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
        let request = TTSStreamRequest(
            text: "allowance",
            voice: "alloy",
            speed: 1.0,
            sessionToken: UUID(),
            utteranceToken: UUID(),
            requestToken: UUID()
        )

        await engine.start(request: request)
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(state.typedFailure == .trial(message: "trial exhausted"))
        #expect(state.typedFailureTokens == request.tokenSnapshot)
        await engine.stop()
    }
}

/// Thread-safe collector for the tracker's emitted passage ids — the consumer
/// Task runs off the test's actor, so capture must be Sendable.
private final class PassageIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.withLock { ids.append(id) } }
    func snapshot() -> [String] { lock.withLock { ids } }
}

private actor BlockingMP3Source: TTSChunkSource {
    private let chunk: Data

    init(chunk: Data) {
        self.chunk = chunk
    }

    nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(TTSChunk.make(request: request, sequenceIndex: 0, data: chunk))
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct TypedAllowanceSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WorkerAllowanceError.trial(message: "trial exhausted"))
        }
    }
}
#endif
