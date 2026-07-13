import Foundation
import RishiLogging

/// Wraps any upstream `TTSChunkSource` with a file-backed LRU cache.
///
/// Hit: yields cached bytes in ordered 4 KiB chunks without touching upstream.
/// Miss: tees upstream chunks into `<key>.mp3.partial`; atomic-renames to `<key>.mp3`
///       on stream completion. On error or cancel, leaves `.partial` in place for the
///       LRU sweep to evict — never promotes a half-written file.
public actor CachingTTSChunkSource: TTSChunkSource {
    private typealias SubscriberContinuation = AsyncThrowingStream<TTSChunk, Error>.Continuation

    private struct InFlightRequest {
        let request: TTSStreamRequest
        var history: [TTSChunk]
        var subscribers: [UUID: SubscriberContinuation]
        var pendingSubscribers: [UUID: SubscriberContinuation]
        var producer: Task<Void, Never>?
        var isStopping: Bool
    }

    /// The stream can be cancelled before the actor gets a chance to register its
    /// continuation. This small lock-protected token closes that race without
    /// putting mutable subscription state outside the actor-owned registry.
    private final class SubscriptionState: @unchecked Sendable {
        private let lock = NSLock()
        private var terminated = false

        func markTerminated() {
            lock.lock()
            terminated = true
            lock.unlock()
        }

        func isTerminated() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminated
        }
    }

    private let upstream: any TTSChunkSource
    private let store: TTSAudioCacheStore
    private var inFlight: [String: InFlightRequest] = [:]

    public init(upstream: any TTSChunkSource, store: TTSAudioCacheStore) {
        self.upstream = upstream
        self.store = store
    }

    public nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        let key = TTSCacheKey.compute(
            text: request.text,
            voice: request.voice,
            model: request.model,
            speed: request.speed
        )
        let subscriberID = UUID()
        let state = SubscriptionState()

        return AsyncThrowingStream { continuation in
            Task { [self] in
                await self.subscribe(
                    request: request,
                    key: key,
                    subscriberID: subscriberID,
                    state: state,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [weak self] _ in
                state.markTerminated()
                Task { await self?.unsubscribe(key: key, subscriberID: subscriberID) }
            }
        }
    }

    public func shouldShowLoading(for request: TTSStreamRequest) async -> Bool {
        let key = TTSCacheKey.compute(
            text: request.text,
            voice: request.voice,
            model: request.model,
            speed: request.speed
        )
        let isCached = await store.contains(key: key)
        return !isCached
    }

    // MARK: - In-flight subscription registry

    /// Registers the first subscriber and reserves `key` before the first await.
    /// Every later subscriber joins this same producer, including while its cache
    /// lookup is suspended.
    private func subscribe(
        request: TTSStreamRequest,
        key: String,
        subscriberID: UUID,
        state: SubscriptionState,
        continuation: SubscriberContinuation
    ) {
        guard !state.isTerminated() else {
            continuation.finish()
            return
        }

        if var existing = inFlight[key] {
            if existing.isStopping {
                // The old producer is already cancelled. Wait for its terminal
                // cleanup before starting a replacement, so producers never
                // overlap for the same cache key.
                existing.pendingSubscribers[subscriberID] = continuation
            } else {
                for chunk in existing.history {
                    continuation.yield(chunk)
                }
                existing.subscribers[subscriberID] = continuation
            }
            inFlight[key] = existing
            return
        }

        // Reserve before creating the producer. There is no suspension in this
        // actor method, so another caller cannot observe an unreserved key.
        inFlight[key] = InFlightRequest(
            request: request,
            history: [],
            subscribers: [subscriberID: continuation],
            pendingSubscribers: [:],
            producer: nil,
            isStopping: false
        )
        startProducer(request: request, key: key)
    }

    private func startProducer(request: TTSStreamRequest, key: String) {
        let producer = Task.detached { [self] in
            await self.produce(request: request, key: key)
        }
        inFlight[key]?.producer = producer
    }

    private func unsubscribe(key: String, subscriberID: UUID) {
        guard var request = inFlight[key] else { return }
        let removedSubscriber = request.subscribers.removeValue(forKey: subscriberID) != nil
        if !removedSubscriber {
            request.pendingSubscribers.removeValue(forKey: subscriberID)
        }
        let shouldCancelProducer = removedSubscriber
            && request.subscribers.isEmpty
            && !request.isStopping
        if shouldCancelProducer {
            request.isStopping = true
        }
        inFlight[key] = request
        if shouldCancelProducer {
            request.producer?.cancel()
        }
    }

    private func publish(key: String, chunk: TTSChunk) {
        guard var request = inFlight[key] else { return }
        request.history.append(chunk)
        for continuation in request.subscribers.values {
            continuation.yield(chunk)
        }
        inFlight[key] = request
    }

    private func finish(key: String, error: Error?) {
        guard let request = inFlight.removeValue(forKey: key) else { return }
        for continuation in request.subscribers.values {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }

        guard !request.pendingSubscribers.isEmpty else { return }
        inFlight[key] = InFlightRequest(
            request: request.request,
            history: [],
            subscribers: request.pendingSubscribers,
            pendingSubscribers: [:],
            producer: nil,
            isStopping: false
        )
        startProducer(request: request.request, key: key)
    }

    // MARK: - Shared producer

    private func produce(request: TTSStreamRequest, key: String) async {
        do {
            try Task.checkCancellation()
            if let hitURL = await store.read(key: key) {
                Log.event("tts.cache.hit", level: .info, data: ["key_prefix": String(key.prefix(8))])
                try await streamFile(at: hitURL, requestKey: key)
            } else {
                Log.event("tts.cache.miss", level: .info, data: ["key_prefix": String(key.prefix(8))])
                try await streamMiss(request: request, key: key)
            }
            finish(key: key, error: nil)
        } catch {
            finish(key: key, error: error)
        }
    }

    // MARK: - Hit path: stream the cached file in 16 KiB chunks

    private func streamFile(at url: URL, requestKey: String) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = TTSChunk.streamChunkByteCount
        var sequenceIndex = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { return }
            publish(
                key: requestKey,
                chunk: TTSChunk(requestKey: requestKey, sequenceIndex: sequenceIndex, data: chunk)
            )
            sequenceIndex += 1
            await Task.yield()
        }
    }

    // MARK: - Miss path: tee upstream chunks to `.partial` then atomic-rename

    private func streamMiss(request: TTSStreamRequest, key: String) async throws {
        try Task.checkCancellation()
        let partialURL: URL
        do {
            partialURL = try await store.beginWrite(key: key)
        } catch {
            // If we cannot open a partial, fall back to passthrough: don't fail the user.
            Log.event("tts.cache.beginWrite.failed", level: .error, data: ["error": "\(error)"])
            try await passthrough(request: request, key: key)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: partialURL) else {
            Log.event("tts.cache.openWrite.failed", level: .error, data: [:])
            await store.discard(partial: partialURL)
            try await passthrough(request: request, key: key)
            return
        }

        var committed = false
        var wroteBytes = 0
        do {
            try Task.checkCancellation()
            for try await chunk in await upstream.stream(request: request) {
                try Task.checkCancellation()
                publish(key: key, chunk: chunk)
                try handle.write(contentsOf: chunk.data)
                wroteBytes += chunk.count
            }
            try Task.checkCancellation()
            try? handle.close()
            // Never commit an empty file: a 0-byte cache entry yields no audio
            // and halts playback on every later hit. An empty upstream response
            // is treated as a transient failure — discard so the next play
            // re-synthesises rather than caching silence.
            guard wroteBytes > 0 else {
                await store.discard(partial: partialURL)
                committed = true // nothing to clean up in the catch blocks
                Log.event("tts.cache.empty_upstream", level: .error, data: [
                    "key_prefix": String(key.prefix(8)),
                ])
                return
            }
            try await store.commit(key: key, partial: partialURL)
            committed = true
        } catch {
            try? handle.close()
            if !committed { await store.discard(partial: partialURL) }
            throw error
        }
    }

    /// Last-resort: pass upstream bytes through without writing to disk.
    /// Reached only when the cache store itself is broken (cannot create partial).
    private func passthrough(request: TTSStreamRequest, key: String) async throws {
        try Task.checkCancellation()
        for try await chunk in await upstream.stream(request: request) {
            try Task.checkCancellation()
            publish(key: key, chunk: chunk)
        }
    }
}
