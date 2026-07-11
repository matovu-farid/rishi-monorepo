import Foundation

/// Ordered MP3 chunk for the TTS pipeline.
///
/// `requestKey` gives the chunk a deterministic request-scoped identity, and
/// `sequenceIndex` preserves stable ordering independent of whether the bytes
/// came from the worker or from the cache.
public struct TTSChunk: Sendable, Equatable, Hashable {
    public static let streamChunkByteCount = 4 * 1024

    public let requestKey: String
    public let sequenceIndex: Int
    public let data: Data

    public init(requestKey: String, sequenceIndex: Int, data: Data) {
        self.requestKey = requestKey
        self.sequenceIndex = sequenceIndex
        self.data = data
    }

    /// Deterministic chunk id derived from the request and its ordered index.
    public var id: String {
        "\(requestKey)#\(String(format: "%08d", sequenceIndex))"
    }

    public var count: Int { data.count }
    public var isEmpty: Bool { data.isEmpty }

    public static func make(request: TTSStreamRequest, sequenceIndex: Int, data: Data) -> Self {
        let requestKey = TTSCacheKey.compute(
            text: request.text,
            voice: request.voice,
            model: request.model,
            speed: request.speed
        )
        return Self(requestKey: requestKey, sequenceIndex: sequenceIndex, data: data)
    }
}
