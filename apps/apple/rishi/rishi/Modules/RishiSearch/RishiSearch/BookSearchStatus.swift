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
    
    /// Indexing process was killed previously and did not complete
    case staleIndexing

    /// Index is on disk and ready for queries.
    case ready

    /// Indexing terminated abnormally. `reason` is a short human-readable
    /// summary suitable for logging or surfacing to a debug screen.
    case failed(reason: String)
}

// MARK: - UI-facing helpers

public extension BookSearchStatus {
    /// Whether a reader-open backfill should kick off an index build.
    ///
    /// True ONLY for `.notIndexed`: an in-flight `.indexing` build must not
    /// be restarted, a `.failed` build must not be retried on every open
    /// (avoids thrash), and `.ready` needs no work.
    var shouldBackfillIndex: Bool {
        switch self {
        case .notIndexed, .staleIndexing:
            return true
        default:
            return false
            
        }
   
    }

    /// Integer completion percent for an in-progress build, else nil.
    ///
    /// Returns 0 when `chunksTotal` is 0 (degenerate empty book) so the chip
    /// can still render "Indexing…". Integer division floors toward zero.
    var indexingProgressPercent: Int? {
        guard case let .indexing(done, total) = self else { return nil }
        return total > 0 ? done * 100 / total : 0
    }

    /// Low-salience chip text, or nil when the chip should be hidden.
    ///
    /// `.indexing` -> "Indexing NN%" (or "Indexing 0%" when total is 0);
    /// every other case returns nil so the chip disappears once the index
    /// is ready, never built, or failed.
    var indicatorText: String? {
        guard case let .indexing(_, total) = self else { return nil }
        if total > 0, let percent = indexingProgressPercent {
            return "Indexing \(percent)%"
        }
        return "Indexing 0%"
    }
}
