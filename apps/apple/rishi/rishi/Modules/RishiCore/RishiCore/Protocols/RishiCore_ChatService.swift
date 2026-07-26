import Foundation

/// Events emitted by `ChatService.stream(...)` as the worker streams an answer.
public enum ChatEvent: Sendable, Hashable {
    /// A token of assistant content. Append to the current message body.
    case token(String)
    /// A tool call (opaque JSON; v1 does not introspect).
    case toolCall(String)
    /// The stream completed successfully.
    case completed
}

public protocol ChatService: Sendable {
    /// Stream a chat answer scoped to an optional book.
    /// - Parameter query: The user's question.
    /// - Parameter bookId: The book context, or nil for a general conversation.
    func stream(query: String, bookId: BookID?) -> AsyncThrowingStream<ChatEvent, Error>
}
