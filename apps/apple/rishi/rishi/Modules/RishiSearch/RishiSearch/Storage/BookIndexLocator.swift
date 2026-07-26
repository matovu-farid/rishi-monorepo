import Foundation

/// Resolves the on-disk per-book index layout under a shared root.
///
/// Locked decision (CONTEXT.md): every book stores its index artifacts under
/// `<rootURL>/Books/<bookId>/`:
///
///   - `vectors.hnsw`     — USearch native binary index (memory-mapped at search time)
///   - `chunks.db`        — SwiftData store holding `(chunk_id, page, text)` rows
///   - `index.status.json` — cold-start status sidecar consumed by `BookSearch.status`
///
/// This struct is a pure value/utility — it does not touch the filesystem
/// except via the explicit `ensureBookDir(_:)` helper. Callers are responsible
/// for creating directories before writing files.
public struct BookIndexLocator: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// `<rootURL>/Books/<bookId>/` — uppercased UUID (Foundation's default
    /// `UUID.uuidString` form). The Books/ prefix matches CONTEXT.md.
    public func bookDir(_ bookId: UUID) -> URL {
        rootURL
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    public func vectorsURL(_ bookId: UUID) -> URL {
        bookDir(bookId).appendingPathComponent("vectors.hnsw")
    }

    public func chunksDBURL(_ bookId: UUID) -> URL {
        bookDir(bookId).appendingPathComponent("chunks.db")
    }

    public func statusURL(_ bookId: UUID) -> URL {
        bookDir(bookId).appendingPathComponent("index.status.json")
    }

    /// Create `<rootURL>/Books/<bookId>/` (and intermediate directories) if
    /// it doesn't already exist. Idempotent.
    public func ensureBookDir(_ bookId: UUID) throws {
        try FileManager.default.createDirectory(
            at: bookDir(bookId),
            withIntermediateDirectories: true
        )
    }
}
