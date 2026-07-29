import Foundation



/// Source of ordered MP3 chunks for a TTS request. Production is `WorkerClient`
/// via ``WorkerTTSChunkSource``; tests inject ``FakeTTSChunkSource`` to avoid
/// spinning up URLProtocol.
public protocol TTSChunkSource: Sendable {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error>
    func shouldShowLoading(for request: TTSStreamRequest) async -> Bool
}

public extension TTSChunkSource {
    func shouldShowLoading(for request: TTSStreamRequest) async -> Bool {
        _ = request
        return true
    }
}

/// Production adapter — wraps the existing WorkerClient + worker-owned speech
/// endpoint in SSE event mode and turns ordered chunk frames into `TTSChunk`.
public struct WorkerTTSChunkSource: TTSChunkSource {
    private let client: WorkerClient
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider

    public init(
        client: WorkerClient,
        dataUseConsentProvider: any WorkerDataUseConsentProvider = AlwaysAllowWorkerDataUseConsentProvider()
    ) {
        self.client = client
        self.dataUseConsentProvider = dataUseConsentProvider
    }

    public func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WorkerDataUseConsentRequiredError())
            }
        }
        let endpoint = SpeechStreamEndpoint(
            body: .init(
                text: request.text,
                voice: request.voice,
                speed: request.speed,
                responseMode: .events
            )
        )
        let upstream = await client.stream(endpoint)
        return AsyncThrowingStream { continuation in
            let parser = TTSStreamEventParser()
            let task = Task {
                var workerRequestKey: String?
                do {
                    for try await bytes in upstream {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        for frame in await parser.consume(bytes) {
                            if Task.isCancelled {
                                continuation.finish()
                                return
                            }
                            workerRequestKey = workerRequestKey ?? frame.requestID
                            let chunk = TTSChunk(
                                requestKey: frame.requestID,
                                sequenceIndex: frame.index,
                                data: frame.audio
                            )
                            if frame.requestID != workerRequestKey {
                                Log.event("tts.sse.request_id_mismatch", level: .error, data: [
                                    "expected": workerRequestKey ?? "unknown",
                                    "got": frame.requestID,
                                ])
                            }
                            if let chunkID = frame.chunkID, chunkID != chunk.id {
                                Log.event("tts.sse.chunk_id_mismatch", level: .error, data: [
                                    "expected": chunk.id,
                                    "got": chunkID,
                                ])
                            }
                            continuation.yield(chunk)
                        }
                    }
                    for frame in await parser.finalize() {
                        workerRequestKey = workerRequestKey ?? frame.requestID
                        let chunk = TTSChunk(
                            requestKey: frame.requestID,
                            sequenceIndex: frame.index,
                            data: frame.audio
                        )
                        if frame.requestID != workerRequestKey {
                            Log.event("tts.sse.request_id_mismatch", level: .error, data: [
                                "expected": workerRequestKey ?? "unknown",
                                "got": frame.requestID,
                            ])
                        }
                        if let chunkID = frame.chunkID, chunkID != chunk.id {
                            Log.event("tts.sse.chunk_id_mismatch", level: .error, data: [
                                "expected": chunk.id,
                                "got": chunkID,
                            ])
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Test-only deterministic source. Yields each pre-configured chunk in order;
/// optionally throws after N chunks to exercise the error path.
public actor FakeTTSChunkSource: TTSChunkSource {

    public private(set) var receivedRequests: [TTSStreamRequest] = []
    private enum ChunkTemplate: Sendable {
        case raw(Data)
        case chunk(TTSChunk)
    }

    private let chunks: [ChunkTemplate]
    private let throwAfter: Int?

    public init(chunks: [Data], throwAfter: Int? = nil) {
        self.chunks = chunks.map { .raw($0) }
        self.throwAfter = throwAfter
    }

    public init(chunks: [TTSChunk], throwAfter: Int? = nil) {
        self.chunks = chunks.map { .chunk($0) }
        self.throwAfter = throwAfter
    }

    nonisolated public func stream(request: TTSStreamRequest) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            // KEEP: nonisolated wrapper on an actor; Task body bridges chunks
            // into the continuation off the calling actor.
            let task = Task { [chunks, throwAfter] in
                await self.recordRequest(request)
                for (index, template) in chunks.enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if let throwAfter, index >= throwAfter {
                        continuation.finish(throwing: TTSStreamerError.injected)
                        return
                    }
                    switch template {
                    case .raw(let data):
                        continuation.yield(
                            TTSChunk.make(request: request, sequenceIndex: index, data: data)
                        )
                    case .chunk(let chunk):
                        continuation.yield(chunk)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordRequest(_ request: TTSStreamRequest) {
        receivedRequests.append(request)
    }

    public func requests() async -> [TTSStreamRequest] {
        receivedRequests
    }
}

public enum TTSStreamerError: Error, Equatable {
    case injected
    case emptyResponse
}

/// Forwarding actor — adds Log.event breadcrumbs around the underlying source
/// and centralises the streaming entry point so Phase 8 callers (plan 08-04
/// TTSEngine) depend on a single seam.
public actor TTSStreamer {

    private let source: any TTSChunkSource

    public init(source: any TTSChunkSource) {
        self.source = source
    }

    public func shouldShowLoading(for request: TTSStreamRequest) async -> Bool {
        await source.shouldShowLoading(for: request)
    }

    public nonisolated func stream(_ request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        let upstream = await source.stream(request: request)
        return AsyncThrowingStream { continuation in
            // KEEP: nonisolated wrapper on an actor; Task body forwards
            // ordered chunks and emits Log breadcrumbs off the calling actor.
            let task = Task {
                var byteCount = 0
                var yieldedChunk = false
                do {
                    Log.event("tts.stream.start", level: .info, data: [
                        "voice": request.voice,
                        "speed": String(format: "%.2f", request.speed),
                        "textLen": String(request.text.count),
                    ])
                    for try await chunk in upstream {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        byteCount += chunk.count
                        yieldedChunk = true
                        continuation.yield(chunk)
                    }
                    guard yieldedChunk else {
                        Log.event("tts.stream.empty_response", level: .error, data: [
                            "voice": request.voice,
                            "textLen": String(request.text.count),
                        ])
                        continuation.finish(throwing: TTSStreamerError.emptyResponse)
                        return
                    }
                    Log.event("tts.stream.complete", level: .info, data: ["bytes": String(byteCount)])
                    continuation.finish()
                } catch {
                    Log.event("tts.stream.failed", level: .error, data: ["error": String(describing: error)])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
