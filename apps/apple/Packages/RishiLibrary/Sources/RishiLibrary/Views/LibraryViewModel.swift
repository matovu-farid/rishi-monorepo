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

    /// User-visible import failure. An `.alert` in `LibraryRootView` binds to
    /// this so a batch that imported nothing is never silent (Mac Catalyst
    /// picker-delegate-drop regression).
    public struct ImportFailure: Identifiable, Sendable {
        public let id = UUID()
        public let message: String
        public init(message: String) { self.message = message }
    }

    public var importError: ImportFailure? = nil

    /// 150 ms by default per LIB-09. Test-only override to shrink the wait
    /// inside debounce-coalescing tests.
    public var debounceDuration: Duration = .milliseconds(150)

    private let bookStore: any BookStore
    private let storage: BookFileStorage
    private let currentUserId: @MainActor () -> UserID?
    private let importCoordinator: ImportCoordinator
    private let positionLoader: PositionLoader
    private let coverResolver: BookCoverResolver

    private var searchTask: Task<Void, Never>? = nil

    /// `positionLoader` / `coverResolver` are defaulted so existing call
    /// sites keep the stable five-argument init; production constructs them
    /// from the injected `positionStore` / `storage`. Tests may inject
    /// custom collaborators.
    public init(bookStore: any BookStore,
                positionStore: any PositionStore,
                storage: BookFileStorage,
                currentUserId: @escaping @MainActor () -> UserID?,
                importCoordinator: ImportCoordinator,
                positionLoader: PositionLoader? = nil,
                coverResolver: BookCoverResolver? = nil) {
        self.bookStore = bookStore
        self.storage = storage
        self.currentUserId = currentUserId
        self.importCoordinator = importCoordinator
        self.positionLoader = positionLoader ?? PositionLoader(positionStore: positionStore)
        self.coverResolver = coverResolver ?? BookCoverResolver(storage: storage)
    }

    /// Imports picker-vended URLs through `ImportCoordinator` (security-scoped
    /// resource dance + sync `onBookImported` hook), refreshes the library, and
    /// surfaces a user-visible error when nothing imported so the failure is
    /// never silent. Routed off the view so it is unit-testable.
    @discardableResult
    public func importPicked(_ urls: [URL]) async -> [ImportCoordinator.ImportOutcome] {
        importError = nil
        guard !urls.isEmpty else { return [] }
        let outcomes = await importCoordinator.importBooks(urls)
        await refresh()
        if outcomes.compactMap(\.book).isEmpty {
            importError = ImportFailure(message: "Couldn't import the selected file. Please choose a valid EPUB or PDF.")
        }
        return outcomes
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
            // Thin orchestration: the position fan-out and the cover
            // fast/slow resolution now live in dedicated services
            // (`PositionLoader`, `BookCoverResolver`). Both resolve BEFORE
            // assigning state so the grid's first paint sees real positions
            // AND real cover URLs in the same MainActor turn — no gradient
            // placeholder flash. Cover resolution warms the HEIC cache for
            // newly-imported books, locked by
            // `LibraryViewModelImportCoverRegressionTests`.
            let positionsByBook = await positionLoader.positions(for: loaded)
            let resolvedCovers = await coverResolver.coverURLs(for: loaded)
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
        // Delegates to `BookCoverResolver`, which owns the single fast/slow
        // cache decision (nonisolated HEIC fast path, then the actor-isolated
        // slow path on miss). Kept as a VM method for existing call sites.
        await coverResolver.coverURL(for: book)
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

    /// The Reading-Now shelf shows at most this many books — the most
    /// recently read ones.
    static let readingNowLimit = 3

    static func deriveReadingNow(books: [Book], positions: [BookID: Position]) -> [ReadingNowEntry] {
        let inProgress = books.compactMap { book -> ReadingNowEntry? in
            guard let position = positions[book.id], ReadingNowEntry.isInProgress(position) else { return nil }
            return ReadingNowEntry(book: book, position: position)
        }
        let mostRecentFirst = inProgress.sorted { left, right in
            left.position.updatedAt > right.position.updatedAt
        }
        return Array(mostRecentFirst.prefix(readingNowLimit))
    }
}
