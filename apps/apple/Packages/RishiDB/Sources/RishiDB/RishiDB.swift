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
    ///
    /// PRODUCTION callers should prefer ``makeDatabasePool(at:)`` — it allows
    /// concurrent readers (parallel `withTaskGroup` fan-outs across stores
    /// stop collapsing to a single serial connection). `DatabaseQueue`
    /// remains the right choice for in-memory test fixtures because
    /// `DatabasePool` requires a real on-disk file.
    public static func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        let config = makeConfiguration()

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

    /// Open (or create) a GRDB `DatabasePool` at the given file URL,
    /// configured for the RishiDB schema and ready for production use.
    ///
    /// `DatabasePool` allows N concurrent READ connections while writes still
    /// serialize on a single writer — this is GRDB's recommended shape for an
    /// app that fans out across multiple stores. Every `pool.read { db in ... }`
    /// can run in parallel; only `pool.write { db in ... }` is serialized.
    ///
    /// GRDB enables SQLite WAL mode automatically when opening a Pool.
    ///
    /// - Enables foreign keys via `PRAGMA foreign_keys = ON` on every connection.
    /// - Runs all registered migrations before returning. The migrator owns
    ///   serializing the migration as a single write — it accepts any
    ///   `DatabaseWriter`, so the call site is identical to the Queue path.
    ///
    /// In-memory databases (`:memory:`) are NOT supported by `DatabasePool` —
    /// it needs a real file on disk. Tests that want an in-memory store
    /// should call ``makeDatabaseQueue(at:)`` instead and pass the resulting
    /// `DatabaseQueue` (which also conforms to `DatabaseWriter`) to the
    /// store init.
    public static func makeDatabasePool(at url: URL) throws -> DatabasePool {
        let config = makeConfiguration()
        let pool = try DatabasePool(path: url.path, configuration: config)
        try Migrations.migrator.migrate(pool)
        return pool
    }

    /// Shared GRDB `Configuration` used by both Queue and Pool constructors.
    /// `prepareDatabase` runs once per connection — for a Pool this fires on
    /// the single writer connection and on every reader connection the pool
    /// opens lazily, so foreign-key enforcement is consistent across all
    /// connections.
    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }
}
