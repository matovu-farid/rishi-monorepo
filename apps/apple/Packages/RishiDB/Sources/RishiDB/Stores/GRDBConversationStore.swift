import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `ConversationStore`. See `GRDBBookStore` for the `@unchecked
/// Sendable` rationale.
public final class GRDBConversationStore: ConversationStore, Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func conversations(for userId: UserID) async throws -> [Conversation] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Conversations.table,
            "operation": "conversations_for_user",
        ])
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \(Tables.Conversations.table)
                    WHERE \(Tables.Conversations.userId) = ?
                    ORDER BY \(Tables.Conversations.updatedAt) DESC
                """, arguments: [userId.uuidString])
                return rows.compactMap(Self.decode)
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
            return try await dbQueue.read { db -> Conversation? in
                let row: Row? = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Conversations.table) WHERE \(Tables.Conversations.id) = ?
                """, arguments: [id.uuidString])
                return row.flatMap(Self.decode)
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
            try await dbQueue.write { db in
                // bookId is a nullable FK to books — conformance helper uses nil
                // bookIds, but defer FK in case a caller targets a synthetic id.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: """
                    INSERT INTO \(Tables.Conversations.table)
                      (\(Tables.Conversations.id), \(Tables.Conversations.userId),
                       \(Tables.Conversations.bookId), \(Tables.Conversations.title),
                       \(Tables.Conversations.createdAt), \(Tables.Conversations.updatedAt))
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Conversations.id)) DO UPDATE SET
                      \(Tables.Conversations.userId) = excluded.\(Tables.Conversations.userId),
                      \(Tables.Conversations.bookId) = excluded.\(Tables.Conversations.bookId),
                      \(Tables.Conversations.title) = excluded.\(Tables.Conversations.title),
                      \(Tables.Conversations.createdAt) = excluded.\(Tables.Conversations.createdAt),
                      \(Tables.Conversations.updatedAt) = excluded.\(Tables.Conversations.updatedAt)
                """, arguments: [
                    conversation.id.uuidString, conversation.userId.uuidString,
                    conversation.bookId?.uuidString, conversation.title,
                    conversation.createdAt.timeIntervalSince1970,
                    conversation.updatedAt.timeIntervalSince1970,
                ])
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
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Conversations.table) WHERE \(Tables.Conversations.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(conversation:) failed: \(error)")
        }
    }

    private static func decode(_ row: Row) -> Conversation? {
        guard
            let idStr: String = row[Tables.Conversations.id], let id = UUID(uuidString: idStr),
            let userIdStr: String = row[Tables.Conversations.userId], let userId = UUID(uuidString: userIdStr),
            let title: String = row[Tables.Conversations.title],
            let createdAt: Double = row[Tables.Conversations.createdAt],
            let updatedAt: Double = row[Tables.Conversations.updatedAt]
        else { return nil }
        let bookIdStr: String? = row[Tables.Conversations.bookId]
        return Conversation(
            id: id, userId: userId,
            bookId: bookIdStr.flatMap(UUID.init(uuidString:)),
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
