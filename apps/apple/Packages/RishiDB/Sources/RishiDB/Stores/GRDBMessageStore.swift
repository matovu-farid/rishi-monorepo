import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `MessageStore`. See `GRDBBookStore` for the `@unchecked
/// Sendable` rationale. The `tool_calls` column is stored as-is from
/// `Message.toolCalls` — the model already represents it as an opaque JSON
/// String, so no extra encoding is needed here. `JSONColumnCodec` is
/// available for future callers that want typed access to the column.
public final class GRDBMessageStore: MessageStore, Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func messages(for conversationId: ConversationID) async throws -> [Message] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Messages.table,
            "operation": "messages_for_conversation",
        ])
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \(Tables.Messages.table)
                    WHERE \(Tables.Messages.conversationId) = ?
                    ORDER BY \(Tables.Messages.createdAt) ASC
                """, arguments: [conversationId.uuidString])
                return rows.compactMap(Self.decode)
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
            return try await dbQueue.read { db -> Message? in
                let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Messages.table)
                    WHERE \(Tables.Messages.id) = ?
                """, arguments: [id.uuidString])
                return row.flatMap(Self.decode)
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
            try await dbQueue.write { db in
                // FK target is conversations.id; conformance helper uses synthetic
                // conversation ids so defer FK at the txn boundary.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: """
                    INSERT INTO \(Tables.Messages.table)
                      (\(Tables.Messages.id), \(Tables.Messages.conversationId),
                       \(Tables.Messages.role), \(Tables.Messages.content),
                       \(Tables.Messages.toolCalls), \(Tables.Messages.createdAt))
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Messages.id)) DO UPDATE SET
                      \(Tables.Messages.conversationId) = excluded.\(Tables.Messages.conversationId),
                      \(Tables.Messages.role) = excluded.\(Tables.Messages.role),
                      \(Tables.Messages.content) = excluded.\(Tables.Messages.content),
                      \(Tables.Messages.toolCalls) = excluded.\(Tables.Messages.toolCalls),
                      \(Tables.Messages.createdAt) = excluded.\(Tables.Messages.createdAt)
                """, arguments: [
                    message.id.uuidString, message.conversationId.uuidString,
                    message.role.rawValue, message.content,
                    message.toolCalls, message.createdAt.timeIntervalSince1970,
                ])
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
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Messages.table) WHERE \(Tables.Messages.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(message:) failed: \(error)")
        }
    }

    private static func decode(_ row: Row) -> Message? {
        guard
            let idStr: String = row[Tables.Messages.id], let id = UUID(uuidString: idStr),
            let convIdStr: String = row[Tables.Messages.conversationId],
            let convId = UUID(uuidString: convIdStr),
            let roleStr: String = row[Tables.Messages.role], let role = MessageRole(rawValue: roleStr),
            let content: String = row[Tables.Messages.content],
            let createdAt: Double = row[Tables.Messages.createdAt]
        else { return nil }
        let toolCalls: String? = row[Tables.Messages.toolCalls]
        return Message(
            id: id, conversationId: convId,
            role: role, content: content,
            toolCalls: toolCalls,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
