@testable import rishi
import Testing
import Foundation


/// Phase 24 orthogonality proof.
///
/// Claim: a `TTSPrewarmer` draining a `CachingTTSChunkSource` over a real
/// `TTSAudioCacheStore` causes the cache file to land on disk; a subsequent
/// player-style draw of the SAME request through the SAME caching source is
/// served from disk and does NOT re-hit the underlying worker source.
///
/// This test is the literal evidence that the prewarmer is byte-untouched-orthogonal
/// to the engine: nothing about the engine is exercised here. The cache layer is
/// the shared resource; warm and play are two independent consumers.
@Suite(.serialized)
struct Phase24PrewarmOrthogonalityTests {

    @Test
    func prewarm_writes_disk_then_player_draw_is_a_hit() async throws {
        // 1. Tmp dir + real cache store.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase24-orthogonality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try TTSAudioCacheStore(directory: tmpDir, capBytes: 10 * 1024 * 1024)

        // 2. Fake worker source + real caching wrapper.
        let workerBytes: [Data] = [
            Data("hello ".utf8),
            Data("world".utf8),
        ]
        let fakeWorker = FakeTTSChunkSource(chunks: workerBytes)
        let cachingSource = CachingTTSChunkSource(upstream: fakeWorker, store: store)

        // 3. Real prewarmer over the caching source.
        let prewarmer = TTSPrewarmer(source: cachingSource)

        // 4. Build the paragraph-N+1 request and compute its expected key.
        let req = TTSStreamRequest(
            text: "Paragraph N plus one body text.",
            voice: "alloy",
            model: "eleven_v3",
            speed: 1.0,
            passageId: nil
        )
        let key = TTSCacheKey.compute(text: req.text, voice: req.voice, model: req.model, speed: req.speed)
        let expectedURL = tmpDir.appendingPathComponent("\(key).mp3", isDirectory: false)

        // 5. Warm. The warm call returns once the per-request Task is spawned;
        //    poll for the disk file to appear (the drain runs in a Task).
        await prewarmer.warm(requests: [req])

        let warmedDeadline = Date().addingTimeInterval(2.0)
        while Date() < warmedDeadline {
            if FileManager.default.fileExists(atPath: expectedURL.path) {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }
        #expect(FileManager.default.fileExists(atPath: expectedURL.path), "prewarm must produce \(expectedURL.path)")

        // 6. Confirm the worker was called exactly once during warm.
        let warmCalls = await fakeWorker.requests()
        #expect(warmCalls.count == 1, "expected 1 worker call during warm; got \(warmCalls.count)")
        #expect(warmCalls.first?.text == req.text)

        // 7. Player-side draw of the SAME request through the SAME caching source.
        //    This simulates `engine.start(request:)` in production; the engine itself
        //    is NOT exercised here -- the orthogonality claim is about the cache + sources.
        var playerByteCount = 0
        for try await chunk in cachingSource.stream(request: req) {
            playerByteCount += chunk.count
        }

        // 8. Disk hit -- worker call count must still be 1.
        let afterPlayerCalls = await fakeWorker.requests()
        #expect(afterPlayerCalls.count == 1, "player draw must be served from disk -- worker count must stay at 1; got \(afterPlayerCalls.count)")

        // 9. Player saw some bytes (no quantity assertion -- the cache reads in 16 KiB
        //    chunks per the hit-path, possibly fewer if the file is tiny).
        let totalWorkerBytes = workerBytes.reduce(0) { $0 + $1.count }
        #expect(playerByteCount == totalWorkerBytes, "player byte count must equal worker byte count")
    }

    @Test
    func prewarm_window_with_empty_input_is_safe_noop() async throws {
        // End-of-page case: bridge calls warm(requests: []) when the window is empty.
        // Must not crash, must not call upstream.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase24-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = try TTSAudioCacheStore(directory: tmpDir, capBytes: 1024 * 1024)
        let fakeWorker = FakeTTSChunkSource(chunks: [Data("x".utf8)])
        let cachingSource = CachingTTSChunkSource(upstream: fakeWorker, store: store)
        let prewarmer = TTSPrewarmer(source: cachingSource)

        await prewarmer.warm(requests: [])

        // Settle window (no Tasks should have been spawned).
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        let calls = await fakeWorker.requests()
        #expect(calls.isEmpty, "warm([]) must spawn no Tasks and call no upstream")
    }
}
