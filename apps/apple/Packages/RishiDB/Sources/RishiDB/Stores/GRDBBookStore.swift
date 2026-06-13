import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `BookStore`. Marked `@unchecked Sendable` because the only
/// mutable state is the injected `DatabaseWriter` (a `DatabaseQueue` or
/// `DatabasePool`), which is itself Sendable; GRDB serialises writes and
/// (with a Pool) parallelises reads internally, so the class needs no
/// additional locking. We prefer a `final class` over an `actor` so callers
/// can still benefit from the synchronous `dbQueue.read { db in ... }`
/// ergonomics without an outer actor hop.
///
/// The store accepts `any DatabaseWriter` so production code can pass a
/// `DatabasePool` (concurrent readers) while tests can pass an in-memory
/// `DatabaseQueue`.
public final class GRDBBookStore: BookStore, @unchecked Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func books(for userId: UserID) async throws -> [Book] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "books_for_user",
        ])
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \(Tables.Books.table)
                    WHERE \(Tables.Books.userId) = ?
                    ORDER BY \(Tables.Books.addedAt) DESC
                """, arguments: [userId.uuidString])
                return rows.compactMap { Self.decode($0) }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("books(for:) failed: \(error)")
        }
    }

    public func book(_ id: BookID) async throws -> Book? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "book_by_id",
        ])
        do {
            return try await dbQueue.read { db -> Book? in
                let row: Row? = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Books.table) WHERE \(Tables.Books.id) = ?
                """, arguments: [id.uuidString])
                return row.flatMap { Self.decode($0) }
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("book(_:) failed: \(error)")
        }
    }

    public func upsert(_ book: Book) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "upsert",
        ])
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO \(Tables.Books.table)
                      (\(Tables.Books.id), \(Tables.Books.userId), \(Tables.Books.title), \(Tables.Books.author),
                       \(Tables.Books.formatType), \(Tables.Books.addedAt), \(Tables.Books.openedAt),
                       \(Tables.Books.fileURL), \(Tables.Books.coverPath),
                       \(Tables.Books.positionId), \(Tables.Books.conversationId))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Books.id)) DO UPDATE SET
                      \(Tables.Books.userId) = excluded.\(Tables.Books.userId),
                      \(Tables.Books.title) = excluded.\(Tables.Books.title),
                      \(Tables.Books.author) = excluded.\(Tables.Books.author),
                      \(Tables.Books.formatType) = excluded.\(Tables.Books.formatType),
                      \(Tables.Books.addedAt) = excluded.\(Tables.Books.addedAt),
                      \(Tables.Books.openedAt) = excluded.\(Tables.Books.openedAt),
                      \(Tables.Books.fileURL) = excluded.\(Tables.Books.fileURL),
                      \(Tables.Books.coverPath) = excluded.\(Tables.Books.coverPath),
                      \(Tables.Books.positionId) = excluded.\(Tables.Books.positionId),
                      \(Tables.Books.conversationId) = excluded.\(Tables.Books.conversationId)
                """, arguments: [
                    book.id.uuidString, book.userId.uuidString, book.title, book.author,
                    book.formatType.rawValue, book.addedAt.timeIntervalSince1970, book.openedAt?.timeIntervalSince1970,
                    book.fileURL, book.coverPath,
                    book.positionId?.uuidString, book.conversationId?.uuidString,
                ])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(book:) failed: \(error)")
        }
    }

    public func delete(_ id: BookID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Books.table,
            "operation": "delete",
        ])
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Books.table) WHERE \(Tables.Books.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(book:) failed: \(error)")
        }
    }

    // MARK: - Decode

    private static func decode(_ row: Row) -> Book? {
        guard
            let idStr: String = row[Tables.Books.id],
            let id = UUID(uuidString: idStr),
            let userIdStr: String = row[Tables.Books.userId],
            let userId = UUID(uuidString: userIdStr),
            let title: String = row[Tables.Books.title],
            let formatStr: String = row[Tables.Books.formatType],
            let format = BookFormat(rawValue: formatStr),
            let addedAt: Double = row[Tables.Books.addedAt],
            let fileURL: String = row[Tables.Books.fileURL]
        else { return nil }

        let author: String? = row[Tables.Books.author]
        let coverPath: String? = row[Tables.Books.coverPath]
        let openedAt: Double? = row[Tables.Books.openedAt]
        let positionIdStr: String? = row[Tables.Books.positionId]
        let conversationIdStr: String? = row[Tables.Books.conversationId]

        return Book(
            id: id,
            userId: userId,
            title: title,
            author: author,
            formatType: format,
            addedAt: Date(timeIntervalSince1970: addedAt),
            openedAt: openedAt.map { Date(timeIntervalSince1970: $0) },
            fileURL: fileURL,
            coverPath: coverPath,
            positionId: positionIdStr.flatMap(UUID.init(uuidString:)),
            conversationId: conversationIdStr.flatMap(UUID.init(uuidString:))
        )
    }
}
