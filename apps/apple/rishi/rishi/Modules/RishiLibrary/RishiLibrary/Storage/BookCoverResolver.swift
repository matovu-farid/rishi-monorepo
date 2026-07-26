import Foundation


/// Resolves cover-image URLs for library books, owning the HEIC-cache
/// fast/slow decision and the concurrent fan-out that the library grid
/// depends on.
///
/// Extracted from `LibraryViewModel.refresh()` / `LibraryViewModel.coverURL`
/// (Plan 34-11) so the view-model no longer performs storage orchestration.
/// The single fast-then-slow rule — previously duplicated in the VM's
/// `refresh()` task body AND its `coverURL(for:)` helper — now lives in
/// exactly one place (`coverURL(for:)` below); the fan-out reuses it.
///
/// Resolution order per book:
///   1. `BookFileStorage.cachedCoverURLIfFresh` — nonisolated HEIC-cache
///      fast path; returns instantly when the downsampled HEIC + mtime
///      sidecar are present and fresh, paying only a stat syscall on the
///      cooperative executor.
///   2. `BookFileStorage.cachedCoverURL(for:)` — slow path that lazily warms
///      the HEIC cache from the on-disk `cover.png` and returns the cache
///      URL. This is what makes newly-imported books render their cover on
///      the very next paint — locked by
///      `LibraryViewModelImportCoverRegressionTests`.
///
/// Books that have no `cover.png` on disk resolve to `nil` and are absent
/// from the returned map (the grid renders the gradient fallback).
public struct BookCoverResolver: Sendable {

    private let storage: BookFileStorage

    public init(storage: BookFileStorage) {
        self.storage = storage
    }

    /// Resolves a single book's cover URL using the fast-then-slow rule.
    /// This is the one place the fast/slow decision is made.
    public func coverURL(for book: Book) async -> URL? {
        if let warm = storage.cachedCoverURLIfFresh(for: book) {
            return warm
        }
        return await storage.cachedCoverURL(for: book)
    }

    /// Fans out `coverURL(for:)` across `books` concurrently and returns the
    /// `BookID -> URL` map. Books that resolve to `nil` are omitted.
    ///
    /// Each child task runs the fast-path stat off-actor on the cooperative
    /// executor, hopping into the `BookFileStorage` actor only on cache miss.
    public func coverURLs(for books: [Book]) async -> [BookID: URL] {
        await withTaskGroup(of: (BookID, URL?).self) { group in
            for book in books {
                group.addTask {
                    (book.id, await coverURL(for: book))
                }
            }
            var out: [BookID: URL] = [:]
            for await (id, url) in group {
                if let url { out[id] = url }
            }
            return out
        }
    }
}
