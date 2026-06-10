import Foundation
import RishiCore
import RishiLogging

/// Resolves the `Conversation` a chat-panel session is bound to.
///
/// Strategy: scan `ConversationStore.conversations(for: userId)` for the
/// most-recently-updated row whose `bookId` matches the requested context.
/// `bookId == nil` is treated as a first-class match key (general/non-book
/// conversation). When no row matches, mint a new `Conversation` with a
/// sensible default title and persist it via `upsert`.
public actor ConversationLookup {

    private let store: any ConversationStore

    public init(store: any ConversationStore) {
        self.store = store
    }

    public func findOrCreate(
        userId: UserID,
        bookId: BookID?,
        defaultTitle: @autoclosure () -> String = "New conversation"
    ) async throws -> Conversation {
        let all = try await store.conversations(for: userId)
        if let match = all
            .filter({ $0.bookId == bookId })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return match
        }
        let convo = Conversation(
            userId: userId,
            bookId: bookId,
            title: defaultTitle()
        )
        try await store.upsert(convo)
        Log.event("chat.conversation.created", level: .info, data: [
            "conversation_id": convo.id.uuidString,
            "has_book_id": bookId == nil ? "false" : "true",
        ])
        return convo
    }
}
