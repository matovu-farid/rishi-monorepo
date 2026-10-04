import Foundation
import Observation

public struct LibraryAccountIdentity: Hashable, Sendable {
    public let userID: UserID
    public let generation: UInt64

    public init(userID: UserID, generation: UInt64) {
        self.userID = userID
        self.generation = generation
    }
}



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

    public enum LoadReadiness: Equatable, Sendable {
        case idle
        case loading(LibraryAccountIdentity?)
        case success(LibraryAccountIdentity?)
        case failure(LibraryAccountIdentity?)
    }

    enum RefreshReason: Equatable { case appearance, mutation }
    public enum LoadResult: Equatable, Sendable { case success, failure, cancelled }

    private enum HydrationResult: Sendable {
        case positions([BookID: Position])
        case covers([BookID: URL])
    }

    public private(set) var books: [Book] = []
    public private(set) var readingNow: [ReadingNowEntry] = []
    public private(set) var filteredBooks: [Book] = []
    public private(set) var positionsByBookId: [BookID: Position] = [:]

    /// Cover URLs hydrate after the base book list is published. A missing
    /// entry uses the grid's ordinary fallback until resolution completes.
    public private(set) var coverURLs: [BookID: URL] = [:]
    public private(set) var loadReadiness: LoadReadiness = .idle

    public var searchText: String = "" {
        didSet { scheduleSearchDebounce(oldValue: oldValue) }
    }

    /// User-visible import failure. An `.alert` in `LibraryRootView` binds to
    /// this so a batch that imported nothing is never silent (Mac Catalyst
    /// picker-delegate-drop regression).
    public struct ImportFailure: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let message: String
        public init(title: String = "Import Failed", message: String) {
            self.title = title
            self.message = message
        }
    }

    public var importError: ImportFailure? = nil
    /// Failure to persist a deletion is visible to the library shell. The
    /// row and material remain available when source admission is restored.
    public private(set) var deletionError: String?
    /// Optional library-shell hook for one-time ready-only enrichments such as
    /// share prewarm. Registration itself never schedules managed consumers.
    public var onManagedBookReady: (@MainActor (BookID) -> Void)?

    /// 150 ms by default per LIB-09. Test-only override to shrink the wait
    /// inside debounce-coalescing tests.
    public var debounceDuration: Duration = .milliseconds(150)

    private let bookStore: any BookStore
    private let currentUserId: @MainActor () -> UserID?
    private let boundAccountIdentity: LibraryAccountIdentity?
    private let currentAccountIdentity: @MainActor () -> LibraryAccountIdentity?
    private let importCoordinator: ImportCoordinator
    private let positionLoader: PositionLoader
    private let coverResolver: BookCoverResolver
    private let bookImportEvents: BookImportEvents?
    private let currentAccountGeneration: @Sendable () async -> UInt64?
    private let validatesRegistrationEvent: (@Sendable (BookImportEvent) async -> Bool)?
    private let importInstrumentation: BookImportInstrumentation
    private let deleteBook: @Sendable (Book) async throws -> Void
    /// Fences and drains work that may still read or materialize this book.
    /// Production wiring also closes any presented reader before returning.
    private let beforeBookDeleted: @Sendable (Book) async throws -> Void
    /// Confirms that no tombstone was committed and restores the current live
    /// managed source admission after a failed retirement. False keeps the
    /// book fenced and retryable.
    private let restoreBookAfterFailedRetirement: @Sendable (Book, BookMaterializationToken?) async -> Bool
    private let onBookDeleted: (@Sendable (BookID) async throws -> Void)?

    private var searchTask: Task<Void, Never>? = nil
    private var hydrationTask: Task<Void, Never>? = nil
    private var publicationRevision: UInt64 = 0
    private var bookSnapshotRevision: UInt64 = 0
    private var publishedOwnerId: UserID?
    private var pendingManagedBookIDs: Set<BookID> = []
    private var pendingCoverBookIDs: Set<BookID> = []
    private var importEventTokens: [BookID: BookMaterializationToken] = [:]
    private var retiredImportTokens: Set<BookMaterializationToken> = []
    /// A deletion is an immediate publication fence. It also covers events
    /// already queued before the view model learned their attempt token.
    private var locallyDeletedBookIDs: Set<BookID> = []
    private var importRefreshTask: Task<Void, Never>?
    private var snapshotLoadTask: Task<LoadResult, Never>?
    private var snapshotLoadID: UUID?
    private var mutationInvalidationPending = false

    /// Composed initializer for production callers that already own the
    /// library helpers. The view model does not need to know the concrete file
    /// storage used to implement deletion.
    public init(
        bookStore: any BookStore,
        currentUserId: @escaping @MainActor () -> UserID?,
        boundAccountIdentity: LibraryAccountIdentity? = nil,
        currentAccountIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil },
        importCoordinator: ImportCoordinator,
        positionLoader: PositionLoader,
        coverResolver: BookCoverResolver,
        deleteBook: @escaping @Sendable (Book) async throws -> Void,
        beforeBookDeleted: @escaping @Sendable (Book) async throws -> Void = { _ in },
        restoreBookAfterFailedRetirement: @escaping @Sendable (Book, BookMaterializationToken?) async -> Bool = { _, _ in false },
        onBookDeleted: (@Sendable (BookID) async throws -> Void)? = nil,
        bookImportEvents: BookImportEvents? = nil,
        currentAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        validatesRegistrationEvent: (@Sendable (BookImportEvent) async -> Bool)? = nil,
        importInstrumentation: BookImportInstrumentation = .shared
    ) {
        self.bookStore = bookStore
        self.currentUserId = currentUserId
        self.boundAccountIdentity = boundAccountIdentity
        self.currentAccountIdentity = currentAccountIdentity
        self.importCoordinator = importCoordinator
        self.positionLoader = positionLoader
        self.coverResolver = coverResolver
        self.bookImportEvents = bookImportEvents
        self.currentAccountGeneration = currentAccountGeneration
        self.validatesRegistrationEvent = validatesRegistrationEvent
        self.importInstrumentation = importInstrumentation
        self.deleteBook = deleteBook
        self.beforeBookDeleted = beforeBookDeleted
        self.restoreBookAfterFailedRetirement = restoreBookAfterFailedRetirement
        self.onBookDeleted = onBookDeleted
    }

    /// Compatibility initializer for callers that still provide raw storage.
    /// New production construction should use the composed helper initializer.
    public convenience init(bookStore: any BookStore,
                positionStore: any PositionStore,
                storage: BookFileStorage,
                currentUserId: @escaping @MainActor () -> UserID?,
                importCoordinator: ImportCoordinator) {
        self.init(
            bookStore: bookStore,
            currentUserId: currentUserId,
            importCoordinator: importCoordinator,
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: { book in try await storage.delete(book) }
        )
    }

    /// Compatibility initializer for external consumers that provide custom
    /// helper implementations. New production code should use the primary
    /// initializer and let the view model derive these helpers.
    @available(*, deprecated, message: "Use the initializer without helper overrides for production construction.")
    public convenience init(bookStore: any BookStore,
                positionStore: any PositionStore,
                storage: BookFileStorage,
                currentUserId: @escaping @MainActor () -> UserID?,
                importCoordinator: ImportCoordinator,
                positionLoader: PositionLoader? = nil,
                coverResolver: BookCoverResolver? = nil) {
        self.init(
            bookStore: bookStore,
            currentUserId: currentUserId,
            importCoordinator: importCoordinator,
            positionLoader: positionLoader ?? PositionLoader(positionStore: positionStore),
            coverResolver: coverResolver ?? BookCoverResolver(storage: storage),
            deleteBook: { book in try await storage.delete(book) }
        )
    }

    /// Imports picker-vended URLs through `ImportCoordinator` (security-scoped
    /// resource dance + sync `onBookImported` hook), refreshes the library, and
    /// surfaces a user-visible error when nothing imported so the failure is
    /// never silent. Routed off the view so it is unit-testable.
    @discardableResult
    public func importPicked(
        _ urls: [URL],
        onSingleRegistration: (@MainActor @Sendable (ImportCoordinator.ImportOutcome) -> Void)? = nil
    ) async -> [ImportCoordinator.ImportOutcome] {
        importError = nil
        Log.event(
            "library.import.picked.received",
            data: ["count": String(urls.count)]
        )
        guard !urls.isEmpty else {
            Log.event("library.import.picked.empty", level: .warning)
            return []
        }
        let supportedURLs = ImportCoordinator.filterSupported(urls)
        let isSingleSelection = supportedURLs.count == 1
        let outcomes = await importCoordinator.registerSourceReadableBooks(urls, providerKind: .fileImporter) { registration in
            guard isSingleSelection, let onSingleRegistration else { return }
            let outcome = ImportCoordinator.ImportOutcome(
                url: supportedURLs[0],
                book: registration.book,
                error: nil
            )
            await MainActor.run { onSingleRegistration(outcome) }
        }
        await refresh()
        let succeeded = outcomes.compactMap(\.book).count
        let failed = outcomes.filter { $0.error != nil }.count
        if succeeded == 0 {
            Log.event(
                "library.import.picked.no_books",
                level: .error,
                data: [
                    "count": String(outcomes.count),
                    "errors": outcomes.compactMap(\.error).joined(separator: " | ")
                ]
            )
            importError = ImportFailure(message: "Couldn't import the selected file. Please choose a valid EPUB or PDF.")
        } else if failed > 0 {
            importError = ImportFailure(
                title: "Some Files Could Not Be Imported",
                message: "Imported \(succeeded) of \(outcomes.count) selected files. Try importing the remaining files again."
            )
        }
        return outcomes
    }

    /// Reloads books for the current user and re-derives readingNow + filteredBooks.
    /// Silent on errors (logged via RishiLogging) — the UI shows empty state.
    public func refresh() async {
        _ = await refresh(reason: .mutation)
    }

    func refresh(reason: RefreshReason) async -> LoadResult {
        guard boundIdentityIsCurrent else { return .cancelled }
        if reason == .appearance, loadReadiness == .success(boundAccountIdentity) { return .success }
        if let snapshotLoadTask {
            if reason == .mutation { mutationInvalidationPending = true }
            return await snapshotLoadTask.value
        }
        let identity = boundAccountIdentity
        let loadID = UUID()
        snapshotLoadID = loadID
        loadReadiness = .loading(identity)
        let task = Task { @MainActor [weak self] in
            guard let self else { return LoadResult.cancelled }
            var result = await self.readCurrentSnapshot()
            while self.mutationInvalidationPending && self.boundIdentityIsCurrent {
                self.mutationInvalidationPending = false
                result = await self.readCurrentSnapshot()
            }
            if self.snapshotLoadID == loadID {
                self.snapshotLoadTask = nil
                self.snapshotLoadID = nil
                self.loadReadiness = result == .success ? .success(identity) : (result == .failure ? .failure(identity) : .idle)
            }
            return result
        }
        snapshotLoadTask = task
        return await task.value
    }

    private func readCurrentSnapshot() async -> LoadResult {
        cancelSearchDebounce()
        publicationRevision &+= 1
        bookSnapshotRevision &+= 1
        let revision = bookSnapshotRevision
        hydrationTask?.cancel()
        hydrationTask = nil
        guard let userId = currentUserId() else {
            publishedOwnerId = nil
            books = []
            readingNow = []
            filteredBooks = []
            positionsByBookId = [:]
            coverURLs = [:]
            pendingManagedBookIDs = []
            pendingCoverBookIDs = []
            importEventTokens = [:]
            retiredImportTokens = []
            locallyDeletedBookIDs = []
            return .cancelled
        }
        guard boundIdentityIsCurrent, boundAccountIdentity?.userID == nil || boundAccountIdentity?.userID == userId else { return .cancelled }
        if publishedOwnerId != userId {
            // BookIDs can collide across owners. Never retain the previous
            // account's reading or cover state while the new base list loads.
            publishedOwnerId = userId
            books = []
            readingNow = []
            filteredBooks = []
            positionsByBookId = [:]
            coverURLs = [:]
            pendingManagedBookIDs = []
            pendingCoverBookIDs = []
            importEventTokens = [:]
            retiredImportTokens = []
            locallyDeletedBookIDs = []
        }
        do {
            let loaded = try await bookStore.books(for: userId)
            guard isCurrent(revision: revision, owner: userId) else { return .cancelled }
            let loadedIDs = Set(loaded.map(\.id))
            retiredImportTokens.formUnion(importEventTokens.values.filter { !loadedIDs.contains($0.bookID) })
            self.books = loaded
            self.positionsByBookId = positionsByBookId.filter { loadedIDs.contains($0.key) }
            self.coverURLs = coverURLs.filter { loadedIDs.contains($0.key) }
            pendingManagedBookIDs.formIntersection(loadedIDs)
            pendingCoverBookIDs.formIntersection(loadedIDs)
            importEventTokens = importEventTokens.filter { loadedIDs.contains($0.key) }
            self.readingNow = Self.deriveReadingNow(books: loaded, positions: positionsByBookId)
            self.filteredBooks = LibrarySearchFilter.filter(books: loaded, query: searchText)
            startHydration(books: loaded, owner: userId, revision: revision)
            return .success
        } catch {
            Log.error("library.refresh.failed", error: error)
            return boundIdentityIsCurrent ? .failure : .cancelled
        }
    }

    private var boundIdentityIsCurrent: Bool {
        guard let boundAccountIdentity else { return true }
        return currentUserId() == boundAccountIdentity.userID
            && currentAccountIdentity() == boundAccountIdentity
    }

    public func loadInitialSnapshotAndSyncIfNeeded(
        accountIdentity: LibraryAccountIdentity,
        consentGranted: Bool,
        autoSync: Bool,
        sync: () async -> Void
    ) async -> LoadResult {
        guard accountIdentity == boundAccountIdentity,
              await refresh(reason: .appearance) == .success,
              !Task.isCancelled,
              boundIdentityIsCurrent else { return .cancelled }
        if consentGranted && autoSync {
            await sync()
            guard !Task.isCancelled, boundIdentityIsCurrent else { return .cancelled }
            return await refresh(reason: .mutation)
        }
        return .success
    }

    /// Consumes attempt-scoped registration/readiness events while the library
    /// view is alive. The producer is optional so durable-import clients keep
    /// their existing behavior until the service graph opts in.
    public func observeImportEvents() async {
        guard let bookImportEvents else { return }
        let stream = await bookImportEvents.stream()
        for await event in stream {
            guard !Task.isCancelled else { return }
            await applyImportEvent(event)
        }
    }

    func applyImportEvent(_ event: BookImportEvent) async {
        guard boundIdentityIsCurrent,
              let owner = currentUserId(), owner == event.ownerID,
              await currentAccountGeneration() == event.accountGeneration,
              event.token.ownerID == owner,
              event.token.accountGeneration == event.accountGeneration else { return }

        let bookID = event.token.bookID
        switch event.kind {
        case .registered(let book):
            guard book.id == bookID, book.userId == owner,
                  !locallyDeletedBookIDs.contains(bookID),
                  !retiredImportTokens.contains(event.token) else { return }
            // Remote tombstones and other inbound changes do not pass through
            // `delete(_:)`. Re-read the canonical row before accepting a
            // queued registration, then optionally verify the persisted job
            // token/tombstone through the service-graph validator.
            guard let canonicalBeforeValidation = try? await bookStore.book(bookID),
                  canonicalBeforeValidation.userId == owner,
                  canonicalBeforeValidation.fileURL == book.fileURL,
                  currentUserId() == owner,
                  await currentAccountGeneration() == event.accountGeneration,
                  !locallyDeletedBookIDs.contains(bookID) else { return }
            if let validatesRegistrationEvent,
               !(await validatesRegistrationEvent(event)) { return }
            guard currentUserId() == owner,
                  await currentAccountGeneration() == event.accountGeneration,
                  !locallyDeletedBookIDs.contains(bookID),
                  let canonicalBook = try? await bookStore.book(bookID),
                  canonicalBook.userId == owner,
                  canonicalBook.fileURL == book.fileURL,
                  currentUserId() == owner,
                  await currentAccountGeneration() == event.accountGeneration,
                  !locallyDeletedBookIDs.contains(bookID) else { return }
            // This row was already durably registered before its event was
            // emitted. Invalidate reads/hydration that began before that CAS
            // so an older empty snapshot cannot erase it or retire its token.
            publicationRevision &+= 1
            bookSnapshotRevision &+= 1
            cancelSearchDebounce()
            hydrationTask?.cancel()
            hydrationTask = nil
            importEventTokens[bookID] = event.token
            pendingManagedBookIDs.insert(bookID)
            pendingCoverBookIDs.insert(bookID)
            var updated = books.filter { $0.id != bookID }
            updated.append(canonicalBook)
            books = updated.sorted { $0.addedAt > $1.addedAt }
            filteredBooks = LibrarySearchFilter.filter(books: books, query: searchText)
            importInstrumentation.record(.baseLibraryPublished, attemptID: event.token.attemptID)
            // Position hydration remains optional and cannot delay the
            // canonical Book's appearance in the library.
            startHydration(books: books, owner: owner, revision: bookSnapshotRevision)
        case .managedReady(let id):
            guard id == bookID, importEventTokens[bookID] == event.token,
                  !locallyDeletedBookIDs.contains(id),
                  books.contains(where: { $0.id == id }) else { return }
            pendingManagedBookIDs.remove(id)
            pendingCoverBookIDs.insert(id)
            onManagedBookReady?(id)
            scheduleCoalescedImportRefresh()
        case .coverReady(let id), .coverFailed(let id):
            guard id == bookID, importEventTokens[bookID] == event.token,
                  !locallyDeletedBookIDs.contains(id),
                  books.contains(where: { $0.id == id }) else { return }
            pendingCoverBookIDs.remove(id)
            scheduleCoalescedImportRefresh()
        case .failed(let id, let retryableCode):
            guard id == bookID, importEventTokens[bookID] == event.token,
                  !locallyDeletedBookIDs.contains(id) else { return }
            Log.event("library.import.materialization.failed", level: .warning, data: ["retryable_code": retryableCode])
        }
    }

    private func scheduleCoalescedImportRefresh() {
        importRefreshTask?.cancel()
        importRefreshTask = Task { @MainActor [weak self] in
            // A short quiet window merges ready/cover callbacks from the same
            // completion wave into one canonical snapshot read.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Waits for the current optional hydration pass. Kept internal so
    /// package tests can synchronize on resolver completion without sleeps.
    func waitForHydration() async {
        await hydrationTask?.value
    }

    func waitForImportEventRefresh() async {
        await importRefreshTask?.value
    }

    /// Deletes the book on-disk + in the store; updates local state in place.
    public func delete(
        _ book: Book,
        closePresentedReader: (@MainActor (Book) async -> Void)? = nil
    ) async {
        deletionError = nil
        cancelSearchDebounce()
        publicationRevision &+= 1
        bookSnapshotRevision &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        locallyDeletedBookIDs.insert(book.id)
        var tombstonePersisted = false
        do {
            // The local publication fence above is synchronous. Close and
            // drain reader/copy work before writing a tombstone or removing
            // either managed bytes or the Book row.
            await closePresentedReader?(book)
            try await beforeBookDeleted(book)
            // Persist the tombstone first. If this fails, keep the local book
            // intact so a later retry cannot lose the deletion remotely.
            try await onBookDeleted?(book.id)
            tombstonePersisted = true
            try await deleteBook(book)
            if let token = importEventTokens.removeValue(forKey: book.id) {
                retiredImportTokens.insert(token)
            }
            pendingManagedBookIDs.remove(book.id)
            pendingCoverBookIDs.remove(book.id)
            books.removeAll { existing in existing.id == book.id }
            positionsByBookId[book.id] = nil
            coverURLs[book.id] = nil
            readingNow = Self.deriveReadingNow(books: books, positions: positionsByBookId)
            filteredBooks = LibrarySearchFilter.filter(books: books, query: searchText)
            await refresh(reason: .mutation)
        } catch {
            if !tombstonePersisted {
                if await restoreBookAfterFailedRetirement(book, importEventTokens[book.id]) {
                    locallyDeletedBookIDs.remove(book.id)
                }
                deletionError = "Couldn't save this deletion. The book remains in your library; try again."
            } else {
                // Keep the source fence after the durable tombstone. The row
                // remains visible for local cleanup retry but cannot start
                // new managed consumers.
                deletionError = "Deletion was saved, but local cleanup failed. The book is fenced for retry."
            }
            Log.error("library.delete.failed", error: error)
            startHydrationForCurrentBooks()
        }
    }

    public func clearDeletionError() {
        deletionError = nil
    }

    /// Arms a one-shot import trace immediately before the single-import
    /// auto-open callback, independent of async library-event publication.
    public func markImportReaderOpenRequested(bookID: BookID) {
        importInstrumentation.markReaderOpenRequested(bookID: bookID)
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
        publicationRevision &+= 1
        let revision = publicationRevision
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty resets immediately — no debounce.
            filteredBooks = books
            return
        }
        let snapshotQuery = searchText
        let delay = debounceDuration
        // KEEP: viewModel is @MainActor and writes filteredBooks (@Observable
        // state). LibrarySearchFilter.filter is a pure value function on a
        // snapshot, fast enough to stay on main for v1. If the corpus grows
        // and Time Profiler shows >1ms here, hoist to Task.detached and write
        // back via MainActor.run.
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if Task.isCancelled || publicationRevision != revision { return }
            filteredBooks = LibrarySearchFilter.filter(books: books, query: snapshotQuery)
        }
    }

    private func cancelSearchDebounce() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func startHydrationForCurrentBooks() {
        guard let owner = currentUserId(), !books.isEmpty else { return }
        startHydration(books: books, owner: owner, revision: bookSnapshotRevision)
    }

    private func startHydration(books snapshot: [Book], owner: UserID, revision: UInt64) {
        hydrationTask?.cancel()
        let pendingIDs = pendingManagedBookIDs.union(pendingCoverBookIDs)
        hydrationTask = Task { @MainActor [weak self, positionLoader = self.positionLoader, coverResolver = self.coverResolver] in
            let snapshotIDs = Set(snapshot.map(\.id))
            await withTaskGroup(of: HydrationResult.self) { group in
                group.addTask {
                    .positions(await positionLoader.positions(for: snapshot))
                }
                group.addTask {
                    .covers(await coverResolver.coverURLs(for: snapshot, excluding: pendingIDs))
                }
                for await result in group {
                    guard let self, !Task.isCancelled,
                          self.isCurrent(revision: revision, owner: owner) else { continue }
                    switch result {
                    case .positions(let positions):
                        var next = self.positionsByBookId.filter { !snapshotIDs.contains($0.key) }
                        for (bookID, position) in positions where snapshotIDs.contains(bookID) {
                            next[bookID] = position
                        }
                        self.positionsByBookId = next
                        self.readingNow = Self.deriveReadingNow(books: self.books, positions: next)
                    case .covers(let covers):
                        var next = self.coverURLs.filter { !snapshotIDs.contains($0.key) }
                        for (bookID, url) in covers where snapshotIDs.contains(bookID) {
                            next[bookID] = url
                        }
                        self.coverURLs = next
                        for book in snapshot where !pendingIDs.contains(book.id) {
                            self.importInstrumentation.recordLatest(
                                .coverHydrationCompleted,
                                bookID: book.id,
                                cacheState: covers[book.id] == nil ? .miss : .hit
                            )
                        }
                    }
                }
            }
        }
    }

    private func isCurrent(revision: UInt64, owner: UserID) -> Bool {
        bookSnapshotRevision == revision && currentUserId() == owner && boundIdentityIsCurrent
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
