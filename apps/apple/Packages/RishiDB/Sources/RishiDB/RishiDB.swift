import Foundation
@_exported import GRDB

/// Public surface for the RishiDB package.
public enum RishiDB {

    /// Marker for the public RishiDB API version. Bump when the surface breaks.
    public static let apiVersion = "0.2.0-schema"

    /// Open (or create) a GRDB `DatabaseQueue` at the given file URL,
    /// configured for the RishiDB schema and ready for use.
    ///
    /// - Enables foreign keys via `PRAGMA foreign_keys = ON` on every connection.
    /// - Runs all registered migrations (v1_initial, v2_placeholder) before returning.
    ///
    /// Pass `URL(fileURLWithPath: ":memory:")` for an in-memory queue (tests).
    public static func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        // SQLite treats the literal string ":memory:" as the in-memory database
        // sentinel. `URL(fileURLWithPath: ":memory:").path` resolves to an
        // ABSOLUTE filesystem path (e.g. "/cwd/:memory:"), which would create
        // a real on-disk file named ":memory:". Detect the sentinel and
        // forward it via the no-path initialiser so callers get a true
        // in-memory queue.
        let queue: DatabaseQueue
        if url.lastPathComponent == ":memory:" {
            queue = try DatabaseQueue(configuration: config)
        } else {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        }

        try Migrations.migrator.migrate(queue)
        return queue
    }
}
