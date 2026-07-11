import Foundation
import RishiLogging

/// Wraps any upstream `TTSChunkSource` with a file-backed LRU cache.
///
/// Hit: yields cached bytes in ordered 4 KiB chunks without touching upstream.
/// Miss: tees upstream chunks into `<key>.mp3.partial`; atomic-renames to `<key>.mp3`
///       on stream completion. On error or cancel, leaves `.partial` in place for the
///       LRU sweep to evict — never promotes a half-written file.
public actor CachingTTSChunkSource: TTSChunkSource {
    private let upstream: any TTSChunkSource
    private let store: TTSAudioCacheStore

    public init(upstream: any TTSChunkSource, store: TTSAudioCacheStore) {
        self.upstream = upstream
        self.store = store
    }

    public nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let key = TTSCacheKey.compute(
                    text: request.text,
                    voice: request.voice,
                    model: request.model,
                    speed: request.speed
                )

                if let hitURL = await self.store.read(key: key) {
                    Log.event("tts.cache.hit", level: .info, data: ["key_prefix": String(key.prefix(8))])
                    do {
                        try await Self.streamFile(at: hitURL, requestKey: key, into: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                Log.event("tts.cache.miss", level: .info, data: ["key_prefix": String(key.prefix(8))])
                await self.streamMiss(request: request, key: key, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Hit path: stream the cached file in 16 KiB chunks

    private static func streamFile(
        at url: URL,
        requestKey: String,
        into continuation: AsyncThrowingStream<TTSChunk, Error>.Continuation
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = TTSChunk.streamChunkByteCount
        var sequenceIndex = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { return }
            continuation.yield(
                TTSChunk(requestKey: requestKey, sequenceIndex: sequenceIndex, data: chunk)
            )
            sequenceIndex += 1
        }
    }

    // MARK: - Miss path: tee upstream chunks to `.partial` then atomic-rename

    private func streamMiss(
        request: TTSStreamRequest,
        key: String,
        into continuation: AsyncThrowingStream<TTSChunk, Error>.Continuation
    ) async {
        let partialURL: URL
        do {
            partialURL = try await store.beginWrite(key: key)
        } catch {
            // If we cannot open a partial, fall back to passthrough: don't fail the user.
            Log.event("tts.cache.beginWrite.failed", level: .error, data: ["error": "\(error)"])
            await passthrough(request: request, into: continuation)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: partialURL) else {
            Log.event("tts.cache.openWrite.failed", level: .error, data: [:])
            await store.discard(partial: partialURL)
            await passthrough(request: request, into: continuation)
            return
        }

        var committed = false
        var wroteBytes = 0
        do {
            for try await chunk in await upstream.stream(request: request) {
                try Task.checkCancellation()
                continuation.yield(chunk)
                try handle.write(contentsOf: chunk.data)
                wroteBytes += chunk.count
            }
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
                continuation.finish()
                return
            }
            try await store.commit(key: key, partial: partialURL)
            committed = true
            continuation.finish()
        } catch is CancellationError {
            try? handle.close()
            if !committed { await store.discard(partial: partialURL) }
            continuation.finish(throwing: CancellationError())
        } catch {
            try? handle.close()
            if !committed { await store.discard(partial: partialURL) }
            continuation.finish(throwing: error)
        }
    }

    /// Last-resort: pass upstream bytes through without writing to disk.
    /// Reached only when the cache store itself is broken (cannot create partial).
    private func passthrough(
        request: TTSStreamRequest,
        into continuation: AsyncThrowingStream<TTSChunk, Error>.Continuation
    ) async {
        do {
            for try await chunk in await upstream.stream(request: request) {
                try Task.checkCancellation()
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
