import Foundation
import GRDB
import RishiCore
import RishiDB

/// GRDB-backed implementation of `SyncMetadataStore`.
///
/// `final class ... Sendable` mirrors `GRDBHighlightStore` — the only stored
/// property is `let dbQueue: any DatabaseWriter` and `DatabaseWriter` is
/// itself `Sendable`, so the compiler proves Sendable directly. GRDB
/// serialises writes and (with a `DatabasePool`) parallelises reads, so an
/// outer actor would double-hop every read/write. The store accepts any
/// `DatabaseWriter` so production code can pass a `DatabasePool` (concurrent
/// readers) while tests can pass an in-memory `DatabaseQueue`.
public final class GRDBSyncMetadataStore: SyncMetadataStore, Sendable {
    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.SyncMetadata.table)
                    (\(Tables.SyncMetadata.entityId), \(Tables.SyncMetadata.entityType), \(Tables.SyncMetadata.dirty))
                VALUES (?, ?, 1)
                ON CONFLICT(\(Tables.SyncMetadata.entityId)) DO UPDATE SET
                    \(Tables.SyncMetadata.entityType) = excluded.\(Tables.SyncMetadata.entityType),
                    \(Tables.SyncMetadata.dirty) = 1
                """,
                arguments: [id, type])
        }
    }

    public func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        let ts = lastSyncedAt.timeIntervalSince1970
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.SyncMetadata.table)
                    (\(Tables.SyncMetadata.entityId), \(Tables.SyncMetadata.entityType), \(Tables.SyncMetadata.remoteEtag), \(Tables.SyncMetadata.lastSyncedAt), \(Tables.SyncMetadata.dirty))
                VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(\(Tables.SyncMetadata.entityId)) DO UPDATE SET
                    \(Tables.SyncMetadata.entityType) = excluded.\(Tables.SyncMetadata.entityType),
                    \(Tables.SyncMetadata.remoteEtag) = excluded.\(Tables.SyncMetadata.remoteEtag),
                    \(Tables.SyncMetadata.lastSyncedAt) = excluded.\(Tables.SyncMetadata.lastSyncedAt),
                    \(Tables.SyncMetadata.dirty) = 0
                """,
                arguments: [id, type, remoteEtag, ts])
        }
    }

    public func allDirty() async throws -> [SyncPendingItem] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Tables.SyncMetadata.entityId), \(Tables.SyncMetadata.entityType)
                FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.dirty) = 1
                ORDER BY \(Tables.SyncMetadata.entityId) ASC
                """)
            return rows.compactMap(Self.decodePending)
        }
    }

    public func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] {
        let type = kind.rawValue
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Tables.SyncMetadata.entityId), \(Tables.SyncMetadata.entityType)
                FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.dirty) = 1 AND \(Tables.SyncMetadata.entityType) = ?
                ORDER BY \(Tables.SyncMetadata.entityId) ASC
                LIMIT ?
                """,
                arguments: [type, limit])
            return rows.compactMap(Self.decodePending)
        }
    }

    public func pendingCount() async throws -> Int {
        try await dbQueue.read { db -> Int in
            let row: Row? = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.dirty) = 1
                """)
            let n: Int? = row?["n"]
            return n ?? 0
        }
    }

    public func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? {
        let type = kind.rawValue
        return try await dbQueue.read { db -> Date? in
            let row: Row? = try Row.fetchOne(db, sql: """
                SELECT MAX(\(Tables.SyncMetadata.lastSyncedAt)) AS ts
                FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.entityType) = ? AND \(Tables.SyncMetadata.dirty) = 0
                """,
                arguments: [type])
            guard let ts: Double = row?["ts"] else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
    }

    public func globalLastSyncedAt() async throws -> Date? {
        try await dbQueue.read { db -> Date? in
            let row: Row? = try Row.fetchOne(db, sql: """
                SELECT MAX(\(Tables.SyncMetadata.lastSyncedAt)) AS ts
                FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.dirty) = 0
                """)
            guard let ts: Double = row?["ts"] else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
    }

    public func forget(entityId: UUID, kind: SyncEntityKind) async throws {
        let id = entityId.uuidString
        let type = kind.rawValue
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM \(Tables.SyncMetadata.table)
                WHERE \(Tables.SyncMetadata.entityId) = ? AND \(Tables.SyncMetadata.entityType) = ?
                """,
                arguments: [id, type])
        }
    }

    private static func decodePending(_ row: Row) -> SyncPendingItem? {
        guard
            let idStr: String = row[Tables.SyncMetadata.entityId],
            let typeStr: String = row[Tables.SyncMetadata.entityType],
            let id = UUID(uuidString: idStr),
            let kind = SyncEntityKind(rawValue: typeStr)
        else { return nil }
        return SyncPendingItem(entityId: id, kind: kind)
    }
}
