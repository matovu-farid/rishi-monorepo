import Foundation
import GRDB

/// Public surface for the RishiDB package. Plans 02-03 (schema + migrations)
/// and 02-06 (GRDB-backed stores) extend this with concrete schema and
/// `BookStore`/`HighlightStore`/etc. implementations.
public enum RishiDB {

    /// Marker for the public RishiDB API version. Bump when the surface breaks.
    public static let apiVersion = "0.1.0-scaffold"

    /// Open (or create) a GRDB `DatabaseQueue` at the given file URL.
    ///
    /// The returned queue has NO migrations applied. Plan 02-03 adds a
    /// `migrate(_:)` companion that runs the `DatabaseMigrator`.
    ///
    /// Pass `URL(fileURLWithPath: ":memory:")` for an in-memory queue (tests).
    public static func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        // SQLite treats the literal string ":memory:" as the in-memory database
        // sentinel. `URL(fileURLWithPath: ":memory:").path` resolves to an
        // ABSOLUTE filesystem path (e.g. "/cwd/:memory:"), which would create a
        // real on-disk file named ":memory:". Detect the sentinel and forward
        // it untouched so callers get a true in-memory queue.
        if url.lastPathComponent == ":memory:" {
            return try DatabaseQueue()
        }
        return try DatabaseQueue(path: url.path)
    }
}
