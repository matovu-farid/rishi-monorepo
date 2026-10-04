import Foundation


/// Protocol seam that lets `BookFileStorage.importBook` schedule background
/// RAG index construction without depending on `RishiSearch`.
///
/// Phase 25 Plan 25-11 owns the protocol; the production conformer lives in
/// `RishiSearch` (`RishiSearchIndexingHook`) and is wired by `AppDependencies`.
/// Tests use `NoopBookIndexingHook` (or a recording fake) so the import path
/// has zero observable dependency on the indexer.
///
/// Contract:
///   - `scheduleIndexing(for:fileURL:)` MUST return quickly (synchronously
///     enqueueing a `Task.detached` and returning). It MUST NOT throw —
///     failures surface via the per-book `index.status.json` sidecar
///     written by `IndexBuilder` (Plan 25-05).
///   - Re-running for the same `book.id` is idempotent (the builder wipes
///     and rewrites).
public protocol BookIndexingHook: Sendable {
    /// Fire-and-forget: chunk + embed + persist the book's RAG index.
    /// Never throws — failures surface via the index.status.json sidecar.
    /// Caller (BookFileStorage) does NOT await meaningful work; the hook
    /// returns quickly after scheduling a detached Task.
    func scheduleIndexing(for book: Book, fileURL: URL) async
}

/// Reader callers that must keep a source lease alive through extraction and
/// persistence use this refinement. Unlike `scheduleIndexing`, this method
/// returns only after the per-book indexing task has completed. Concurrent
/// callers for the same book join the same task.
public protocol AwaitableBookIndexingHook: BookIndexingHook {
    func scheduleIndexingAndWait(for book: Book, fileURL: URL) async
}

/// No-op default conformer for production call sites (or tests) that do not
/// want RAG indexing to fire — e.g. legacy test fixtures, or the synthetic
/// `SampleBookInstaller` path where indexing is handled separately.
public struct NoopBookIndexingHook: AwaitableBookIndexingHook {
    public init() {}
    public func scheduleIndexing(for _: Book, fileURL _: URL) async {}
    public func scheduleIndexingAndWait(for _: Book, fileURL _: URL) async {}
}
