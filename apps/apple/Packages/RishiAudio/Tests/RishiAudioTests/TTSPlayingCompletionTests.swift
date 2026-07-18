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
