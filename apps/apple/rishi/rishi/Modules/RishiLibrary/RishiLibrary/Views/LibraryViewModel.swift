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

    /// An exact, owner-scoped deletion attempt. Only this view model creates it.
    public struct BookDeletionOperation: Sendable {
        fileprivate let id: UUID
        fileprivate let book: Book
        fileprivate let owner: UserID
        fileprivate let accountIdentity: LibraryAccountIdentity?
        fileprivate let ownerEpoch: UInt64
    }

    private enum CanonicalDeletionObservation {
        case unread
        case absent
        case present(Book)
    }

    private struct PendingDeletion {
        let operation: BookDeletionOperation
        let position: Position?
        let coverURL: URL?
        let previouslyPersistedTombstone: Bool
        var completionStarted = false
        var canonical: CanonicalDeletionObservation = .unread
    }

    private struct FailedDeletionPresentation {
        let book: Book
        let position: Position?
        let coverURL: URL?
        let retainWhenCanonicallyAbsent: Bool
    }

    private enum HydrationResult: Sendable {
        case positions([BookID: Position])
        case coversFinished
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
    private let beforeBookDeleted: @Sendable (Book) async throws -> BookDeletionRetirementWitness?
    /// Confirms that no tombstone was committed and restores the current live
    /// managed source admission after a failed retirement. False keeps the
    /// book fenced and retryable.
    private let restoreBookAfterFailedRetirement: @Sendable (Book, BookDeletionRetirementWitness?) async -> BookDeletionRollbackResult
    private let onBookDeleted: (@Sendable (BookID) async throws -> Void)?
    public enum DeletionCommitOutcome: Sendable {
        case committed(deferredCleanup: @Sendable () async -> Void)
        case savedNeedsReconciliation(reconcile: @Sendable () async -> Bool, deferredCleanup: @Sendable () async -> Void)
    }
    private let logicalBookDeletion: (@Sendable (Book, BookDeletionRetirementWitness?) async throws -> DeletionCommitOutcome)?
    private let isBookTombstoned: (@Sendable (BookID) async throws -> Bool)?

    private var searchTask: Task<Void, Never>? = nil
    private var hydrationTask: Task<Void, Never>? = nil
    private var publicationRevision: UInt64 = 0
    private var bookSnapshotRevision: UInt64 = 0
    private var publishedOwnerId: UserID?
    private var publishedAccountIdentity: LibraryAccountIdentity?
    private var ownerEpoch: UInt64 = 0
    private var pendingDeletions: [BookID: PendingDeletion] = [:]
    private var failedDeletionPresentations: [BookID: FailedDeletionPresentation] = [:]
    private var pendingManagedBookIDs: Set<BookID> = []
    private var pendingCoverBookIDs: Set<BookID> = []
    private var coverResultsPublishedForSnapshot: Set<BookID> = []
    private var coverPublicationWaiters: [BookID: [CheckedContinuation<Void, Never>]] = [:]
    private var gridVisibleBookIDs: Set<BookID> = []
    private var readingNowVisibleBookIDs: Set<BookID> = []
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
        beforeBookDeleted: @escaping @Sendable (Book) async throws -> BookDeletionRetirementWitness? = { _ in nil },
        restoreBookAfterFailedRetirement: @escaping @Sendable (Book, BookDeletionRetirementWitness?) async -> BookDeletionRollbackResult = { _, _ in .refused },
        onBookDeleted: (@Sendable (BookID) async throws -> Void)? = nil,
        logicalBookDeletion: (@Sendable (Book, BookDeletionRetirementWitness?) async throws -> DeletionCommitOutcome)? = nil,
        isBookTombstoned: (@Sendable (BookID) async throws -> Bool)? = nil,
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
        self.logicalBookDeletion = logicalBookDeletion
        self.isBookTombstoned = isBookTombstoned
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
        let retiring = outcomes.filter { $0.failureReason == .deletionInProgress }.count
        if succeeded == 0 {
            Log.event(
                "library.import.picked.no_books",
                level: .error,
                data: [
                    "count": String(outcomes.count),
                    "errors": outcomes.compactMap(\.error).joined(separator: " | ")
                ]
            )
            if retiring == failed && retiring > 0 {
                importError = ImportFailure(message: "This book is still being deleted. Try importing it again when deletion finishes.")
            } else if retiring > 0 {
                importError = ImportFailure(message: "Some books are still being deleted. Try importing those again when deletion finishes. Other selected files could not be imported.")
            } else {
                importError = ImportFailure(message: "Couldn't import the selected file. Please choose a valid EPUB or PDF.")
            }
        } else if failed > 0 {
            importError = ImportFailure(
                title: "Some Files Could Not Be Imported",
                message: retiring > 0 ? "Imported \(succeeded) of \(outcomes.count) selected files. Some books are still being deleted; try importing those again when deletion finishes." : "Imported \(succeeded) of \(outcomes.count) selected files. Try importing the remaining files again."
            )
        }
        return outcomes
    }

    /// Reloads books for the current user and re-derives readingNow + filteredBooks.
    /// Silent on errors (logged via RishiLogging) — the UI shows empty state.
    @discardableResult
    public func refresh() async -> LoadResult {
        await refresh(reason: .mutation)
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
            adoptOwner(nil)
            return .cancelled
        }
        guard boundIdentityIsCurrent, boundAccountIdentity?.userID == nil || boundAccountIdentity?.userID == userId else { return .cancelled }
        adoptOwner(userId)
        do {
            let candidates = try await bookStore.books(for: userId)
            var loaded: [Book] = []
            for book in candidates {
                if let isBookTombstoned, try await isBookTombstoned(book.id) { continue }
                guard isCurrent(revision: revision, owner: userId) else { return .cancelled }
                loaded.append(book)
            }
            guard isCurrent(revision: revision, owner: userId) else { return .cancelled }
            let loadedIDs = Set(loaded.map(\.id))
            retiredImportTokens.formUnion(importEventTokens.values.filter { !loadedIDs.contains($0.bookID) })
            // Readiness and attempt retirement use canonical rows, even when
            // a pending deletion temporarily hides one from every surface.
            pendingManagedBookIDs.formIntersection(loadedIDs)
            pendingCoverBookIDs.formIntersection(loadedIDs)
            importEventTokens = importEventTokens.filter { loadedIDs.contains($0.key) }
            let canonicalByID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            for id in Array(pendingDeletions.keys) {
                pendingDeletions[id]?.canonical = canonicalByID[id].map(CanonicalDeletionObservation.present) ?? .absent
            }
            var visible = loaded
            for (id, fallback) in failedDeletionPresentations {
                if let canonical = canonicalByID[id] {
                    if canonical != fallback.book {
                        failedDeletionPresentations[id] = nil
                        positionsByBookId[id] = nil
                        coverURLs[id] = nil
                    }
                } else if fallback.retainWhenCanonicallyAbsent {
                    visible.append(fallback.book)
                } else {
                    failedDeletionPresentations[id] = nil
                }
            }
            visible.removeAll { pendingDeletions[$0.id] != nil }
            visible.sort { $0.addedAt > $1.addedAt }
            let visibleIDs = Set(visible.map(\.id))
            self.books = visible
            self.positionsByBookId = positionsByBookId.filter { visibleIDs.contains($0.key) }
            self.coverURLs = coverURLs.filter { visibleIDs.contains($0.key) }
            gridVisibleBookIDs.formIntersection(visibleIDs)
            readingNowVisibleBookIDs.formIntersection(visibleIDs)
            updateLibraryProjections()
            startHydration(books: visible, owner: userId, revision: revision)
            return .success
        } catch {
            guard isCurrent(revision: revision, owner: userId) else { return .cancelled }
            Log.error("library.refresh.failed", error: error)
            return .failure
        }
    }

    private func adoptOwner(_ owner: UserID?) {
        let identity = owner == nil ? nil : (boundAccountIdentity ?? currentAccountIdentity())
        guard publishedOwnerId != owner || publishedAccountIdentity != identity else { return }
        ownerEpoch &+= 1
        publishedOwnerId = owner
        publishedAccountIdentity = identity
        books = []
        readingNow = []
        filteredBooks = []
        positionsByBookId = [:]
        coverURLs = [:]
        pendingManagedBookIDs = []
        pendingCoverBookIDs = []
        coverResultsPublishedForSnapshot = []
        resumeCoverPublicationWaiters()
        gridVisibleBookIDs = []
        readingNowVisibleBookIDs = []
        importEventTokens = [:]
        retiredImportTokens = []
        locallyDeletedBookIDs = []
        pendingDeletions = [:]
        failedDeletionPresentations = [:]
        deletionError = nil
    }

    private func updateLibraryProjections() {
        readingNow = Self.deriveReadingNow(books: books, positions: positionsByBookId)
        filteredBooks = LibrarySearchFilter.filter(books: books, query: searchText)
    }

    private func invalidateDeletionPublication() {
        cancelSearchDebounce()
        publicationRevision &+= 1
        bookSnapshotRevision &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        if snapshotLoadTask != nil { mutationInvalidationPending = true }
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
        guard accountIdentity == boundAccountIdentity else { return .cancelled }
        let initialResult = await refresh(reason: .appearance)
        guard !Task.isCancelled, boundIdentityIsCurrent else { return .cancelled }
        guard initialResult == .success else { return initialResult }
        if consentGranted && autoSync {
            await sync()
            guard boundIdentityIsCurrent else { return .cancelled }
            let result = await refresh(reason: .mutation)
            return Task.isCancelled ? .cancelled : result
        }
        return .success
    }

    /// Consumes attempt-scoped registration/readiness events while the library
    /// view is alive. The producer is optional so durable-import clients keep
    /// their existing behavior until the service graph opts in.
    public func observeImportEvents() async {
        guard let bookImportEvents else { return }
        let stream = await bookImportEvents.stream()
        // Completion hints are not replayed. Register first so imports that
        // finish during this snapshot read remain buffered, then recover any
        // artwork persisted while the library observer was absent.
        guard !Task.isCancelled else { return }
        await refresh()
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
            if snapshotLoadTask != nil {
                mutationInvalidationPending = true
            }
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

    func waitForCoverResolution(_ bookID: BookID) async {
        if coverResultsPublishedForSnapshot.contains(bookID) { return }
        await withCheckedContinuation { continuation in
            if coverResultsPublishedForSnapshot.contains(bookID) {
                continuation.resume()
            } else {
                coverPublicationWaiters[bookID, default: []].append(continuation)
            }
        }
    }

    private func markCoverResolutionPublished(_ bookID: BookID) {
        coverResultsPublishedForSnapshot.insert(bookID)
        coverPublicationWaiters.removeValue(forKey: bookID)?.forEach { $0.resume() }
    }

    private func resumeCoverPublicationWaiters() {
        let waiters = coverPublicationWaiters.values.flatMap { $0 }
        coverPublicationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForImportEventRefresh() async {
        await importRefreshTask?.value
    }

    /// Called by each visible book surface. Separate sets make repeated and
    /// cross-surface reports idempotent while preserving priority until the
    /// book leaves every surface.
    public func setGridBookVisible(_ bookID: BookID, visible: Bool) {
        updateVisibility(bookID, visible: visible, in: &gridVisibleBookIDs)
    }

    public func setReadingNowBookVisible(_ bookID: BookID, visible: Bool) {
        updateVisibility(bookID, visible: visible, in: &readingNowVisibleBookIDs)
    }

    var prioritizedCoverBookIDs: Set<BookID> {
        gridVisibleBookIDs.union(readingNowVisibleBookIDs)
    }

    private func updateVisibility(_ bookID: BookID, visible: Bool, in surface: inout Set<BookID>) {
        if visible { surface.insert(bookID) } else { surface.remove(bookID) }
    }

    /// Hides the confirmed book synchronously; source retirement stays separate.
    public func beginDeletion(_ book: Book) -> BookDeletionOperation? {
        guard boundIdentityIsCurrent, let owner = currentUserId(),
              book.userId == owner,
              boundAccountIdentity?.userID == nil || boundAccountIdentity?.userID == owner else { return nil }
        adoptOwner(owner)
        guard pendingDeletions[book.id] == nil else { return nil }
        let failedPresentation = failedDeletionPresentations.removeValue(forKey: book.id)
        let previousFailure = failedPresentation?.book == book ? failedPresentation : nil
        let operation = BookDeletionOperation(
            id: UUID(), book: book, owner: owner,
            accountIdentity: boundAccountIdentity ?? currentAccountIdentity(), ownerEpoch: ownerEpoch
        )
        pendingDeletions[book.id] = PendingDeletion(
            operation: operation,
            position: positionsByBookId[book.id] ?? previousFailure?.position,
            coverURL: coverURLs[book.id] ?? previousFailure?.coverURL,
            previouslyPersistedTombstone: previousFailure?.retainWhenCanonicallyAbsent == true
        )
        deletionError = nil
        locallyDeletedBookIDs.insert(book.id)
        invalidateDeletionPublication()
        books.removeAll { $0.id == book.id }
        positionsByBookId[book.id] = nil
        coverURLs[book.id] = nil
        gridVisibleBookIDs.remove(book.id)
        readingNowVisibleBookIDs.remove(book.id)
        updateLibraryProjections()
        return operation
    }

    private func ownsDeletion(_ operation: BookDeletionOperation) -> Bool {
        guard pendingDeletions[operation.book.id]?.operation.id == operation.id,
              ownerEpoch == operation.ownerEpoch, publishedOwnerId == operation.owner,
              currentUserId() == operation.owner, boundIdentityIsCurrent else { return false }
        return (boundAccountIdentity ?? currentAccountIdentity()) == operation.accountIdentity
    }

    /// Recheck synchronous ownership after the generation lookup suspends.
    private func admitsDeletionStage(_ operation: BookDeletionOperation) async -> Bool {
        guard ownsDeletion(operation) else { return false }
        if let identity = operation.accountIdentity {
            guard await currentAccountGeneration() == identity.generation else { return false }
        }
        return ownsDeletion(operation)
    }

    public func completeDeletion(
        _ operation: BookDeletionOperation,
        closePresentedReader: (@MainActor (Book) async -> Void)? = nil
    ) async {
        guard await admitsDeletionStage(operation),
              pendingDeletions[operation.book.id]?.completionStarted == false else { return }
        pendingDeletions[operation.book.id]?.completionStarted = true
        let book = operation.book
        var tombstonePersisted = pendingDeletions[book.id]?.previouslyPersistedTombstone == true
        var retirementWitness: BookDeletionRetirementWitness?
        var committedOutcome: DeletionCommitOutcome?
        defer {
            if let committedOutcome {
                // Capture only immutable values and service-owned actions.
                // Reader teardown and physical lifetime never delay persistence.
                Task { @MainActor in
                    let cleanup: @Sendable () async -> Void
                    switch committedOutcome {
                    case .committed(let action): cleanup = action
                    case .savedNeedsReconciliation(let reconcile, let action):
                        guard await reconcile() else { return }
                        cleanup = action
                    }
                    await closePresentedReader?(book)
                    await cleanup()
                }
            }
        }
        do {
            // Each await can replace the account. Already-entered retirement
            // finishes normally, but no obsolete attempt enters the next stage.
            if logicalBookDeletion == nil { await closePresentedReader?(book) }
            guard await admitsDeletionStage(operation) else { return }
            retirementWitness = try await beforeBookDeleted(book)
            guard await admitsDeletionStage(operation) else { return }
            if let logicalBookDeletion {
                committedOutcome = try await logicalBookDeletion(book, retirementWitness)
                tombstonePersisted = true
            } else {
                try await onBookDeleted?(book.id)
                tombstonePersisted = true
                guard await admitsDeletionStage(operation) else { return }
                try await deleteBook(book)
            }
            guard await admitsDeletionStage(operation) else { return }
            invalidateDeletionPublication()
            pendingDeletions[book.id] = nil
            failedDeletionPresentations[book.id] = nil
            if let token = importEventTokens.removeValue(forKey: book.id) {
                retiredImportTokens.insert(token)
            }
            pendingManagedBookIDs.remove(book.id)
            pendingCoverBookIDs.remove(book.id)
            books.removeAll { $0.id == book.id }
            positionsByBookId[book.id] = nil
            coverURLs[book.id] = nil
            updateLibraryProjections()
            await refresh(reason: .mutation)
        } catch {
            guard await admitsDeletionStage(operation) else { return }
            var rollback: BookDeletionRollbackResult = .refused
            if !tombstonePersisted {
                rollback = await restoreBookAfterFailedRetirement(book, retirementWitness)
                guard await admitsDeletionStage(operation) else { return }
            }
            guard let pending = pendingDeletions[book.id] else { return }
            invalidateDeletionPublication()
            pendingDeletions[book.id] = nil
            if rollback.didRestoreBook { locallyDeletedBookIDs.remove(book.id) }
            restoreDeletionPresentation(pending, tombstonePersisted: tombstonePersisted, didRollback: rollback.didRestoreBook)
            if tombstonePersisted {
                deletionError = "Deletion was saved, but local cleanup failed. The book is fenced for retry."
            } else if rollback.didRestoreBook {
                deletionError = "Couldn't save this deletion. The book remains in your library; try again."
            } else if case .conflict = rollback {
                deletionError = "This book could not be restored because another file occupies its managed location. Keep the book in the library and resolve the file conflict before trying again."
            } else {
                deletionError = "Couldn't safely restore this book after the deletion failed. It remains fenced; retry recovery after checking your account and storage."
            }
            Log.error("library.delete.failed", error: error)
            updateLibraryProjections()
            startHydrationForCurrentBooks()
        }
    }

    private func restoreDeletionPresentation(
        _ pending: PendingDeletion, tombstonePersisted: Bool, didRollback: Bool
    ) {
        let original = pending.operation.book
        let restored: Book
        let useOriginalCaches: Bool
        switch pending.canonical {
        case .present(let canonical):
            restored = canonical
            useOriginalCaches = canonical == original
        case .absent:
            guard tombstonePersisted || didRollback else { return }
            restored = original
            useOriginalCaches = true
        case .unread:
            restored = original
            useOriginalCaches = true
        }
        // Do not overwrite another book imported while this attempt drained.
        if let current = books.first(where: { $0.id == original.id }), current != original {
            return
        }
        books.removeAll { $0.id == original.id }
        books.append(restored)
        books.sort { $0.addedAt > $1.addedAt }
        if useOriginalCaches {
            positionsByBookId[original.id] = pending.position
            coverURLs[original.id] = pending.coverURL
            failedDeletionPresentations[original.id] = FailedDeletionPresentation(
                book: restored, position: pending.position, coverURL: pending.coverURL,
                retainWhenCanonicallyAbsent: tombstonePersisted
            )
        }
    }

    /// Compatibility entry point for callers that do not split confirmation.
    public func delete(
        _ book: Book,
        closePresentedReader: (@MainActor (Book) async -> Void)? = nil
    ) async {
        guard let operation = beginDeletion(book) else { return }
        await completeDeletion(operation, closePresentedReader: closePresentedReader)
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
        coverResultsPublishedForSnapshot.subtract(snapshot.map(\.id))
        // An image can be committed while its completion hint is missed.
        // Admit persisted artwork through the resolver's independent artwork
        // policy without asserting that managed book bytes are ready.
        let recoverableArtworkIDs = Set(snapshot.compactMap { book in
            book.userId == owner && book.coverPath != nil ? book.id : nil
        })
        let pendingIDs = pendingManagedBookIDs.union(pendingCoverBookIDs)
            .subtracting(recoverableArtworkIDs)
        hydrationTask = Task { @MainActor [weak self, positionLoader = self.positionLoader, coverResolver = self.coverResolver] in
            let snapshotIDs = Set(snapshot.map(\.id))
            await withTaskGroup(of: HydrationResult.self) { group in
                group.addTask {
                    .positions(await positionLoader.positions(for: snapshot))
                }
                group.addTask {
                    await coverResolver.resolveCoverURLs(
                        for: snapshot,
                        excluding: pendingIDs,
                        prioritizedBookIDs: { [weak self] in
                            guard let self else { return [] }
                            return self.prioritizedCoverBookIDs
                        },
                        onResolved: { [weak self] bookID, url in
                            guard let self, !Task.isCancelled,
                                  snapshotIDs.contains(bookID),
                                  self.isCurrent(revision: revision, owner: owner),
                                  recoverableArtworkIDs.contains(bookID)
                                    || (!self.pendingManagedBookIDs.contains(bookID)
                                        && !self.pendingCoverBookIDs.contains(bookID)),
                                  !self.locallyDeletedBookIDs.contains(bookID) else { return }
                            // Subscript assignment removes the key for nil,
                            // explicitly resolving only this book while
                            // retaining untouched/imported covers.
                            self.coverURLs[bookID] = url ?? self.failedDeletionPresentations[bookID]?.coverURL
                            self.markCoverResolutionPublished(bookID)
                            self.importInstrumentation.recordLatest(
                                .coverHydrationCompleted,
                                bookID: bookID,
                                cacheState: url == nil ? .miss : .hit
                            )
                        }
                    )
                    return .coversFinished
                }
                for await result in group {
                    guard let self, !Task.isCancelled,
                          self.isCurrent(revision: revision, owner: owner) else { continue }
                    switch result {
                    case .positions(let positions):
                        var next = self.positionsByBookId.filter {
                            !snapshotIDs.contains($0.key) || self.failedDeletionPresentations[$0.key] != nil
                        }
                        for (bookID, position) in positions where snapshotIDs.contains(bookID) {
                            next[bookID] = position
                        }
                        self.positionsByBookId = next
                        self.readingNow = Self.deriveReadingNow(books: self.books, positions: next)
                    case .coversFinished: break
                    }
                }
            }
        }
    }

    private func isCurrent(revision: UInt64, owner: UserID) -> Bool {
        bookSnapshotRevision == revision && currentUserId() == owner && boundIdentityIsCurrent
            && publishedAccountIdentity == (boundAccountIdentity ?? currentAccountIdentity())
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
