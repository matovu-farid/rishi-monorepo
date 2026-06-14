import Foundation
import Observation
import RishiCore
import RishiLogging

/// `@Observable` view model that powers `LibraryRootView` + `LibraryView`.
///
/// Owns the materialised library state for the current signed-in user:
///   - `books` (full list)
///   - `readingNow` (derived: positions strictly between 0 and 1)
///   - `filteredBooks` (search results)
///
/// Search is debounced 150 ms via Task cancellation per LIB-09. Empty query
/// resets `filteredBooks` synchronously (no debounce wait) so the user does
/// not see a brief flash of "no results".
@MainActor
@Observable
public final class LibraryViewModel {

    public private(set) var books: [Book] = []
    public private(set) var readingNow: [ReadingNowEntry] = []
    public private(set) var filteredBooks: [Book] = []
    public private(set) var positionsByBookId: [BookID: Position] = [:]

    /// Phase 21 Plan 21-01 — cover URL map populated by `refresh()` BEFORE
    /// it returns. The grid binds directly to this map so the first paint
    /// after `vm.refresh()` sees real cover URLs instead of a gradient
    /// placeholder.
    ///
    /// Resolution order per book (inside `refresh()`'s `withTaskGroup`):
    ///   1. `BookFileStorage.cachedCoverURLIfFresh` — nonisolated HEIC-cache
    ///      fast path, returns instantly when the downsampled HEIC + mtime
    ///      sidecar are present and fresh.
    ///   2. `BookFileStorage.cachedCoverURL(for:)` — slow path that lazily
    ///      reads the on-disk `cover.png` (written by `importBook`),
    ///      downsamples it into the HEIC cache, and returns the cache URL.
    ///      This is the path that makes newly-imported books render covers
    ///      on the very next paint instead of staying stuck on the gradient
    ///      placeholder — see `LibraryViewModelImportCoverRegressionTests`.
    ///
    /// Books that have no `cover.png` on disk (extractor returned nil during
    /// import) end up absent from this map and render the gradient fallback.
    public private(set) var coverURLs: [BookID: URL] = [:]

    public var searchText: String = "" {
        didSet { scheduleSearchDebounce(oldValue: oldValue) }
    }

    /// 150 ms by default per LIB-09. Test-only override to shrink the wait
    /// inside debounce-coalescing tests.
    public var debounceDuration: Duration = .milliseconds(150)

    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let storage: BookFileStorage
    private let currentUserId: @MainActor () -> UserID?

    private var searchTask: Task<Void, Never>? = nil

    public init(bookStore: any BookStore,
                positionStore: any PositionStore,
                storage: BookFileStorage,
                currentUserId: @escaping @MainActor () -> UserID?) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.storage = storage
        self.currentUserId = currentUserId
    }

    /// Reloads books for the current user and re-derives readingNow + filteredBooks.
    /// Silent on errors (logged via RishiLogging) — the UI shows empty state.
    public func refresh() async {
        guard let userId = currentUserId() else {
            books = []
            readingNow = []
            filteredBooks = []
            positionsByBookId = [:]
            coverURLs = [:]
            return
        }
        do {
            let loaded = try await bookStore.books(for: userId)
            // F-P0-03: fan out positionStore reads concurrently via withTaskGroup
            // instead of awaiting each one serially. PositionStore is Sendable +
            // nonisolated, so each spawned task runs off the MainActor; the only
            // hop back is for the final state assignment. Per locked decision #2
            // the PositionStore protocol stays unchanged — fan-out lives in the
            // view-model. Swift book reference: "Calling Asynchronous Functions
            // in Parallel".
            let positionsByBook: [BookID: Position] = await withTaskGroup(
                of: (BookID, Position?).self
            ) { group in
                for book in loaded {
                    group.addTask { [positionStore = self.positionStore] in
                        let p = try? await positionStore.position(for: book.id)
                        return (book.id, p)
                    }
                }
                var out: [BookID: Position] = [:]
                for await (id, position) in group {
                    if let position { out[id] = position }
                }
                return out
            }
            // Phase 21 Plan 21-01 — fan out cover-URL resolution INSIDE
            // refresh() so the grid's first paint (which binds to
            // `coverURLs`) sees real URLs and skips the gradient placeholder
            // flash. Each child task tries the nonisolated HEIC-cache fast
            // path first (`cachedCoverURLIfFresh`) so cache-warm books pay
            // only a stat syscall on the cooperative executor. On MISS we
            // fall through to the actor-isolated `cachedCoverURL(for:)`
            // slow path which lazily warms the HEIC cache from the on-disk
            // `cover.png` that `importBook` wrote. This second hop is what
            // makes newly-imported books render their cover on the very
            // next paint instead of staying stuck on the gradient — locked
            // by `LibraryViewModelImportCoverRegressionTests`. Subsequent
            // refreshes hit the warm cache and skip the slow-path entirely.
            let resolvedCovers: [BookID: URL] = await withTaskGroup(
                of: (BookID, URL?).self
            ) { group in
                for book in loaded {
                    group.addTask { [storage = self.storage] in
                        if let warm = storage.cachedCoverURLIfFresh(for: book) {
                            return (book.id, warm)
                        }
                        let cold = await storage.cachedCoverURL(for: book)
                        return (book.id, cold)
                    }
                }
                var out: [BookID: URL] = [:]
                for await (id, url) in group {
                    if let url { out[id] = url }
                }
                return out
            }
            self.books = loaded
            self.positionsByBookId = positionsByBook
            self.coverURLs = resolvedCovers
            self.readingNow = Self.deriveReadingNow(books: loaded, positions: positionsByBook)
            self.filteredBooks = LibrarySearchFilter.filter(books: loaded, query: searchText)
        } catch {
            Log.error("library.refresh.failed", error: error)
        }
    }

    /// Deletes the book on-disk + in the store; updates local state in place.
    public func delete(_ book: Book) async {
        do {
            try await storage.delete(book)
            books.removeAll { $0.id == book.id }
            positionsByBookId[book.id] = nil
            coverURLs[book.id] = nil
            readingNow = Self.deriveReadingNow(books: books, positions: positionsByBookId)
            filteredBooks = LibrarySearchFilter.filter(books: books, query: searchText)
        } catch {
            Log.error("library.delete.failed", error: error)
        }
    }

    public func position(for bookId: BookID) -> Position? {
        positionsByBookId[bookId]
    }

    public func coverURL(for book: Book) async -> URL? {
        // Phase 21 perf — nonisolated cache-hit fast path. The library
        // renders N tiles in parallel via `LibraryRootView.computeCoverURLs`
        // (`withTaskGroup`); previously every tile (including cache HITs)
        // had to queue behind the BookFileStorage actor's single executor
        // and then again behind the CoverCache actor's executor, defeating
        // the parallel fan-out. The fast path reads HEIC + mtime sidecar
        // off-actor via FileManager.default, so warm-cache paints fan out
        // truly concurrently. Cache MISS / stale still falls through to
        // the slow path which owns the write side under actor isolation.
        if let hit = storage.cachedCoverURLIfFresh(for: book) {
            return hit
        }
        return await storage.cachedCoverURL(for: book)
    }

    // MARK: - Search debounce

    private func scheduleSearchDebounce(oldValue: String) {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty resets immediately — no debounce.
            filteredBooks = books
            return
        }
        let snapshotBooks = books
        let snapshotQuery = searchText
        let delay = debounceDuration
        // KEEP: viewModel is @MainActor and writes filteredBooks (@Observable
        // state). LibrarySearchFilter.filter is a pure value function on a
        // snapshot, fast enough to stay on main for v1. If the corpus grows
        // and Time Profiler shows >1ms here, hoist to Task.detached and write
        // back via MainActor.run.
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            filteredBooks = LibrarySearchFilter.filter(books: snapshotBooks, query: snapshotQuery)
        }
    }

    static func deriveReadingNow(books: [Book], positions: [BookID: Position]) -> [ReadingNowEntry] {
        books.compactMap { book in
            guard let pos = positions[book.id], ReadingNowEntry.isInProgress(pos) else { return nil }
            return ReadingNowEntry(book: book, position: pos)
        }.sorted { $0.position.updatedAt > $1.position.updatedAt }
    }
}
