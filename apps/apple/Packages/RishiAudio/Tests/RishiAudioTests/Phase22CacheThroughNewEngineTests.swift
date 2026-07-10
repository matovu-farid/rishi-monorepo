import Foundation
import Testing
#if canImport(AVFAudio)
import AVFAudio
@testable import RishiAudio

/// Phase 22 ↔ Phase 23 orthogonality proof.
///
/// Phase 22 shipped a cache at the `TTSChunkSource` seam
/// (`CachingTTSChunkSource` + `TTSAudioCacheStore`); Phase 23 reshaped the
/// engine seam (`AudioEngineProtocol.play(_:)` returning
/// `AsyncStream<PCMChunk.ID>`). The two layers compose if and only if
/// cache-fed bytes flow into the new engine shape without either layer
/// special-casing the other.
///
/// This test wires:
///
/// ```
/// FailingUpstream  ──→  CachingTTSChunkSource (hit)  ──→  Data chunks
///                                                         │
///                                                         ▼
///                                       wrap each Data as a PCMChunk
///                                                         │
///                                                         ▼
///                                            FakeAudioEngine.play(_:)
/// ```
///
/// `FailingUpstream` throws if invoked — that proves the cache hit short-
/// circuited it. The wrap-as-PCMChunk step takes the place of
/// `MP3StreamDecoder`: the orthogonality claim is about the data flow
/// (cache yields bytes, engine consumes chunks), not specifically about
/// libmp3lame. A separate suite (`MP3StreamDecoderTests`) already covers
/// the decoder contract; coupling this test to a real MP3 fixture would
/// add a flaky filesystem dependency without strengthening the
/// orthogonality claim.
///
/// Assertions:
///
/// 1. `FakeAudioEngine.calls` contains `.playStarted` — the new engine
///    shape was invoked.
/// 2. `FakeAudioEngine.calls` contains at least one `.chunkSeen(...)` —
///    chunks reached the engine.
/// 3. Each `.chunkSeen(id:_:_:)` is paired with a matching
///    `.completionEmitted(id:)` — the AsyncStream contract holds end-to-end.
/// 4. `FailingUpstream` was never invoked (no upstream throw observed) —
///    the cache short-circuit worked.
@Suite("Phase 22 cache through Phase 23 engine — orthogonality", .serialized)
struct Phase22CacheThroughNewEngineTests {

    // MARK: - Test doubles

    /// Upstream that fails loudly if asked. If a cache hit short-circuits
    /// the lookup, this is never invoked; if it is invoked, the throw will
    /// propagate through `CachingTTSChunkSource` and the cached-byte stream
    /// will terminate before any chunks reach the engine — caught by
    /// assertion 2 (no `.chunkSeen`).
    private struct FailingUpstream: TTSChunkSource {
        struct WasCalled: Error {}
        func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: WasCalled())
            }
        }
    }

    // MARK: - Helpers

    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Phase22Orthogonality-\(UUID().uuidString)", isDirectory: true)
    }

    /// Builds a 1-frame placeholder PCMChunk. `FakeAudioEngine.play(_:)`
    /// never touches buffer contents — only `chunk.id` / `chunk.passageId` /
    /// `chunk.isFinal` — so the buffer's bytes are irrelevant; we just need
    /// one PCMChunk per cached-data chunk.
    private func makePCMChunk(passageId: String?, isFinal: Bool) -> PCMChunk {
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

    // MARK: - Test

    @Test("Cache-hit bytes flow through engine.play(_:) end-to-end without invoking upstream")
    func cacheHitDrivesNewEngineShape() async throws {
        // 1. Build a temp cache directory and a TTSAudioCacheStore over it.
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)

        // 2. Build a TTSStreamRequest and seed the cache file at the key
        //    Phase 22 would compute for it. This is the same seed pattern
        //    used in CachingTTSChunkSourceTests.hitSkipsUpstream.
        let request = TTSStreamRequest(
            text: "The quick brown fox.",
            voice: "alloy",
            model: "eleven_v3",
            speed: 1.0,
            passageId: "p-orthogonality"
        )
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)
        let seeded = Data((0..<8192).map { UInt8($0 % 256) })
        try seeded.write(to: tmp.appendingPathComponent("\(key).mp3"))

        // 3. Wire CachingTTSChunkSource over a FailingUpstream — if cache
        //    short-circuit fails, the upstream throw will surface as zero
        //    chunks reaching the engine.
        let cachingSource = CachingTTSChunkSource(
            upstream: FailingUpstream(),
            store: store
        )

        // 4. Drain the cache-fed Data chunks into a PCMChunk AsyncStream.
        //    This step stands in for MP3StreamDecoder; the orthogonality
        //    proof is about the *flow* (cache → chunk → engine), not the
        //    specifics of MP3 decoding. The decoder is covered separately
        //    by MP3StreamDecoderTests.
        let (pcmStream, pcmContinuation) = AsyncStream<PCMChunk>.makeStream()

        let producer = Task { [self] in
            do {
                var bytesSeen = 0
                for try await chunk in cachingSource.stream(request: request) {
                    bytesSeen += chunk.count
                    pcmContinuation.yield(
                        makePCMChunk(passageId: request.passageId, isFinal: false)
                    )
                }
                // Emit a terminal final-chunk marker so engine.play(_:)'s inner
                // for-await sees a clean end signal.
                pcmContinuation.yield(
                    makePCMChunk(passageId: request.passageId, isFinal: true)
                )
                pcmContinuation.finish()
                return bytesSeen
            } catch {
                // Surface upstream-was-called as a zero-bytes result so the
                // assertions below can catch it.
                pcmContinuation.finish()
                return -1
            }
        }

        // 5. Drive the chunks through the new Phase 23 engine shape.
        let engine = FakeAudioEngine()
        var observedCompletions = 0
        for await _ in engine.play(pcmStream) {
            observedCompletions += 1
        }

        let bytesSeen = await producer.value

        // 6. Assertions.
        #expect(bytesSeen > 0, "Cache hit path produced zero bytes — FailingUpstream was likely invoked")
        #expect(bytesSeen == seeded.count, "Cache should have streamed back the full seeded payload byte-for-byte; got \(bytesSeen), expected \(seeded.count)")

        let calls = engine.calls

        #expect(calls.contains(.playStarted), "engine.play(_:) was not invoked")

        let chunkSeenIds: [UUID] = calls.compactMap { call in
            if case let .chunkSeen(id, _, _) = call { return id }
            return nil
        }
        let completionEmittedIds: [UUID] = calls.compactMap { call in
            if case let .completionEmitted(id) = call { return id }
            return nil
        }

        #expect(!chunkSeenIds.isEmpty, "No chunks reached the engine — cache short-circuit failed")
        #expect(
            chunkSeenIds == completionEmittedIds,
            "Per-chunk completion ids do not match per-chunk seen ids — AsyncStream id round-trip broken"
        )
        #expect(
            observedCompletions == chunkSeenIds.count,
            "Observed completion count (\(observedCompletions)) does not match .chunkSeen count (\(chunkSeenIds.count))"
        )
    }
}
#endif
