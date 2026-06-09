import Foundation
import RishiCore

public actor InMemoryConversationStore: ConversationStore {
    private var storage: [ConversationID: Conversation] = [:]

    public init(initial: [Conversation] = []) {
        for c in initial { storage[c.id] = c }
    }

    public func conversations(for userId: UserID) async throws -> [Conversation] {
        storage.values
            .filter { $0.userId == userId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func conversation(_ id: ConversationID) async throws -> Conversation? {
        storage[id]
    }

    public func upsert(_ conversation: Conversation) async throws {
        storage[conversation.id] = conversation
    }

    public func delete(_ id: ConversationID) async throws {
        storage.removeValue(forKey: id)
    }
}
