import Foundation
import Observation

/// Loads rows independently from optional transcript search hydration.
@MainActor
@Observable
public final class ConversationsListViewModel {
    public enum SearchIndexState {
        case idle, indexing, ready
        case partial(Error)
    }

    public var searchQuery = ""
    public private(set) var conversations: [Conversation] = []
    public private(set) var messagesByConversation: [ConversationID: [Message]] = [:]
    public private(set) var isLoading = false
    public private(set) var loadError: Error?
    public private(set) var deleteError: Error?
    public private(set) var searchIndexState: SearchIndexState = .idle
    public private(set) var indexRequestRevision: UInt64 = 0

    private let conversationStore: any ConversationStore
    private let messageStore: any MessageStore
    private var currentUserID: UserID?
    private var rowLoadID: UUID?
    private var indexGeneration: UUID?
    private var deleteAttemptID: UUID?

    public init(conversationStore: any ConversationStore, messageStore: any MessageStore) {
        self.conversationStore = conversationStore
        self.messageStore = messageStore
    }

    public var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var filteredConversations: [Conversation] {
        ConversationSearchFilter.apply(
            conversations: conversations, messagesByConversation: messagesByConversation, query: searchQuery
        )
    }

    public func load(userId: UserID) async {
        if currentUserID != userId {
            currentUserID = userId
            conversations = []
            deleteError = nil
            deleteAttemptID = nil
            invalidateSearchIndex()
        }
        let loadID = UUID()
        rowLoadID = loadID
        isLoading = true
        loadError = nil
        defer { if rowLoadID == loadID { isLoading = false } }
        do {
            let fetched = try await conversationStore.conversations(for: userId)
            guard currentUserID == userId, rowLoadID == loadID, !Task.isCancelled else { return }
            conversations = fetched.sorted { $0.updatedAt > $1.updatedAt }
            // Inbound messages can change while conversation IDs stay identical.
            invalidateSearchIndex()
        } catch {
            guard currentUserID == userId, rowLoadID == loadID, !Task.isCancelled else { return }
            loadError = error
            Log.event("chat.conversations.load.failed", level: .error, data: ["error": "\(error)"])
        }
    }

    public func refreshAfterSync(userId: UserID) async { await load(userId: userId) }

    public func retrySearchIndex() { invalidateSearchIndex() }

    private func invalidateSearchIndex() {
        indexGeneration = nil
        messagesByConversation = [:]
        searchIndexState = .idle
        indexRequestRevision &+= 1
    }

    public func ensureSearchIndex(userId: UserID, requestRevision: UInt64) async {
        guard currentUserID == userId, indexRequestRevision == requestRevision,
              hasSearchQuery, !Task.isCancelled else { return }
        if case .ready = searchIndexState { return }
        let generation = UUID()
        indexGeneration = generation
        searchIndexState = .indexing
        let rows = conversations
        var index: [ConversationID: [Message]] = [:]
        var firstError: Error?
        defer {
            if indexGeneration == generation {
                indexGeneration = nil
                if Task.isCancelled || !hasSearchQuery { searchIndexState = .idle }
            }
        }
        for conversation in rows {
            do {
                let messages = try await messageStore.messages(for: conversation.id)
                guard ownsIndex(userId, requestRevision, generation) else { return }
                index[conversation.id] = messages
            } catch {
                guard ownsIndex(userId, requestRevision, generation) else { return }
                if firstError == nil { firstError = error }
            }
            messagesByConversation = index
        }
        guard ownsIndex(userId, requestRevision, generation) else { return }
        searchIndexState = firstError.map(SearchIndexState.partial) ?? .ready
    }

    private func ownsIndex(_ userID: UserID, _ revision: UInt64, _ generation: UUID) -> Bool {
        currentUserID == userID && indexRequestRevision == revision && indexGeneration == generation
            && hasSearchQuery && !Task.isCancelled
    }

    /// Reads persisted children afresh; search hydration is never deletion input.
    @discardableResult
    public func delete(id: ConversationID) async -> Bool {
        let userID = currentUserID
        let attemptID = UUID()
        deleteAttemptID = attemptID
        deleteError = nil
        do {
            let messages = try await messageStore.messages(for: id)
            for message in messages { try await messageStore.delete(message.id) }
            try await conversationStore.delete(id)
            NotificationCenter.default.post(name: .rishiSearchableDataDidChange, object: nil)
            if currentUserID == userID {
                // A suspended pre-delete row load must not restore the deleted row.
                rowLoadID = nil
                isLoading = false
                conversations.removeAll { $0.id == id }
                invalidateSearchIndex()
            }
            return true
        } catch {
            if currentUserID == userID, deleteAttemptID == attemptID { deleteError = error }
            Log.event("chat.conversations.delete.failed", level: .error, data: [
                "conversation_id": id.uuidString, "error": "\(error)"
            ])
            return false
        }
    }
}
