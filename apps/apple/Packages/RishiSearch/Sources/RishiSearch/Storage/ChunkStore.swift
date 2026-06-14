import Foundation
import GRDB

/// Per-book GRDB-backed table of `(chunk_id, page, text)` rows.
///
/// One `DatabasePool` per book — `<rootURL>/Books/<bookId>/chunks.db`.
/// Writes happen at index-build time (background `IndexBuilder`); reads
/// happen at query time (voice session). Single writer + many readers is
/// exactly what GRDB's WAL `DatabasePool` is designed for, so we use it
/// over `DatabaseQueue`.
///
/// Schema (v1_chunks migration, applied automatically on `init`):
///
/// ```sql
/// CREATE TABLE chunks (
///     chunk_id INTEGER PRIMARY KEY,
///     page     INTEGER NOT NULL,
///     text     TEXT    NOT NULL
/// );
/// CREATE INDEX idx_chunks_page ON chunks(page);
/// ```
///
/// `chunk_id` is the same `UInt64` USearch key that the index stores —
/// `USearchBookSearch.search` joins on it.
///
/// Concurrency: `@unchecked Sendable` because `DatabasePool` already
/// serialises writes internally. The store itself is stateless after init.
final class ChunkStore: @unchecked Sendable {

    enum StorageError: Error, Equatable {
        case dbOpenFailed(message: String)
    }

    private let dbPool: DatabasePool

    init(dbURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        do {
            self.dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            throw StorageError.dbOpenFailed(message: String(describing: error))
        }
        try Self.migrator.migrate(dbPool)
    }

    /// Append (or replace) chunk rows. Idempotent on `chunk_id`.
    /// Empty input is a no-op.
    func append(chunks: [(chunkId: UInt64, page: Int, text: String)]) async throws {
        guard !chunks.isEmpty else { return }
        try await dbPool.write { db in
            for c in chunks {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO chunks (chunk_id, page, text) VALUES (?, ?, ?)",
                    arguments: [Int64(bitPattern: c.chunkId), c.page, c.text]
                )
            }
        }
    }

    /// Look up rows by chunk id. Returns a map keyed by chunk id; missing
    /// ids are silently absent (no throw).
    func lookup(chunkIds: [UInt64]) async throws -> [UInt64: (page: Int, text: String)] {
        guard !chunkIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chunkIds.count).joined(separator: ",")
        let signedKeys = chunkIds.map { Int64(bitPattern: $0) }
        return try await dbPool.read { db -> [UInt64: (page: Int, text: String)] in
            var out: [UInt64: (page: Int, text: String)] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT chunk_id, page, text FROM chunks WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(signedKeys)
            )
            for row in rows {
                let signed: Int64 = row["chunk_id"]
                let id = UInt64(bitPattern: signed)
                let page: Int = row["page"]
                let text: String = row["text"]
                out[id] = (page: page, text: text)
            }
            return out
        }
    }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_chunks") { db in
            try db.execute(sql: """
                CREATE TABLE chunks (
                    chunk_id INTEGER PRIMARY KEY,
                    page     INTEGER NOT NULL,
                    text     TEXT    NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_chunks_page ON chunks(page);")
        }
        return migrator
    }()
}
