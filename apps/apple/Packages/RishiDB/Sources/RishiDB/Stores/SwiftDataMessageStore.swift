import Foundation
import SwiftData
import RishiCore
import RishiLogging

/// SwiftData-backed `MessageStore`.
public final class SwiftDataMessageStore: MessageStore, Sendable {

    private let dbStore: RishiDBStore

    public init(dbStore: RishiDBStore) {
        self.dbStore = dbStore
    }

    public func messages(for conversationId: ConversationID) async throws -> [Message] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Messages.table,
            "operation": "messages_for_conversation",
        ])
        do {
            return try await dbStore.read { context in
                var descriptor = FetchDescriptor<MessageEntity>(
                    predicate: #Predicate { $0.conversationId == conversationId },
                    sortBy: [SortDescriptor(\MessageEntity.createdAt)]
                )
                descriptor.fetchLimit = nil
                return try context.fetch(descriptor).compactMap(\.messageValue)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("messages(for:) failed: \(error)")
        }
    }

    public func message(_ id: MessageID) async throws -> Message? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Messages.table,
            "operation": "message_by_id",
        ])
        do {
            return try await dbStore.read { context -> Message? in
                var descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.messageValue
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("message(_:) failed: \(error)")
        }
    }

    public func upsert(_ message: Message) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Messages.table,
            "operation": "upsert",
        ])
        do {
            try await dbStore.write { context in
                var descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == message.id })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.update(from: message)
                } else {
                    context.insert(
                        MessageEntity(
                            id: message.id,
                            conversationId: message.conversationId,
                            roleRawValue: message.role.rawValue,
                            content: message.content,
                            toolCalls: message.toolCalls,
                            createdAt: message.createdAt
                        )
                    )
                }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(message:) failed: \(error)")
        }
    }

    public func delete(_ id: MessageID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Messages.table,
            "operation": "delete",
        ])
        do {
            try await dbStore.write { context in
                try Self.deleteAll(context, matching: #Predicate { $0.id == id })
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(message:) failed: \(error)")
        }
    }

    private static func deleteAll(_ context: ModelContext, matching predicate: Predicate<MessageEntity>) throws {
        let descriptor = FetchDescriptor<MessageEntity>(predicate: predicate)
        for item in try context.fetch(descriptor) {
            context.delete(item)
        }
    }
}
