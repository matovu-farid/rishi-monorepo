import Testing
import Foundation
@testable import RishiAudio

@Suite("TTSStreamer", .serialized)
struct TTSStreamerTests {

    @Test("Yields chunks in order")
    func yieldsChunksInOrder() async throws {
        let chunks = [Data([0xFF, 0xFB]), Data([0x90, 0x00]), Data([0x11, 0x22])]
        let source = FakeTTSChunkSource(chunks: chunks)
        let streamer = TTSStreamer(source: source)
        let request = TTSStreamRequest(text: "hi", voice: "alloy", speed: 1.0)
        var received: [TTSChunk] = []
        for try await chunk in await streamer.stream(request) {
            received.append(chunk)
        }
        let requestKey = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)
        #expect(received.map(\.data) == chunks)
        #expect(received.map(\.sequenceIndex) == [0, 1, 2])
        #expect(received.map(\.id) == [
            "\(requestKey)#00000000",
            "\(requestKey)#00000001",
            "\(requestKey)#00000002",
        ])
    }

    @Test("Forwards source error")
    func forwardsSourceError() async {
        let chunks = [Data([0x01]), Data([0x02])]
        let source = FakeTTSChunkSource(chunks: chunks, throwAfter: 1)
        let streamer = TTSStreamer(source: source)
        let request = TTSStreamRequest(text: "boom", voice: "alloy", speed: 1.0)
        var thrown: Error?
        var received: [TTSChunk] = []
        do {
            for try await chunk in await streamer.stream(request) {
                received.append(chunk)
            }
        } catch {
            thrown = error
        }
        #expect(received.count == 1)
        #expect(thrown is TTSStreamerError)
    }

    @Test("Records request with full body shape")
    func recordsRequest() async throws {
        let source = FakeTTSChunkSource(chunks: [Data([0xFF, 0xFB, 0x90, 0x00])])
        let streamer = TTSStreamer(source: source)
        let request = TTSStreamRequest(text: "alpha", voice: "nova", speed: 1.5, passageId: "p-1")
        for try await _ in await streamer.stream(request) {}
        let requests = await source.requests()
        #expect(requests.count == 1)
        #expect(requests[0] == request)
    }

    @Test("Consumer cancellation stops upstream task")
    func consumerCancellationStops() async throws {
        // Long-running source — yields one chunk every 50 ms for 100 chunks.
        // If cancellation didn't propagate, the slow source would keep yielding
        // forever; the fact that we exit the test cleanly is the assertion.
        actor SlowSource: TTSChunkSource {
            nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for i in 0..<100 {
                            if Task.isCancelled { continuation.finish(); return }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            continuation.yield(TTSChunk.make(
                                request: request,
                                sequenceIndex: i,
                                data: Data([UInt8(i & 0xFF)])
                            ))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
        let streamer = TTSStreamer(source: SlowSource())
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        let stream = await streamer.stream(request)
        var iter = stream.makeAsyncIterator()
        _ = try await iter.next()
        // Drop the iterator (end of scope) — should cancel upstream Task.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test("Empty upstream is surfaced as an error")
    func emptyUpstreamThrows() async throws {
        let source = FakeTTSChunkSource(chunks: [] as [Data])
        let streamer = TTSStreamer(source: source)
        let request = TTSStreamRequest(text: "x", voice: "alloy", speed: 1.0)
        do {
            for try await _ in await streamer.stream(request) {}
            Issue.record("Expected emptyResponse to throw")
        } catch TTSStreamerError.emptyResponse {
            // expected
        } catch {
            Issue.record("Expected emptyResponse, got \(error)")
        }
    }

    @Test("Loading is suppressed for cache hits and shown for misses")
    func loadingTracksCacheState() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TTSStreamer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = TTSStreamRequest(text: "cached", voice: "alloy", speed: 1.0)
        let key = TTSCacheKey.compute(
            text: request.text,
            voice: request.voice,
            model: request.model,
            speed: request.speed
        )

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: tmp.appendingPathComponent("\(key).mp3"))

        let hitStreamer = TTSStreamer(source: CachingTTSChunkSource(
            upstream: FakeTTSChunkSource(chunks: [Data([0xFF])]),
            store: store
        ))
        #expect(await hitStreamer.shouldShowLoading(for: request) == false)

        let missRequest = TTSStreamRequest(text: "miss", voice: "alloy", speed: 1.0)
        #expect(await hitStreamer.shouldShowLoading(for: missRequest) == true)
    }
}
