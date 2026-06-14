import Foundation

/// Snapshot of the on-device index state for a single book.
///
/// Callers (notably the BookContextResponder) use this to distinguish
/// cold-start "the index isn't there yet" from real lookup failures.
/// A `.notIndexed` or in-progress `.indexing(...)` status is the
/// expected pre-state during book import; only `.ready` permits a real
/// search; `.failed(reason:)` surfaces an indexing crash for diagnostics.
public enum BookSearchStatus: Sendable, Equatable {
    /// No index exists on disk for this book id.
    case notIndexed

    /// Index build is in progress. `chunksDone` / `chunksTotal` lets the
    /// UI render a progress hint without coupling to the indexer's internals.
    case indexing(chunksDone: Int, chunksTotal: Int)

    /// Index is on disk and ready for queries.
    case ready

    /// Indexing terminated abnormally. `reason` is a short human-readable
    /// summary suitable for logging or surfacing to a debug screen.
    case failed(reason: String)
}
