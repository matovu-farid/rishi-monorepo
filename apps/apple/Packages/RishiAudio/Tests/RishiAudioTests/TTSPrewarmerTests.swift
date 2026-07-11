import Testing
import Foundation
@testable import RishiAudio

@Suite("TTSPrewarmer", .serialized)
struct TTSPrewarmerTests {

    // MARK: - Helpers

    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TTSPrewarmer-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeRequest(text: String = "hello world",
                             voice: String = "alloy",
                             speed: Double = 1.0) -> TTSStreamRequest {
        TTSStreamRequest(text: text, voice: voice, speed: speed, passageId: nil)
    }

    /// Poll `prewarmer.inFlightCount` until it reaches 0 or the budget elapses.
    /// Returns true if it settled in time.
    private func waitForSettle(_ prewarmer: TTSPrewarmer, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await prewarmer.inFlightCount == 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        return await prewarmer.inFlightCount == 0
    }

    // MARK: - 1. warm drives source.stream(request:) once per request

    @Test("warm drives source.stream per request")
    func warm_drives_source_stream_per_request() async throws {
        let fake = FakeTTSChunkSource(chunks: [Data("a".utf8), Data("b".utf8)])
        let prewarmer = TTSPrewarmer(source: fake)

        let req1 = makeRequest(text: "alpha")
        let req2 = makeRequest(text: "bravo")
        let req3 = makeRequest(text: "charlie")

        await prewarmer.warm(requests: [req1, req2, req3])

        let settled = await waitForSettle(prewarmer, timeout: 1.0)
        #expect(settled, "all prewarm tasks should settle within 1s")

        let received = await fake.requests()
        #expect(received.count == 3)
        let texts = Set(received.map(\.text))
        #expect(texts == Set(["alpha", "bravo", "charlie"]))
    }

    // MARK: - 2. cache-miss writes <key>.mp3 to disk

    @Test("cache miss writes mp3 to disk")
    func cache_miss_writes_mp3_to_disk() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let req = makeRequest(text: "needs synthesis", voice: "alloy", speed: 1.0)
        let key = TTSCacheKey.compute(text: req.text, voice: req.voice, model: req.model, speed: req.speed)

        let fake = FakeTTSChunkSource(chunks: [Data("hello".utf8), Data("world".utf8)])
        let cachingSource = CachingTTSChunkSource(upstream: fake, store: store)
        let prewarmer = TTSPrewarmer(source: cachingSource)

        await prewarmer.warm(requests: [req])

        // Poll until the on-disk file <key>.mp3 exists (NOT .partial).
        let finalURL = tmp.appendingPathComponent("\(key).mp3")
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: finalURL.path) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: finalURL.path),
                "cache miss should result in <key>.mp3 written to disk under tmp dir")

        let settled = await waitForSettle(prewarmer, timeout: 1.0)
        #expect(settled, "prewarmer should settle after disk write completes")
    }

    // MARK: - 3. cache-hit does NOT call upstream

    @Test("cache hit does not call upstream")
    func cache_hit_does_not_call_upstream() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let req = makeRequest(text: "already cached", voice: "alloy", speed: 1.0)
        let key = TTSCacheKey.compute(text: req.text, voice: req.voice, model: req.model, speed: req.speed)

        // Pre-populate the cache by writing <key>.mp3 directly.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("precached".utf8).write(to: tmp.appendingPathComponent("\(key).mp3"))

        let fake = FakeTTSChunkSource(chunks: [Data("should-not-be-read".utf8)])
        let cachingSource = CachingTTSChunkSource(upstream: fake, store: store)
        let prewarmer = TTSPrewarmer(source: cachingSource)

        await prewarmer.warm(requests: [req])

        let settled = await waitForSettle(prewarmer, timeout: 1.0)
        #expect(settled, "prewarmer should settle after cache-hit drain")

        let calls = await fake.requests()
        #expect(calls.isEmpty, "upstream MUST NOT be invoked on cache hit")
    }

    // MARK: - 4. cancelAll() cancels in-flight tasks within 100ms (200ms cushion)

    @Test("cancelAll cancels in-flight tasks within 100ms")
    func cancelAll_cancels_inflight_within_100ms() async throws {
        let blocking = BlockingFakeChunkSource()
        let prewarmer = TTSPrewarmer(source: blocking)
        let req = makeRequest(text: "blocking", voice: "alloy", speed: 1.0)

        await prewarmer.warm(requests: [req])

        // Let the task reach the suspend point inside the stream.
        try await Task.sleep(nanoseconds: 50_000_000)

        let t0 = Date()
        await prewarmer.cancelAll()

        let settled = await waitForSettle(prewarmer, timeout: 1.0)
        let elapsed = Date().timeIntervalSince(t0)

        #expect(settled, "tasks should settle after cancelAll")
        #expect(elapsed < 0.2, "cancelAll should cooperatively unwind under 200ms (target 100ms); was \(elapsed)s")
    }
}

// MARK: - Blocking fake source used only by cancelAll test

/// A `TTSChunkSource` whose `stream(request:)` yields ONE chunk then suspends on a
/// 60-second sleep. Used to prove cooperative cancellation by `TTSPrewarmer.cancelAll()`.
private actor BlockingFakeChunkSource: TTSChunkSource {
    nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(TTSChunk.make(
                    request: request,
                    sequenceIndex: 0,
                    data: Data([0x01])
                ))
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
