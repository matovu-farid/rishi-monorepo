import Foundation
import Testing
@testable import rishi

#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AudioToolbox

@Suite("Chunked audio player TTS engine", .serialized)
struct ChunkedAudioPlayerTTSEngineTests {
    @Test("typed allowance failure is recorded before player failure can become stopped")
    @MainActor
    func typedAllowanceFailureIsSticky() async {
        let state = TTSPlaybackState()
        let streamer = TTSStreamer(source: TypedAllowanceSource())
        let engine = ChunkedAudioPlayerTTSEngine(streamer: streamer, state: state)
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

        #expect(state.typedFailure == .narration(message: "narration exhausted"))
        #expect(state.typedFailureTokens == request.tokenSnapshot)
        #expect(state.userFacingFailure == .narrationExhausted)
        #expect(state.status == .error)
        await engine.stop()
    }
}

private struct TypedAllowanceSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WorkerAllowanceError.narration(message: "narration exhausted"))
        }
    }
}
#endif
