import Foundation
import RishiCore
import RishiLogging

/// Source of MP3 byte chunks for a TTS request. Production is `WorkerClient`
/// via ``WorkerTTSChunkSource``; tests inject ``FakeTTSChunkSource`` to avoid
/// spinning up URLProtocol.
public protocol TTSChunkSource: Sendable {
    func stream(request: TTSStreamRequest) async-> AsyncThrowingStream<Data, Error>
}

/// Production adapter — wraps the existing WorkerClient + SpeechStreamEndpoint.
public struct WorkerTTSChunkSource: TTSChunkSource {
    private let client: WorkerClient

    public init(client: WorkerClient) {
        self.client = client
    }

    public func stream(request: TTSStreamRequest) async  -> AsyncThrowingStream<Data, Error> {
        let endpoint = SpeechStreamEndpoint(
            body: .init(text: request.text, voice: request.voice, speed: request.speed)
        )
        return await client.stream(endpoint)
    }
}

/// Test-only deterministic source. Yields each pre-configured chunk in order;
/// optionally throws after N chunks to exercise the error path.
public actor FakeTTSChunkSource: TTSChunkSource {

    public private(set) var receivedRequests: [TTSStreamRequest] = []
    private let chunks: [Data]
    private let throwAfter: Int?

    public init(chunks: [Data], throwAfter: Int? = nil) {
        self.chunks = chunks
        self.throwAfter = throwAfter
    }

    nonisolated public func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            // KEEP: nonisolated wrapper on an actor; Task body bridges chunks
            // into the continuation off the calling actor.
            let task = Task { [chunks, throwAfter] in
                await self.recordRequest(request)
                for (index, chunk) in chunks.enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if let throwAfter, index >= throwAfter {
                        continuation.finish(throwing: TTSStreamerError.injected)
                        return
                    }
                    continuation.yield(chunk)
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
}

/// Forwarding actor — adds Log.event breadcrumbs around the underlying source
/// and centralises the streaming entry point so Phase 8 callers (plan 08-04
/// TTSEngine) depend on a single seam.
public actor TTSStreamer {

    private let source: any TTSChunkSource

    public init(source: any TTSChunkSource) {
        self.source = source
    }

    public nonisolated func stream(_ request: TTSStreamRequest) async -> AsyncThrowingStream<Data, Error> {
        let upstream = await source.stream(request: request)
        return AsyncThrowingStream { continuation in
            // KEEP: nonisolated wrapper on an actor; Task body forwards bytes
            // and emits Log breadcrumbs off the calling actor.
            let task = Task {
                var byteCount = 0
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
                        continuation.yield(chunk)
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
