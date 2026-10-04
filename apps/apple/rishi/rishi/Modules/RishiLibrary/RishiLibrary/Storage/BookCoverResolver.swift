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

    private let storage: BookFileStorage?
    private let resolveOverride: (@Sendable (Book) async -> URL?)?
    private let managedReadiness: (@Sendable (Book) async -> Bool)?

    public init(storage: BookFileStorage, isManagedReady: (@Sendable (Book) async -> Bool)? = nil) {
        self.storage = storage
        self.resolveOverride = nil
        self.managedReadiness = isManagedReady
    }

    /// Allows callers with a separate cover source to provide the same
    /// asynchronous resolution contract. Production storage composition uses
    /// `init(storage:)`; the closure is also useful for deterministic
    /// publication tests.
    init(
        resolve: @escaping @Sendable (Book) async -> URL?,
        isManagedReady: (@Sendable (Book) async -> Bool)? = nil
    ) {
        self.storage = nil
        self.resolveOverride = resolve
        self.managedReadiness = isManagedReady
    }

    /// Resolves a single book's cover URL using the fast-then-slow rule.
    /// This is the one place the fast/slow decision is made.
    public func coverURL(for book: Book) async -> URL? {
        if let managedReadiness, !(await managedReadiness(book)) { return nil }
        if let resolveOverride {
            return await resolveOverride(book)
        }
        guard let storage else { return nil }
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
    public func coverURLs(for books: [Book], excluding excludedBookIDs: Set<BookID> = []) async -> [BookID: URL] {
        await withTaskGroup(of: (BookID, URL?).self) { group in
            for book in books {
                guard !excludedBookIDs.contains(book.id) else { continue }
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
