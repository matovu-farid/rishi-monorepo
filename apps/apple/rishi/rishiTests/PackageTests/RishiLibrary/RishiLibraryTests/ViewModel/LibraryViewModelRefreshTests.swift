@testable import rishi
import Testing
import Foundation




/// A PositionStore that sleeps for ``perReadDelay`` on every read, so a
/// serial caller pays ``perReadDelay × N`` while a concurrent caller pays
/// roughly ``perReadDelay`` total.
///
/// Used by `LibraryViewModelRefreshTests` to assert that
/// `LibraryViewModel.refresh()` fans out position reads via a TaskGroup.
private final class SlowPositionStore: PositionStore, @unchecked Sendable {
    let perReadDelay: Duration
    let positions: [BookID: Position]

    init(perReadDelay: Duration, positions: [BookID: Position] = [:]) {
        self.perReadDelay = perReadDelay
        self.positions = positions
    }

    func position(for bookId: BookID) async throws -> Position? {
        try await Task.sleep(for: perReadDelay)
        return positions[bookId]
    }

    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

private final class SlowCoverExtractor: CoverExtractor, @unchecked Sendable {
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func extractCover(from _: URL) async -> Data? {
        try? await Task.sleep(for: delay)
        return Data([0, 1, 2])
    }
}

private actor SuspendedBookStore: BookStore {
    private let store = InMemoryBookStore()
    private var suspendNextRead = false
    private var readStarted = false
    private var readStartedWaiter: CheckedContinuation<Void, Never>?
    private var readRelease: CheckedContinuation<Void, Never>?
    private var failNextRead = false
    private(set) var readCount = 0

    func suspendNext() { suspendNextRead = true }
    func failNext() { failNextRead = true }
    func releaseRead() { readRelease?.resume(); readRelease = nil }
    func waitForRead() async {
        if readStarted { return }
        await withCheckedContinuation { readStartedWaiter = $0 }
    }

    func books(for userId: UserID) async throws -> [Book] {
        readCount += 1
        if failNextRead {
            failNextRead = false
            throw TestReadFailure.failed
        }
        if suspendNextRead {
            suspendNextRead = false
            readStarted = true
            readStartedWaiter?.resume()
            readStartedWaiter = nil
            await withCheckedContinuation { readRelease = $0 }
            readStarted = false
        }
        return try await store.books(for: userId)
    }
    func book(_ id: BookID) async throws -> Book? { try await store.book(id) }
    func upsert(_ book: Book) async throws { try await store.upsert(book) }
    func delete(_ id: BookID) async throws { try await store.delete(id) }
    func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool {
        try await store.deleteIfUnchanged(id, matching: expected)
    }
}

private enum TestReadFailure: Error { case failed }

@MainActor
@Suite("LibraryViewModel.refresh — concurrent position fan-out (F-P0-03)")
struct LibraryViewModelRefreshTests {

    private static func makeVM(
        userId: UserID,
        bookStore: any BookStore,
        positionStore: any PositionStore,
        root: URL? = nil,
        coverExtractors: [String: any CoverExtractor] = [:],
        deleteBook: (@Sendable (Book) async throws -> Void)? = nil,
        accountIdentity: LibraryAccountIdentity? = nil,
        currentIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil }
    ) -> LibraryViewModel {
        let root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VMRefresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: coverExtractors
        )
        return LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            boundAccountIdentity: accountIdentity,
            currentAccountIdentity: currentIdentity,
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId }),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: deleteBook ?? { book in try await storage.delete(book) }
        )
    }

    @Test("outgoing view model rejects a refresh after its bound generation changes")
    func rejectsNewRefreshFromObsoleteViewModel() async {
        let userId = UUID()
        let store = InMemoryBookStore()
        let identity = LibraryAccountIdentity(userID: userId, generation: 4)
        var liveIdentity: LibraryAccountIdentity? = identity
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { liveIdentity }
        )
        liveIdentity = LibraryAccountIdentity(userID: UUID(), generation: 5)

        await vm.refresh()
        #expect(vm.loadReadiness == .idle)
        #expect(vm.books.isEmpty)
    }

    @Test("suspended snapshot cannot publish after account replacement")
    func suspendedSnapshotIsFencedAfterAccountReplacement() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        let book = Book(userId: userId, title: "Stale", formatType: .pdf, fileURL: "stale.pdf")
        try await store.upsert(book)
        await store.suspendNext()
        let identity = LibraryAccountIdentity(userID: userId, generation: 14)
        var liveIdentity: LibraryAccountIdentity? = identity
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { liveIdentity }
        )

        let suspendedRefresh = Task { await vm.refresh() }
        await store.waitForRead()
        liveIdentity = LibraryAccountIdentity(userID: UUID(), generation: 15)
        await store.releaseRead()
        await suspendedRefresh.value

        #expect(vm.books.isEmpty)
        #expect(vm.loadReadiness == .idle)
        await vm.refresh()
        #expect(await store.readCount == 1)
    }

    @Test("a recreated model for the same user and new generation loads successfully")
    func recreatedSameUserModelLoads() async throws {
        let userId = UUID()
        let book = Book(userId: userId, title: "Reauthenticated", formatType: .pdf, fileURL: "book.pdf")
        let store = InMemoryBookStore(initial: [book])
        let identity = LibraryAccountIdentity(userID: userId, generation: 8)
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { identity }
        )

        await vm.refresh()
        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.loadReadiness == .success(identity))
    }

    @Test("failed local load remains retryable and success replaces failure")
    func localLoadFailureCanRetry() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        await store.failNext()
        let vm = Self.makeVM(userId: userId, bookStore: store, positionStore: SlowPositionStore(perReadDelay: .zero))

        await vm.refresh()
        #expect(vm.loadReadiness == .failure(nil))
        let book = Book(userId: userId, title: "Retry", formatType: .pdf, fileURL: "retry.pdf")
        try await store.upsert(book)
        await vm.refresh()
        #expect(vm.books.map(\.id) == [book.id])
    }

    @Test("mutation arriving during a load causes one trailing current snapshot")
    func mutationDuringLoadRunsTrailingRead() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        await store.suspendNext()
        let vm = Self.makeVM(userId: userId, bookStore: store, positionStore: SlowPositionStore(perReadDelay: .zero))
        let initial = Task { await vm.refresh() }
        await store.waitForRead()
        let added = Book(userId: userId, title: "During load", formatType: .pdf, fileURL: "during.pdf")
        try await store.upsert(added)
        let invalidation = Task { await vm.refresh() }
        await store.releaseRead()

        await initial.value
        await invalidation.value
        #expect(vm.books.map(\.id) == [added.id])
        #expect(await store.readCount == 2)
    }

    @Test("successful deletion during a snapshot queues a trailing snapshot")
    func deletionDuringLoadRunsTrailingRead() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        let book = Book(userId: userId, title: "Delete during load", formatType: .pdf, fileURL: "delete.pdf")
        try await store.upsert(book)
        await store.suspendNext()
        let deletionFinished = AsyncSignal()
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            deleteBook: { book in
                try await store.delete(book.id)
                await deletionFinished.signal()
            }
        )

        let initial = Task { await vm.refresh() }
        await store.waitForRead()
        let deletion = Task { await vm.delete(book) }
        await deletionFinished.wait()
        await store.releaseRead()
        await initial.value
        await deletion.value

        #expect(vm.books.isEmpty)
        #expect(vm.loadReadiness == .success(nil))
        #expect(await store.readCount == 2)
    }

    @Test("local first snapshot loads without consent and does not start sync")
    func consentDenialStillLoadsLocalSnapshot() async throws {
        let userId = UUID()
        let book = Book(userId: userId, title: "Local", formatType: .pdf, fileURL: "local.pdf")
        let store = InMemoryBookStore(initial: [book])
        let identity = LibraryAccountIdentity(userID: userId, generation: 11)
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { identity }
        )
        var syncStarted = false

        let result = await vm.loadInitialSnapshotAndSyncIfNeeded(
            accountIdentity: identity,
            consentGranted: false,
            autoSync: true,
            sync: { syncStarted = true }
        )

        #expect(result == .success)
        #expect(vm.books.map(\.id) == [book.id])
        #expect(!syncStarted)
    }

    @Test("consent changing during a shared initial read reuses the load and starts one sync")
    func consentFlipReusesInFlightLoad() async {
        let userId = UUID()
        let store = SuspendedBookStore()
        await store.suspendNext()
        let identity = LibraryAccountIdentity(userID: userId, generation: 12)
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .milliseconds(0)),
            accountIdentity: identity,
            currentIdentity: { identity }
        )
        var syncCount = 0
        var readCountBeforeSync: Int?
        let deniedLoad = Task {
            await vm.loadInitialSnapshotAndSyncIfNeeded(
                accountIdentity: identity,
                consentGranted: false,
                autoSync: true,
                sync: { syncCount += 1 }
            )
        }
        await store.waitForRead()
        deniedLoad.cancel()
        let grantedLoad = Task {
            await vm.loadInitialSnapshotAndSyncIfNeeded(
                accountIdentity: identity,
                consentGranted: true,
                autoSync: true,
                sync: {
                    syncCount += 1
                    readCountBeforeSync = await store.readCount
                }
            )
        }
        await store.releaseRead()

        #expect(await grantedLoad.value == .success)
        #expect(await deniedLoad.value == .cancelled)
        #expect(syncCount == 1)
        #expect(readCountBeforeSync == 1)
        #expect(await store.readCount == 2)
    }

    @Test("refresh fans out positionStore reads concurrently rather than serially")
    func test_refresh_fansOutPositionReadsConcurrently() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<10 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        // 100 ms per read × 10 books = 1000 ms serial. Parallel target: < 300 ms.
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(100), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await vm.refresh() }

        // Serial would take >= 1000 ms; with parallel fan-out we expect < 300 ms
        // even under heavy CI load. (Single 100ms sleep + scheduling overhead.)
        #expect(elapsed < .milliseconds(300),
                "refresh() took \(elapsed) — expected < 300ms via concurrent fan-out (serial would be ~1000ms)")
        #expect(vm.books.count == 10)
    }

    @Test("refresh overlaps position and cold cover resolution")
    func test_refreshOverlapsPositionAndCoverWork() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        let root = URL.temporaryDirectory
            .appendingPathComponent("VMRefresh-overlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let relativeFile = "Books/overlap/book.pdf"
        let sourceURL = root.appendingPathComponent(relativeFile)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([7]).write(to: sourceURL)

        let book = Book(
            userId: userId,
            title: "Overlap",
            formatType: .pdf,
            fileURL: relativeFile
        )
        try await bookStore.upsert(book)
        let position = Position(bookId: book.id, locator: "loc", percentComplete: 0.5)
        let positionStore = SlowPositionStore(
            perReadDelay: .milliseconds(200),
            positions: [book.id: position]
        )
        let vm = Self.makeVM(
            userId: userId,
            bookStore: bookStore,
            positionStore: positionStore,
            root: root,
            coverExtractors: [
                "pdf": SlowCoverExtractor(delay: .milliseconds(200))
            ]
        )

        let elapsed = await ContinuousClock().measure {
            await vm.refresh()
        }

        #expect(elapsed < .milliseconds(360), "refresh took (elapsed); position and cover work should overlap")
        #expect(vm.position(for: book.id)?.bookId == book.id)
        #expect(vm.coverURLs[book.id] != nil)
    }

    @Test("refresh preserves correct (bookId → position) mapping after fan-out")
    func test_refresh_preservesPositionMap() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<5 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
            // Distinct percent values so we can detect mis-keyed pairings.
            let pct = Double(i + 1) * 0.1
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: pct)
        }
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(5), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        await vm.refresh()

        for b in books {
            let mapped = vm.position(for: b.id)
            #expect(mapped != nil, "missing position for book \(b.title)")
            #expect(mapped?.bookId == b.id, "position landed under wrong bookId for \(b.title)")
            #expect(mapped?.percentComplete == positions[b.id]?.percentComplete)
        }
        // All 5 books are in-progress (0.1–0.5), but the shelf caps at 3.
        #expect(vm.readingNow.count == 3)
    }

    @Test("refresh handles partial nil results — only books with saved positions land in readingNow")
    func test_refresh_handlesPartialNilResults() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<6 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
        }
        // Only even-indexed books have positions; odd-indexed books return nil.
        for i in stride(from: 0, to: 6, by: 2) {
            let b = books[i]
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(5), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        await vm.refresh()

        #expect(vm.books.count == 6)
        // Three even-indexed books have positions; three odd-indexed books do not.
        #expect(vm.positionsByBookId.count == 3)
        for i in 0..<6 {
            let mapped = vm.position(for: books[i].id)
            if i % 2 == 0 {
                #expect(mapped != nil, "expected position for book index \(i)")
            } else {
                #expect(mapped == nil, "expected NO position for book index \(i)")
            }
        }
        #expect(vm.readingNow.count == 3)
    }

    @Test("completed sync refreshes the mounted library and reveals newly synced books")
    func refreshesAfterSyncStatusTransitionsToIdle() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(1))
        let vm = Self.makeVM(
            userId: userId,
            bookStore: bookStore,
            positionStore: positionStore
        )
        let status = SyncStatus(isRunning: true)
        let refreshes = RefreshEventRecorder()
        let observer = LibrarySyncCompletionRefreshObserver(
            refresh: {
                await vm.refresh()
                await refreshes.record()
            }
        )

        await observer.statusChanged(from: nil, to: status.snapshot())

        let syncedBook = Book(
            userId: userId,
            title: "Synced after completion",
            formatType: .pdf,
            fileURL: "synced.pdf"
        )
        try await bookStore.upsert(syncedBook)

        status.apply(SyncStatusSnapshot(
            lastSyncedAt: Date(),
            pendingCount: 0,
            isRunning: false,
            lastError: nil
        ))
        await observer.statusChanged(from: true, to: status.snapshot())

        #expect(await refreshes.count == 1)
        #expect(vm.books.map(\.id) == [syncedBook.id])
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor RefreshEventRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
