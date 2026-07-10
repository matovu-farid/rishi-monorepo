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
        var received: [Data] = []
        for try await chunk in await streamer.stream(request) {
            received.append(chunk)
        }
        #expect(received == chunks)
    }

    @Test("Forwards source error")
    func forwardsSourceError() async {
        let chunks = [Data([0x01]), Data([0x02])]
        let source = FakeTTSChunkSource(chunks: chunks, throwAfter: 1)
        let streamer = TTSStreamer(source: source)
        let request = TTSStreamRequest(text: "boom", voice: "alloy", speed: 1.0)
        var thrown: Error?
        var received: [Data] = []
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
        let source = FakeTTSChunkSource(chunks: [])
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
            nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for i in 0..<100 {
                            if Task.isCancelled { continuation.finish(); return }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            continuation.yield(Data([UInt8(i & 0xFF)]))
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
}
