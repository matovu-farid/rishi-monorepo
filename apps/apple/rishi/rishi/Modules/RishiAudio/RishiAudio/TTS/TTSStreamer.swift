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
                responseMode: .events,
                telemetryID: request.requestToken.uuidString
            )
        )
        let upstream = await client.stream(endpoint)
        return AsyncThrowingStream { continuation in
            let parser = TTSStreamEventParser()
            let task = Task {
                let expectedRequestID = request.requestToken.uuidString
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
                            let chunk = TTSChunk(
                                requestKey: frame.requestID,
                                sequenceIndex: frame.index,
                                data: frame.audio
                            )
                            if frame.requestID != expectedRequestID {
                                Log.error(
                                    "tts.sse.request_id_mismatch",
                                    error: NSError(domain: "org.fidexa.rishi.tts", code: 5),
                                    diagnostic: TelemetryDiagnostic(
                                        feature: "tts",
                                        operation: "tts.sse",
                                        stage: "validate",
                                        errorCode: "request_id_mismatch",
                                        fields: ["correlation_id": expectedRequestID]
                                    )
                                )
                                throw TTSStreamerError.requestIDMismatch
                            }
                            if let chunkID = frame.chunkID, chunkID != chunk.id {
                                Log.error(
                                    "tts.sse.chunk_id_mismatch",
                                    error: NSError(domain: "org.fidexa.rishi.tts", code: 6),
                                    diagnostic: TelemetryDiagnostic(
                                        feature: "tts",
                                        operation: "tts.sse",
                                        stage: "validate",
                                        errorCode: "chunk_id_mismatch",
                                        fields: ["correlation_id": expectedRequestID]
                                    )
                                )
                                throw TTSStreamerError.chunkIDMismatch
                            }
                            continuation.yield(chunk)
                        }
                    }
                    for frame in await parser.finalize() {
                        let chunk = TTSChunk(
                            requestKey: frame.requestID,
                            sequenceIndex: frame.index,
                            data: frame.audio
                        )
                        if frame.requestID != expectedRequestID {
                            Log.error(
                                "tts.sse.request_id_mismatch",
                                error: NSError(domain: "org.fidexa.rishi.tts", code: 5),
                                diagnostic: TelemetryDiagnostic(
                                    feature: "tts",
                                    operation: "tts.sse",
                                    stage: "validate",
                                    errorCode: "request_id_mismatch",
                                    fields: ["correlation_id": expectedRequestID]
                                )
                            )
                            throw TTSStreamerError.requestIDMismatch
                        }
                        if let chunkID = frame.chunkID, chunkID != chunk.id {
                            Log.error(
                                "tts.sse.chunk_id_mismatch",
                                error: NSError(domain: "org.fidexa.rishi.tts", code: 6),
                                diagnostic: TelemetryDiagnostic(
                                    feature: "tts",
                                    operation: "tts.sse",
                                    stage: "validate",
                                    errorCode: "chunk_id_mismatch",
                                    fields: ["correlation_id": expectedRequestID]
                                )
                            )
                            throw TTSStreamerError.chunkIDMismatch
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
    case requestIDMismatch
    case chunkIDMismatch
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
                var chunkCount = 0
                var yieldedChunk = false
                let startedAt = Date()
                let correlationID = request.requestToken.uuidString
                do {
                    Log.event("tts.stream.started", level: .info, data: [
                        "feature": "tts",
                        "operation": "tts.stream",
                        "stage": "request",
                        "correlation_id": correlationID,
                        "request_chars": String(request.text.count),
                        "response_mode": "events",
                    ])
                    for try await chunk in upstream {
                        if Task.isCancelled {
                            Log.event("tts.stream.cancelled", level: .warning, data: [
                                "feature": "tts",
                                "operation": "tts.stream",
                                "stage": "stream",
                                "correlation_id": correlationID,
                                "cancel_reason": "task_cancelled",
                            ])
                            continuation.finish()
                            return
                        }
                        byteCount += chunk.count
                        chunkCount += 1
                        yieldedChunk = true
                        if chunkCount == 1 {
                            Log.event("tts.stream.first_chunk", level: .info, data: [
                                "feature": "tts",
                                "operation": "tts.stream",
                                "stage": "stream",
                                "correlation_id": correlationID,
                                "first_chunk_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                            ])
                        }
                        continuation.yield(chunk)
                    }
                    guard yieldedChunk else {
                        Log.error(
                            "tts.stream.empty_response",
                            error: TTSStreamerError.emptyResponse,
                            diagnostic: TelemetryDiagnostic(
                                feature: "tts",
                                operation: "tts.stream",
                                stage: "provider_stream",
                                errorCode: "empty_response",
                                fields: [
                                    "request_chars": String(request.text.count),
                                    "correlation_id": correlationID,
                                ]
                            )
                        )
                        continuation.finish(throwing: TTSStreamerError.emptyResponse)
                        return
                    }
                    Log.event("tts.stream.completed", level: .info, data: [
                        "feature": "tts",
                        "operation": "tts.stream",
                        "stage": "stream",
                        "correlation_id": correlationID,
                        "duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "chunk_count": String(chunkCount),
                        "byte_count": String(byteCount),
                    ])
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        Log.event("tts.stream.cancelled", level: .warning, data: [
                            "feature": "tts",
                            "operation": "tts.stream",
                            "stage": "stream",
                            "correlation_id": correlationID,
                            "cancel_reason": "consumer_cancelled",
                        ])
                        continuation.finish()
                        return
                    }
                    Log.error(
                        "tts.stream.failed",
                        error: error,
                        diagnostic: TelemetryDiagnostic(
                            feature: "tts",
                            operation: "tts.stream",
                            stage: "provider_stream",
                            errorCode: "stream_failed",
                            fields: [
                                "request_chars": String(request.text.count),
                                "correlation_id": correlationID,
                            ]
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
