import Foundation
import Observation
import RishiCore
import RishiLogging

/// Drives the Conversations tab (CHAT-06 / CHAT-07).
///
/// Loads the current user's conversations + a per-conversation message index
/// so search can match BOTH conversation titles AND any message content. The
/// search itself is delegated to ``ConversationSearchFilter`` (pure value type)
/// — this class only owns the I/O and the bindable state.
///
/// Threading: `@MainActor` because the SwiftUI list view binds directly to the
/// observable surface and we want zero actor hops on the render path.
@MainActor
@Observable
public final class ConversationsListViewModel {

    // MARK: - Bindable state

    public var searchQuery: String = ""

    public private(set) var conversations: [Conversation] = []
    public private(set) var messagesByConversation: [ConversationID: [Message]] = [:]
    public private(set) var loadError: Error? = nil

    // MARK: - Dependencies

    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore

    public init(
        conversationStore: any ConversationStore,
        messageStore: any MessageStore
    ) {
        self.conversationStore = conversationStore
        self.messageStore = messageStore
    }

    // MARK: - Derived

    /// Result of ``ConversationSearchFilter/apply(conversations:messagesByConversation:query:)``
    /// over the current state. Empty / whitespace `searchQuery` returns every
    /// loaded conversation sorted by `updatedAt` descending.
    public var filteredConversations: [Conversation] {
        ConversationSearchFilter.apply(
            conversations: conversations,
            messagesByConversation: messagesByConversation,
            query: searchQuery
        )
    }

    // MARK: - Public API

    /// Hydrates `conversations` for `userId` and the per-conversation message
    /// index used by the search filter. On error, surfaces `loadError` and
    /// resets state — the UI then falls back to its empty-state branch.
    public func load(userId: UserID) async {
        loadError = nil
        do {
            let fetched = try await conversationStore.conversations(for: userId)
            let sorted = fetched.sorted { $0.updatedAt > $1.updatedAt }
            var index: [ConversationID: [Message]] = [:]
            for convo in sorted {
                // Per-conversation message load failure is non-fatal: empty
                // array means the conversation simply contributes no message
                // hits to the search index.
                let msgs = (try? await messageStore.messages(for: convo.id)) ?? []
                index[convo.id] = msgs
            }
            self.conversations = sorted
            self.messagesByConversation = index
        } catch {
            Log.event("chat.conversations.load.failed", level: .error, data: [
                "error": "\(error)",
            ])
            self.loadError = error
            self.conversations = []
            self.messagesByConversation = [:]
        }
    }

    /// Deletes the conversation AND every persisted message whose
    /// `conversationId == id`. Message deletes happen FIRST so a partial
    /// failure can't orphan rows (sync would otherwise resurrect them on the
    /// next inbound wave).
    public func delete(id: ConversationID) async {
        do {
            // Prefer the in-memory index; fall back to a fresh fetch so we
            // don't orphan messages a stale index didn't know about.
            let msgs: [Message]
            if let cached = messagesByConversation[id] {
                msgs = cached
            } else {
                msgs = (try? await messageStore.messages(for: id)) ?? []
            }
            for message in msgs {
                try await messageStore.delete(message.id)
            }
            try await conversationStore.delete(id)
            conversations.removeAll { $0.id == id }
            messagesByConversation.removeValue(forKey: id)
        } catch {
            Log.event("chat.conversations.delete.failed", level: .error, data: [
                "conversation_id": id.uuidString,
                "error": "\(error)",
            ])
        }
    }
}
