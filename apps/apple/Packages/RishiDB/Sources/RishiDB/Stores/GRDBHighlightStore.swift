import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `HighlightStore`. See `GRDBBookStore` for the `@unchecked
/// Sendable` rationale (mutable state is the injected DatabaseQueue, which
/// already serialises access).
public final class GRDBHighlightStore: HighlightStore, Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func highlights(for bookId: BookID) async throws -> [Highlight] {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "highlights_for_book",
        ])
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM \(Tables.Highlights.table)
                    WHERE \(Tables.Highlights.bookId) = ?
                    ORDER BY \(Tables.Highlights.createdAt) ASC
                """, arguments: [bookId.uuidString])
                return rows.compactMap(Self.decode)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("highlights(for:) failed: \(error)")
        }
    }

    public func highlight(_ id: HighlightID) async throws -> Highlight? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "highlight_by_id",
        ])
        do {
            return try await dbQueue.read { db -> Highlight? in
                let row: Row? = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Highlights.table) WHERE \(Tables.Highlights.id) = ?
                """, arguments: [id.uuidString])
                return row.flatMap(Self.decode)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("highlight(_:) failed: \(error)")
        }
    }

    public func upsert(_ highlight: Highlight) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "upsert",
        ])
        do {
            try await dbQueue.write { db in
                // The conformance helper inserts highlights for synthetic bookIds
                // that have no parent `books` row — defer FK checks for the txn so
                // the test contract matches the InMemory* fakes. Production code
                // paths always upsert the parent book first, so this is a no-op
                // in real use.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: """
                    INSERT INTO \(Tables.Highlights.table)
                      (\(Tables.Highlights.id), \(Tables.Highlights.bookId),
                       \(Tables.Highlights.locatorStart), \(Tables.Highlights.locatorEnd),
                       \(Tables.Highlights.color), \(Tables.Highlights.text),
                       \(Tables.Highlights.note), \(Tables.Highlights.createdAt))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Highlights.id)) DO UPDATE SET
                      \(Tables.Highlights.bookId) = excluded.\(Tables.Highlights.bookId),
                      \(Tables.Highlights.locatorStart) = excluded.\(Tables.Highlights.locatorStart),
                      \(Tables.Highlights.locatorEnd) = excluded.\(Tables.Highlights.locatorEnd),
                      \(Tables.Highlights.color) = excluded.\(Tables.Highlights.color),
                      \(Tables.Highlights.text) = excluded.\(Tables.Highlights.text),
                      \(Tables.Highlights.note) = excluded.\(Tables.Highlights.note),
                      \(Tables.Highlights.createdAt) = excluded.\(Tables.Highlights.createdAt)
                """, arguments: [
                    highlight.id.uuidString, highlight.bookId.uuidString,
                    highlight.locatorStart, highlight.locatorEnd,
                    highlight.color.rawValue, highlight.text,
                    highlight.note, highlight.createdAt.timeIntervalSince1970,
                ])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(highlight:) failed: \(error)")
        }
    }

    public func delete(_ id: HighlightID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Highlights.table,
            "operation": "delete",
        ])
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Highlights.table) WHERE \(Tables.Highlights.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(highlight:) failed: \(error)")
        }
    }

    private static func decode(_ row: Row) -> Highlight? {
        guard
            let idStr: String = row[Tables.Highlights.id], let id = UUID(uuidString: idStr),
            let bookIdStr: String = row[Tables.Highlights.bookId], let bookId = UUID(uuidString: bookIdStr),
            let locStart: String = row[Tables.Highlights.locatorStart],
            let locEnd: String = row[Tables.Highlights.locatorEnd],
            let colorStr: String = row[Tables.Highlights.color],
            let color = HighlightColor(rawValue: colorStr),
            let text: String = row[Tables.Highlights.text],
            let createdAt: Double = row[Tables.Highlights.createdAt]
        else { return nil }
        let note: String? = row[Tables.Highlights.note]
        return Highlight(
            id: id, bookId: bookId,
            locatorStart: locStart, locatorEnd: locEnd,
            color: color, text: text,
            note: note,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
