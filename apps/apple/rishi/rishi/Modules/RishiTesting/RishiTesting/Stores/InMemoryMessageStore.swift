import Foundation


public actor InMemoryMessageStore: MessageStore {
    private var storage: [MessageID: Message] = [:]

    public init(initial: [Message] = []) {
        for m in initial { storage[m.id] = m }
    }

    public func messages(for conversationId: ConversationID) async throws -> [Message] {
        storage.values
            .filter { $0.conversationId == conversationId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func message(_ id: MessageID) async throws -> Message? {
        storage[id]
    }

    public func upsert(_ message: Message) async throws {
        storage[message.id] = message
    }

    public func delete(_ id: MessageID) async throws {
        storage.removeValue(forKey: id)
    }
}
