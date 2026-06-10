import Foundation

/// One decoded SSE frame from `POST /api/chat`. The worker emits OpenAI-style
/// frames: a series of `{"delta":"<token>"}` followed by `{"done":true}` (or
/// the `data: [DONE]` literal which ``SSEParser`` handles separately).
///
/// `tool_call` is an opaque JSON string per Phase 9 contract — v1 does not
/// introspect tool payloads.
public struct ChatResponseChunk: Decodable, Sendable, Equatable {
    public let delta: String?
    public let toolCall: String?
    public let done: Bool?

    enum CodingKeys: String, CodingKey {
        case delta
        case toolCall = "tool_call"
        case done
    }

    public init(delta: String? = nil, toolCall: String? = nil, done: Bool? = nil) {
        self.delta = delta
        self.toolCall = toolCall
        self.done = done
    }
}
