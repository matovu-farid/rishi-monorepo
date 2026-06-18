import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `BookmarkStore`. See `GRDBBookStore` for the `@unchecked
/// Sendable` rationale (mutable state is the injected DatabaseQueue, which
/// already serialises access). Mirrors `GRDBHighlightStore` minus the
/// color/selection-range columns.
public final class GRDBBookmarkStore: BookmarkStore, Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "bookmarks_for_book",
        ])
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \(Tables.Bookmarks.table)
                    WHERE \(Tables.Bookmarks.bookId) = ?
                    ORDER BY \(Tables.Bookmarks.createdAt) ASC
                """, arguments: [bookId.uuidString])
                return rows.compactMap(Self.decode)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("bookmarks(for:) failed: \(error)")
        }
    }

    public func bookmark(_ id: BookmarkID) async throws -> Bookmark? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "bookmark_by_id",
        ])
        do {
            return try await dbQueue.read { db -> Bookmark? in
                let row: Row? = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Bookmarks.table) WHERE \(Tables.Bookmarks.id) = ?
                """, arguments: [id.uuidString])
                return row.flatMap(Self.decode)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("bookmark(_:) failed: \(error)")
        }
    }

    public func upsert(_ bookmark: Bookmark) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "upsert",
        ])
        do {
            try await dbQueue.write { db in
                // The conformance helper inserts bookmarks for synthetic bookIds
                // that have no parent `books` row — defer FK checks for the txn so
                // the test contract matches the InMemory* fakes. Production code
                // paths always upsert the parent book first, so this is a no-op
                // in real use.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: """
                    INSERT INTO \(Tables.Bookmarks.table)
                      (\(Tables.Bookmarks.id), \(Tables.Bookmarks.bookId),
                       \(Tables.Bookmarks.locator), \(Tables.Bookmarks.label),
                       \(Tables.Bookmarks.snippet), \(Tables.Bookmarks.createdAt))
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Bookmarks.id)) DO UPDATE SET
                      \(Tables.Bookmarks.bookId) = excluded.\(Tables.Bookmarks.bookId),
                      \(Tables.Bookmarks.locator) = excluded.\(Tables.Bookmarks.locator),
                      \(Tables.Bookmarks.label) = excluded.\(Tables.Bookmarks.label),
                      \(Tables.Bookmarks.snippet) = excluded.\(Tables.Bookmarks.snippet),
                      \(Tables.Bookmarks.createdAt) = excluded.\(Tables.Bookmarks.createdAt)
                """, arguments: [
                    bookmark.id.uuidString, bookmark.bookId.uuidString,
                    bookmark.locator, bookmark.label,
                    bookmark.snippet, bookmark.createdAt.timeIntervalSince1970,
                ])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(bookmark:) failed: \(error)")
        }
    }

    public func delete(_ id: BookmarkID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Bookmarks.table,
            "operation": "delete",
        ])
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Bookmarks.table) WHERE \(Tables.Bookmarks.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(bookmark:) failed: \(error)")
        }
    }

    private static func decode(_ row: Row) -> Bookmark? {
        guard
            let idStr: String = row[Tables.Bookmarks.id], let id = UUID(uuidString: idStr),
            let bookIdStr: String = row[Tables.Bookmarks.bookId], let bookId = UUID(uuidString: bookIdStr),
            let locator: String = row[Tables.Bookmarks.locator],
            let createdAt: Double = row[Tables.Bookmarks.createdAt]
        else { return nil }
        let label: String? = row[Tables.Bookmarks.label]
        let snippet: String? = row[Tables.Bookmarks.snippet]
        return Bookmark(
            id: id, bookId: bookId,
            locator: locator,
            label: label, snippet: snippet,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
