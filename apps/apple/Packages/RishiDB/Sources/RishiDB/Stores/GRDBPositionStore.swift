import Foundation
import GRDB
import RishiCore
import RishiLogging

/// GRDB-backed `PositionStore`. See `GRDBBookStore` for the `@unchecked
/// Sendable` rationale.
public final class GRDBPositionStore: PositionStore, Sendable {

    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func position(for bookId: BookID) async throws -> Position? {
        Log.event("db.read", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "position_for_book",
        ])
        do {
            return try await dbQueue.read { db -> Position? in
                let row: Row? = try Row.fetchOne(db, sql: """
                    SELECT * FROM \(Tables.Positions.table)
                    WHERE \(Tables.Positions.bookId) = ?
                    ORDER BY \(Tables.Positions.updatedAt) DESC
                    LIMIT 1
                """, arguments: [bookId.uuidString])
                return row.flatMap(Self.decode)
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("position(for:) failed: \(error)")
        }
    }

    public func upsert(_ position: Position) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "upsert",
        ])
        do {
            try await dbQueue.write { db in
                // Defer FK so the conformance helper can insert positions for a
                // synthetic bookId. Production paths upsert the parent book first.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: """
                    INSERT INTO \(Tables.Positions.table)
                      (\(Tables.Positions.id), \(Tables.Positions.bookId),
                       \(Tables.Positions.locator), \(Tables.Positions.percentComplete),
                       \(Tables.Positions.updatedAt))
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(\(Tables.Positions.id)) DO UPDATE SET
                      \(Tables.Positions.bookId) = excluded.\(Tables.Positions.bookId),
                      \(Tables.Positions.locator) = excluded.\(Tables.Positions.locator),
                      \(Tables.Positions.percentComplete) = excluded.\(Tables.Positions.percentComplete),
                      \(Tables.Positions.updatedAt) = excluded.\(Tables.Positions.updatedAt)
                """, arguments: [
                    position.id.uuidString, position.bookId.uuidString,
                    position.locator, position.percentComplete,
                    position.updatedAt.timeIntervalSince1970,
                ])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("upsert(position:) failed: \(error)")
        }
    }

    public func delete(_ id: PositionID) async throws {
        Log.event("db.write", level: .debug, data: [
            "table": Tables.Positions.table,
            "operation": "delete",
        ])
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM \(Tables.Positions.table) WHERE \(Tables.Positions.id) = ?
                """, arguments: [id.uuidString])
            }
        } catch {
            Log.error("db.error", error: error)
            throw RishiError.persistence("delete(position:) failed: \(error)")
        }
    }

    private static func decode(_ row: Row) -> Position? {
        guard
            let idStr: String = row[Tables.Positions.id], let id = UUID(uuidString: idStr),
            let bookIdStr: String = row[Tables.Positions.bookId], let bookId = UUID(uuidString: bookIdStr),
            let locator: String = row[Tables.Positions.locator],
            let percent: Double = row[Tables.Positions.percentComplete],
            let updatedAt: Double = row[Tables.Positions.updatedAt]
        else { return nil }
        return Position(
            id: id, bookId: bookId,
            locator: locator, percentComplete: percent,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
