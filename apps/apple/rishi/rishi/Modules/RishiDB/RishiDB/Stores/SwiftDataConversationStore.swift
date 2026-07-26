import Foundation
import SwiftData



/// SwiftData-backed `ConversationStore`.
public final class SwiftDataConversationStore: ConversationStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func conversations(for userId: UserID) async throws -> [Conversation] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Conversations.table,
            "operation": "conversations_for_user",
        ])
        do {
            return try await dbStore.read { context in
                var descriptor = FetchDescriptor<ConversationEntity>(
                    predicate: #Predicate { $0.userId == userId },
                    sortBy: [SortDescriptor(\ConversationEntity.updatedAt, order: .reverse)]
                )
                descriptor.fetchLimit = nil
                return try context.fetch(descriptor).map(\.conversationValue)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("conversations(for:) failed: \(error)")
        }
    }

    public func conversation(_ id: ConversationID) async throws -> Conversation? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Conversations.table,
            "operation": "conversation_by_id",
        ])
        do {
            return try await dbStore.read { context -> Conversation? in
                var descriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.conversationValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("conversation(_:) failed: \(error)")
        }
    }

    public func upsert(_ conversation: Conversation) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Conversations.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == conversation.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: conversation)
                } else {
                    context.insert(
                        ConversationEntity(
                            id: conversation.id,
                            userId: conversation.userId,
                            bookId: conversation.bookId,
                            title: conversation.title,
                            createdAt: conversation.createdAt,
                            updatedAt: conversation.updatedAt
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(conversation:) failed: \(error)")
        }
    }

    public func delete(_ id: ConversationID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Conversations.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, of: MessageEntity.self, matching: #Predicate { $0.conversationId == id })
                try Self.deleteAll(context, of: ConversationEntity.self, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(conversation:) failed: \(error)")
        }
    }

    private static func deleteAll<T: PersistentModel>(
        _ context: ModelContext,
        of type: T.Type,
        matching predicate: Predicate<T>
    ) throws {
        let descriptor = FetchDescriptor<T>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
