@testable import rishi
import Testing
import Foundation


@Suite("CachingTTSChunkSource", .serialized)
struct CachingTTSChunkSourceTests {

    // MARK: - Helpers

    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CachingTTS-\(UUID().uuidString)", isDirectory: true)
    }

    private func consume(_ stream: AsyncThrowingStream<TTSChunk, Error>) async throws -> Data {
        var bytes = Data()
        for try await chunk in stream { bytes.append(chunk.data) }
        return bytes
    }

    private func consumeChunks(_ stream: AsyncThrowingStream<TTSChunk, Error>) async throws -> [TTSChunk] {
        var chunks: [TTSChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
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
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)

        // Seed: write a known byte sequence to <key>.mp3 directly.
        let seeded = Data((0..<8192).map { UInt8($0 % 256) })
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try seeded.write(to: tmp.appendingPathComponent("\(key).mp3"))

        let upstream = FakeTTSChunkSource(chunks: [Data([0xFF])])  // sentinel — must NOT be yielded
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let received = try await consumeChunks(cache.stream(request: request))
        let expectedChunks = [
            seeded.subdata(in: 0..<TTSChunk.streamChunkByteCount),
            seeded.subdata(in: TTSChunk.streamChunkByteCount..<seeded.count),
        ]
        let expectedIDs = [
            "\(key)#00000000",
            "\(key)#00000001",
        ]

        #expect(received.map(\.data) == expectedChunks)
        #expect(received.map(\.sequenceIndex) == [0, 1])
        #expect(received.map(\.id) == expectedIDs)
        let upstreamCalls = await upstream.requests()
        #expect(upstreamCalls.isEmpty, "upstream MUST NOT be invoked on hit")
    }

    @Test("concurrent cache hits replay the complete sequence to both consumers")
    func concurrentCacheHitsReplayCompleteSequence() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest(text: "concurrent cache hit")
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)
        let seeded = Data(repeating: 0xA1, count: TTSChunk.streamChunkByteCount * 3 + 7)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try seeded.write(to: tmp.appendingPathComponent("\(key).mp3"))

        let upstream = FakeTTSChunkSource(chunks: [Data([0xFF])])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)
        let firstStream = cache.stream(request: request)
        let secondStream = cache.stream(request: request)

        let firstConsumer = Task { try await consumeChunks(firstStream) }
        let secondConsumer = Task { try await consumeChunks(secondStream) }
        let first = try await firstConsumer.value
        let second = try await secondConsumer.value

        #expect(first.map(\.data).reduce(Data(), +) == seeded)
        #expect(second == first, "both concurrent cache-hit consumers must receive the same complete sequence")
        #expect(await upstream.requests().isEmpty, "cache hits must never invoke upstream")
    }

    // MARK: - 2. Miss tees to disk; caller bytes == upstream bytes; file exists

    @Test("miss tees to disk and final file exists with full bytes")
    func missTeesToDisk() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)

        let upstreamChunks: [Data] = [
            Data([0x01, 0x02, 0x03]),
            Data([0x04, 0x05]),
            Data([0x06, 0x07, 0x08, 0x09]),
        ]
        let expectedConcatenated = upstreamChunks.reduce(Data(), +)
        let upstream = FakeTTSChunkSource(chunks: upstreamChunks)
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let received = try await consumeChunks(cache.stream(request: request))
        #expect(received.map(\.data) == upstreamChunks)
        #expect(received.map(\.sequenceIndex) == [0, 1, 2])
        #expect(received.map(\.data).reduce(Data(), +) == expectedConcatenated)

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

        let first = try await consumeChunks(cache.stream(request: request))
        let after1 = await upstream.requests().count
        #expect(after1 == 1)

        let second = try await consumeChunks(cache.stream(request: request))
        let after2 = await upstream.requests().count
        #expect(after2 == 1, "upstream MUST stay at 1 invocation — second call is a hit")
        #expect(first == second, "cache hit must preserve chunk ordering and ids")
    }

    // MARK: - 4. Concurrent identical misses share one upstream stream

    @Test("concurrent identical cache misses coalesce upstream")
    func concurrentIdenticalMissesCoalesceUpstream() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest(text: "concurrent miss")
        let upstreamChunks = [
            Data([0x01, 0x02]),
            Data([0x03, 0x04, 0x05]),
            Data([0x06]),
        ]
        let upstream = BlockingAfterFirstChunkSource(chunks: upstreamChunks)
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let firstConsumer = Task {
            try await consumeChunks(cache.stream(request: request))
        }
        await upstream.waitForFirstChunk()

        let secondStream = cache.stream(request: request)
        let secondConsumer = Task {
            try await consumeChunks(secondStream)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await upstream.release()

        let first = try await firstConsumer.value
        let second = try await secondConsumer.value

        #expect(await upstream.requestCount() == 1, "identical overlapping misses must invoke upstream once")
        #expect(first.map(\.data) == upstreamChunks)
        #expect(second == first, "both consumers must receive the complete identical chunk sequence")
    }

    // MARK: - 5. LRU eviction at cap

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

    // MARK: - 6. A replacement request does not join a cancelled producer

    @Test("replacement request waits for cancelled producer to unwind")
    func replacementRequestDoesNotJoinCancelledProducer() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest(text: "cancel then retry")
        let upstream = CancellationWindowSource(chunks: [
            Data([0x01, 0x02]),
            Data([0x03, 0x04]),
        ])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        let firstConsumer = Task {
            try await consumeChunks(cache.stream(request: request))
        }
        await upstream.waitForFirstChunk()
        firstConsumer.cancel()
        _ = await firstConsumer.result
        await upstream.waitForCancellationObserved()

        let secondStream = cache.stream(request: request)
        let secondConsumer = Task {
            try await consumeChunks(secondStream)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await upstream.releaseCancellation()

        let secondResult = await secondConsumer.result
        guard case .success(let received) = secondResult else {
            #expect(Bool(false), "replacement request must not inherit the cancelled stream")
            return
        }

        #expect(received.map(\.data) == [Data([0x01, 0x02]), Data([0x03, 0x04])])
        #expect(await upstream.requestCount() == 2, "replacement should start after the cancelled producer unwinds")
        #expect(await upstream.maxConcurrentRequests() == 1, "replacement requests must not overlap upstream producers")
    }

    // MARK: - 7. Cancelled stream unwinds without hanging

    @Test("cancelled stream unwinds without hanging")
    func cancelLeavesNoFinal() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()

        // Slow upstream so cancellation has time to land before the writer can
        // finish and commit a final file.
        actor SlowSource: TTSChunkSource {
            private(set) var requests: [TTSStreamRequest] = []

            nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
                Task { await self.record(request) }
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        continuation.yield(TTSChunk.make(
                            request: request,
                            sequenceIndex: 0,
                            data: Data([0x01, 0x02, 0x03])
                        ))
                        do {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }

            private func record(_ request: TTSStreamRequest) {
                requests.append(request)
            }

            func count() async -> Int { requests.count }
        }
        let upstream = SlowSource()
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        actor ChunkCounter {
            private var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
            func value() -> Int { count }
        }
        let counter = ChunkCounter()

        let consumer = Task {
            for try await _ in cache.stream(request: request) {
                _ = await counter.increment()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return
            }
        }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if await counter.value() >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        consumer.cancel()
        _ = await consumer.result
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await upstream.count()
        #expect(calls == 1, "cancelled stream should still only have started one upstream request")
        let finalURL = tmp.appendingPathComponent("\(TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)).mp3")
        #expect(!FileManager.default.fileExists(atPath: finalURL.path), "cancelled stream must not promote a partial file")
        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.lastPathComponent.hasSuffix(".mp3.partial") }.isEmpty,
                "cancelled stream must discard its partial file")
    }

    // MARK: - 8. Pre-existing .partial is invisible to read

    @Test("pre-existing .partial file is treated as a miss")
    func partialInvisibleToRead() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest()
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)

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

    // MARK: - 9. Concurrent same-key writers must not clobber each other

    /// Regression for the read-aloud mid-paragraph halt: when the engine plays a
    /// passage while the prewarmer re-warms the SAME passage (same cache key),
    /// the two in-flight writers shared one `.partial` path. The second
    /// `beginWrite` removed the first's partial and a cancel/`discard` then made
    /// the first's `commit` throw `CocoaError.fileNoSuchFile`, surfacing as
    /// `tts.engine.error error=... "The file doesn't exist."` and stopping
    /// playback. Each writer must own an independent partial; discarding one
    /// must never break another's commit.
    @Test("concurrent same-key writers use independent partials and do not clobber")
    func concurrentSameKeyWritersDoNotClobber() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let key = "deadbeefc0ffee"

        // Writer A opens a partial and writes its bytes.
        let partialA = try await store.beginWrite(key: key)
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: partialA)

        // Writer B is a second concurrent miss for the SAME key.
        let partialB = try await store.beginWrite(key: key)
        #expect(partialB != partialA, "each in-flight writer must get an independent .partial path")

        // Writer B aborts (e.g. prewarm cancelled at a chapter switch) and must
        // clean up ONLY its own partial.
        await store.discard(partial: partialB)

        // Writer A must still commit its intact bytes.
        try await store.commit(key: key, partial: partialA)

        let url = try #require(await store.read(key: key))
        #expect(try Data(contentsOf: url) == Data([0x01, 0x02, 0x03, 0x04]),
                "committed bytes must be writer A's, undamaged by the concurrent writer")
    }

    // MARK: - 10. Empty upstream must not poison the cache (read-aloud halt)
    //
    // Field repro (user log): the current paragraph plays from cache, the NEXT
    // paragraph is NOT cached so it forces an upstream (network) call, and that
    // call returns an EMPTY response. The empty was committed as a 0-byte `.mp3`,
    // so every later play of that paragraph became a cache HIT serving 0 bytes —
    // the decoder got no buffer and read-aloud stopped (observed as
    // `tts.cache.hit bytes=0`). An empty/failed upstream must be treated as a
    // transient miss, never cached.

    @Test("empty upstream response is NOT committed as a 0-byte cache entry")
    func emptyUpstreamDoesNotPoisonCache() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest(text: "Paragraph the worker synthesises to nothing.")
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)

        // The uncached next paragraph forces an upstream call that yields NOTHING.
        let upstream = FakeTTSChunkSource(chunks: [Data]())
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)

        // First (uncached) play streams zero audio bytes — the audible stall.
        let firstPlay = try await consume(cache.stream(request: request))
        #expect(firstPlay.isEmpty, "an empty upstream yields no audio on the uncached play")

        // THE BUG: the empty response must NOT be cached. Before the fix a 0-byte
        // `.mp3` was committed and read() returned it, so every later play was a
        // cache hit serving 0 bytes — a permanent halt.
        let finalURL = tmp.appendingPathComponent("\(key).mp3")
        #expect(
            !FileManager.default.fileExists(atPath: finalURL.path),
            "empty upstream MUST NOT be committed as a 0-byte .mp3 (cache poisoning)"
        )
        let hit = await store.read(key: key)
        #expect(hit == nil, "cache must report a MISS for an empty response, not a 0-byte hit")
    }

    @Test("a 0-byte committed cache file is treated as a miss and re-synthesised")
    func zeroByteCacheFileIsTreatedAsMiss() async throws {
        let tmp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try TTSAudioCacheStore(directory: tmp, capBytes: 10 * 1024 * 1024)
        let request = makeRequest(text: "Already-poisoned paragraph.")
        let key = TTSCacheKey.compute(text: request.text, voice: request.voice, model: request.model, speed: request.speed)

        // Simulate a cache poisoned by an older build: a committed but EMPTY .mp3.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data().write(to: tmp.appendingPathComponent("\(key).mp3"))

        // read() must NOT serve the empty file — that is the `tts.cache.hit
        // bytes=0` halt.
        let directHit = await store.read(key: key)
        #expect(directHit == nil, "a 0-byte cache file must be treated as a miss")

        // A play must therefore fall through to upstream and recover real audio
        // instead of halting forever on the poisoned entry.
        let upstream = FakeTTSChunkSource(chunks: [Data([0x01, 0x02, 0x03, 0x04])])
        let cache = CachingTTSChunkSource(upstream: upstream, store: store)
        let played = try await consume(cache.stream(request: request))
        #expect(
            played == Data([0x01, 0x02, 0x03, 0x04]),
            "after evicting the 0-byte entry, playback must re-synthesise real audio"
        )
    }
}

private actor BlockingAfterFirstChunkSource: TTSChunkSource {
    private let chunks: [Data]
    private var receivedRequestCount = 0
    private var firstChunkWasYielded = false
    private var released = false
    private var firstChunkWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [chunks] in
                await self.recordRequest()
                for (index, data) in chunks.enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(TTSChunk.make(
                        request: request,
                        sequenceIndex: index,
                        data: data
                    ))
                    if index == 0 {
                        await self.markFirstChunkWasYielded()
                        await self.waitForRelease()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func waitForFirstChunk() async {
        if firstChunkWasYielded { return }
        await withCheckedContinuation { continuation in
            firstChunkWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCount() -> Int {
        receivedRequestCount
    }

    private func recordRequest() {
        receivedRequestCount += 1
    }

    private func markFirstChunkWasYielded() {
        firstChunkWasYielded = true
        let waiters = firstChunkWaiters
        firstChunkWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor CancellationWindowSource: TTSChunkSource {
    private let chunks: [Data]
    private var totalRequests = 0
    private var activeRequests = 0
    private var maximumConcurrentRequests = 0
    private var firstChunkWasYielded = false
    private var cancellationWasObserved = false
    private var firstChunkWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationReleased = false

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [chunks] in
                let requestNumber = await self.startRequest()
                continuation.yield(TTSChunk.make(
                    request: request,
                    sequenceIndex: 0,
                    data: chunks[0]
                ))
                await self.markFirstChunkWasYielded()

                if requestNumber == 1 {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        await self.markCancellationWasObserved()
                        await self.waitForCancellationRelease()
                        continuation.finish(throwing: error)
                        return
                    }
                }

                for (index, data) in chunks.dropFirst().enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(TTSChunk.make(
                        request: request,
                        sequenceIndex: index + 1,
                        data: data
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.stopRequest() }
            }
        }
    }

    func waitForFirstChunk() async {
        if firstChunkWasYielded { return }
        await withCheckedContinuation { continuation in
            firstChunkWaiters.append(continuation)
        }
    }

    func waitForCancellationObserved() async {
        if cancellationWasObserved { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func releaseCancellation() {
        cancellationReleased = true
        let waiters = cancellationReleaseWaiters
        cancellationReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCount() -> Int {
        totalRequests
    }

    func maxConcurrentRequests() -> Int {
        maximumConcurrentRequests
    }

    private func startRequest() -> Int {
        totalRequests += 1
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        return totalRequests
    }

    private func stopRequest() {
        activeRequests -= 1
    }

    private func markFirstChunkWasYielded() {
        firstChunkWasYielded = true
        let waiters = firstChunkWaiters
        firstChunkWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func markCancellationWasObserved() {
        cancellationWasObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForCancellationRelease() async {
        if cancellationReleased { return }
        await withCheckedContinuation { continuation in
            cancellationReleaseWaiters.append(continuation)
        }
    }
}
