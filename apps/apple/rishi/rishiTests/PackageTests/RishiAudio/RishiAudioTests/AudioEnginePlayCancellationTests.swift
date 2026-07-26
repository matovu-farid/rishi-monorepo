@testable import rishi
import Foundation
import Testing
#if canImport(AVFAudio)
import AVFAudio


/// Locks in the structural-cleanup contract of `AudioEngineProtocol.play(_:)`:
///
/// 1. When the task consuming the returned `AsyncStream<PCMChunk.ID>` is
///    cancelled, the stream finishes within a tight time bound (no hang).
/// 2. After mid-play cancellation, `engine.stop()` remains reachable without
///    hanging.
///
/// Phase 23 promised these properties when the protocol moved from the
/// pre-refactor schedule + escaping-closure shape to AsyncSequence-in /
/// AsyncStream-out. The test asserts them against the production-faithful
/// `FakeAudioEngine` so a future regression (e.g. dropping the
/// `continuation.onTermination = { _ in task.cancel() }` line inside the
/// adapter or the fake) fails loudly here.
@Suite("AudioEngineProtocol.play(_:) cancellation contract")
struct AudioEnginePlayCancellationTests {

    /// Builds a single throwaway PCMChunk for a fake input stream.
    /// `FakeAudioEngine.play(_:)` never touches the buffer contents — only
    /// `chunk.id` / `chunk.passageId` / `chunk.isFinal` — so a 1-frame
    /// placeholder buffer is sufficient.
    private func makeChunk(passageId: String? = nil, isFinal: Bool = false) -> PCMChunk {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1)!
        buffer.frameLength = 1
        return PCMChunk(buffer: buffer, passageId: passageId, isFinal: isFinal)
    }

    @Test("Cancelling the consuming task ends the completions stream within 100 ms")
    func cancellationEndsStreamQuickly() async throws {
        let engine = FakeAudioEngine()

        // Never-ending input stream: a continuation that yields one chunk and
        // then is intentionally never finished. The consuming task must cancel
        // out of this — that is the contract under test.
        let (inputStream, inputContinuation) = AsyncStream<PCMChunk>.makeStream()
        inputContinuation.yield(makeChunk(passageId: "p1", isFinal: false))
        // intentionally never call inputContinuation.finish()

        let completions = engine.play(inputStream)

        // Spawn a consumer task that drains completions; it will be cancelled
        // by this test.
        let consumer = Task { () -> Int in
            var observed = 0
            for await _ in completions {
                observed += 1
            }
            return observed
        }

        // Give the consumer a beat to start, then cancel.
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()

        // Measure how long it takes the consumer's `for await` to exit after
        // cancel(). Bound: must be well under 100 ms — the AsyncStream's
        // `onTermination` hook should cancel the input-consumption task,
        // which finishes the continuation, which lets the consumer's for-await
        // exit.
        let clock = ContinuousClock()
        let exitStart = clock.now
        _ = await consumer.value
        let exitElapsed = clock.now - exitStart

        #expect(
            exitElapsed < .milliseconds(100),
            "Consumer did not exit within 100 ms of cancel; elapsed=\(exitElapsed)"
        )

        // engine.stop() must be reachable without hanging after cancellation.
        let stopStart = clock.now
        engine.stop()
        let stopElapsed = clock.now - stopStart

        #expect(
            stopElapsed < .milliseconds(50),
            "engine.stop() did not return promptly after cancellation; elapsed=\(stopElapsed)"
        )

        // Sanity: the calls log includes .playStarted and .stop. Do not assert
        // on .chunkSeen ordering — depending on scheduling, the single yielded
        // chunk may or may not have made it through the inner Task before the
        // cancel landed.
        #expect(engine.calls.contains(.playStarted))
        #expect(engine.calls.contains(.stop))

        // Keep the producer-side continuation alive until end of test so ARC
        // does not race with the consumer's cancellation path.
        _ = inputContinuation
    }
}
#endif
