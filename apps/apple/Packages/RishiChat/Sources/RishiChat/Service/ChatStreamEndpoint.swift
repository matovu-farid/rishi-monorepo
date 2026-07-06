import Foundation
import RishiCore

/// `POST /api/chat` — book-scoped streaming chat (cloud RAG).
///
/// Conforms to ``WorkerStreamingEndpointWithBody`` because the response is
/// consumed as chunks of `text/event-stream` bytes via
/// `WorkerClient.stream(_:)` rather than decoded as a single JSON document.
///
/// Phase 9 (Chat) is the primary caller. ``SSEParser`` frames the byte stream
/// into ``ChatResponseChunk`` events; `ChatService` (plan 09-03) orchestrates
/// persistence.
struct ChatStreamEndpoint: WorkerStreamingEndpointWithBody {
    public let method: HTTPMethod = .POST
    public let path: String = "/api/chat"
    public let body: ChatRequest

    public init(body: ChatRequest) {
        self.body = body
    }
}
