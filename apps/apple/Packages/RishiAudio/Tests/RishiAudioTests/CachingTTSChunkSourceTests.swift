import Testing
import Foundation
@testable import RishiAudio

@Suite("CachingTTSChunkSource", .serialized)
struct CachingTTSChunkSourceTests {

    // MARK: - Helpers

    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CachingTTS-\(UUID().uuidString)", isDirectory: true)
    }

    private func consume(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var bytes = Data()
        for try await chunk in stream { bytes.append(chunk) }
        return bytes
    }

    private func makeRequest(text: String = "hello world",
                             voice: String = "alloy",
                             speed: Double = 1.0) -> TTSStreamRequest {
        TTSStreamRequest(text: text, voice: voice, speed: speed, passageId: nil)
    }

    // MARK: - 1. Hit serves from disk without invoking upstream

    @Test("hit serves from disk without invoking upstream")
    func hitSkipsUpstream() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, speed: request.speed)

        // Seed: write a known byte sequence to <key>.mp3 directly.
        let seeded = Data((0..<8192).map { UInt8($0 % 256) })
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try seeded.write(to: tmp.appendingPathComponent("\(key).mp3"))

        let upstream = FakeTTSChunkSource(chunks: [Data([0xFF])])  // sentinel — must NOT be yielded
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let received = try await consume(cache.stream(request: request))

        #expect(received == seeded)
        let upstreamCalls = await upstream.requests()
        #expect(upstreamCalls.isEmpty, "upstream MUST NOT be invoked on hit")
    }

    // MARK: - 2. Miss tees to disk; caller bytes == upstream bytes; file exists

    @Test("miss tees to disk and final file exists with full bytes")
    func missTeesToDisk() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, speed: request.speed)

        let upstreamChunks: [Data] = [
            Data([0x01, 0x02, 0x03]),
            Data([0x04, 0x05]),
            Data([0x06, 0x07, 0x08, 0x09]),
        ]
        let expectedConcatenated = upstreamChunks.reduce(Data(), +)
        let upstream = FakeTTSChunkSource(chunks: upstreamChunks)
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let received = try await consume(cache.stream(request: request))
        #expect(received == expectedConcatenated)

        let finalURL = tmp.appendingPathComponent("\(key).mp3")
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        let onDisk = try Data(contentsOf: finalURL)
        #expect(onDisk == expectedConcatenated)
    }

    // MARK: - 3. Second call after miss is a hit (upstream called exactly once)

    @Test("second call after miss is a hit")
    func secondCallIsHit() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let upstream = FakeTTSChunkSource(chunks: [Data([0xAA, 0xBB, 0xCC])])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        _ = try await consume(cache.stream(request: request))
        let after1 = await upstream.requests().count
        #expect(after1 == 1)

        _ = try await consume(cache.stream(request: request))
        let after2 = await upstream.requests().count
        #expect(after2 == 1, "upstream MUST stay at 1 invocation — second call is a hit")
    }

    // MARK: - 4. LRU eviction at cap

    @Test("LRU evicts oldest by modification date when total exceeds cap")
    func lruEviction() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1 MB cap so the math is small.
        let cap = 1 * 1024 * 1024
        let store = try TTSAudioCacheStore(directory: tmp, capBytes: cap)

        // Seed three .mp3 files each ~400 KB (total 1.2 MB > 1 MB cap).
        let blobSize = 400 * 1024
        let blob = Data(repeating: 0xAB, count: blobSize)

        let oldURL = tmp.appendingPathComponent("aaa.mp3")
        let midURL = tmp.appendingPathComponent("bbb.mp3")
        let newURL = tmp.appendingPathComponent("ccc.mp3")

        try blob.write(to: oldURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3000)], ofItemAtPath: oldURL.path)
        try blob.write(to: midURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2000)], ofItemAtPath: midURL.path)
        try blob.write(to: newURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1000)], ofItemAtPath: newURL.path)

        await store.evictIfOver()

        #expect(!FileManager.default.fileExists(atPath: oldURL.path), "oldest must be evicted")
        #expect(FileManager.default.fileExists(atPath: newURL.path), "newest must remain")
    }

    // MARK: - 5. Cancelled stream leaves no .mp3; next call is a miss

    @Test("cancelled stream leaves no .mp3 and next call is a miss")
    func cancelLeavesNoFinal() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, speed: request.speed)

        // Upstream that emits one chunk then would emit more — we cancel after the first.
        let upstream = FakeTTSChunkSource(chunks: [
            Data([0x01, 0x02, 0x03]),
            Data([0x04, 0x05, 0x06]),
            Data([0x07, 0x08, 0x09]),
        ])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let consumer = Task {
            var count = 0
            for try await _ in cache.stream(request: request) {
                count += 1
                if count >= 1 { break }  // bail out after first chunk -> triggers onTermination
            }
        }
        try await consumer.value
        // Give the cleanup task a moment to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        let finalURL = tmp.appendingPathComponent("\(key).mp3")
        #expect(!FileManager.default.fileExists(atPath: finalURL.path),
                "cancelled stream MUST NOT promote .partial to .mp3")

        // Next call must be a miss (upstream invoked a second time).
        _ = try await consume(cache.stream(request: request))
        let calls = await upstream.requests().count
        #expect(calls >= 2, "next stream after cancel must be a miss — upstream invoked again")
    }

    // MARK: - 6. Pre-existing .partial is invisible to read

    @Test("pre-existing .partial file is treated as a miss")
    func partialInvisibleToRead() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, speed: request.speed)

        // Seed only a .partial — NOT a .mp3.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: tmp.appendingPathComponent("\(key).mp3.partial"))

        let upstreamBytes = Data([0x42, 0x43])
        let upstream = FakeTTSChunkSource(chunks: [upstreamBytes])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let received = try await consume(cache.stream(request: request))
        #expect(received == upstreamBytes, "received bytes must come from upstream, not from .partial")

        let calls = await upstream.requests().count
        #expect(calls == 1, "pre-existing .partial MUST be invisible to read — upstream must be invoked")
    }
}
