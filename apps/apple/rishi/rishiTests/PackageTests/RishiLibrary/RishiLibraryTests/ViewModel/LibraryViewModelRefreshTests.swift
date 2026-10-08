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
    let concurrencyProbe: PositionReadConcurrencyProbe?
    let overlapBarrier: HydrationOverlapBarrier?

    init(
        perReadDelay: Duration,
        positions: [BookID: Position] = [:],
        concurrencyProbe: PositionReadConcurrencyProbe? = nil,
        overlapBarrier: HydrationOverlapBarrier? = nil
    ) {
        self.perReadDelay = perReadDelay
        self.positions = positions
        self.concurrencyProbe = concurrencyProbe
        self.overlapBarrier = overlapBarrier
    }

    func position(for bookId: BookID) async throws -> Position? {
        await overlapBarrier?.arriveAndWait(for: .positions)
        await concurrencyProbe?.beginRead()
        do {
            try await Task.sleep(for: perReadDelay)
        } catch {
            await concurrencyProbe?.endRead()
            throw error
        }
        await concurrencyProbe?.endRead()
        return positions[bookId]
    }

    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

private actor PositionReadConcurrencyProbe {
    private var activeReads = 0
    private(set) var maximumConcurrentReads = 0

    func beginRead() {
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
    }

    func endRead() {
        activeReads -= 1
    }
}

private actor HydrationOverlapBarrier {
    enum Branch: Hashable { case positions, covers }

    private var started: Set<Branch> = []
    private var released = false
    private var startedWaiters: [CheckedContinuation<Bool, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait(for branch: Branch) async {
        started.insert(branch)
        if started.count == 2 {
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume(returning: true) }
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForBothBranches() async -> Bool {
        if started.count == 2 { return true }
        if released { return false }
        return await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let allStarted = started.count == 2
        let pendingStarts = startedWaiters
        startedWaiters.removeAll()
        pendingStarts.forEach { $0.resume(returning: allStarted) }
        let pendingWork = releaseWaiters
        releaseWaiters.removeAll()
        pendingWork.forEach { $0.resume() }
    }
}

private final class SlowCoverExtractor: CoverExtractor, @unchecked Sendable {
    let delay: Duration
    let overlapBarrier: HydrationOverlapBarrier?

    init(delay: Duration, overlapBarrier: HydrationOverlapBarrier? = nil) {
        self.delay = delay
        self.overlapBarrier = overlapBarrier
    }

    func extractCover(from _: URL) async -> Data? {
        await overlapBarrier?.arriveAndWait(for: .covers)
        try? await Task.sleep(for: delay)
        return Data([0, 1, 2])
    }
}

private actor SuspendedBookStore: BookStore {
    private let store = InMemoryBookStore()
    private var suspendNextRead = false
    private var readStarted = false
    private var readReleased = false
    private var captureNextSnapshot = false
    private var failSuspendedRead = false
    private var failNextRead = false
    private(set) var readCount = 0

    func suspendNext(capturingSnapshot: Bool = false, failOnRelease: Bool = false) {
        suspendNextRead = true
        readReleased = false
        captureNextSnapshot = capturingSnapshot
        failSuspendedRead = failOnRelease
    }
    func failNext() { failNextRead = true }
    func releaseRead() { readReleased = true }
    @discardableResult
    func waitForRead() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !readStarted {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                Issue.record("snapshot read did not enter before the deadline")
                return false
            }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return true
    }

    func books(for userId: UserID) async throws -> [Book] {
        readCount += 1
        if failNextRead {
            failNextRead = false
            throw TestReadFailure.failed
        }
        if suspendNextRead {
            suspendNextRead = false
            let snapshot = captureNextSnapshot ? try await store.books(for: userId) : nil
            let failOnRelease = failSuspendedRead
            captureNextSnapshot = false
            failSuspendedRead = false
            readStarted = true
            defer { readStarted = false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !readReleased {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw TestReadFailure.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
            if failOnRelease { throw TestReadFailure.failed }
            if let snapshot { return snapshot }
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

private enum TestReadFailure: Error { case failed, timedOut }

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
        beforeDelete: @escaping @Sendable (Book) async throws -> BookDeletionRetirementWitness? = { _ in nil },
        onDelete: (@Sendable (BookID) async throws -> Void)? = nil,
        rollback: @escaping @Sendable (Book, BookDeletionRetirementWitness?) async -> BookDeletionRollbackResult = { _, _ in .existingReady },
        accountIdentity: LibraryAccountIdentity? = nil,
        currentIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil },
        bookImportEvents: BookImportEvents? = nil,
        currentAccountGeneration: @escaping @Sendable () async -> UInt64? = { nil }
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
            deleteBook: deleteBook ?? { book in try await storage.delete(book) },
            beforeBookDeleted: beforeDelete,
            restoreBookAfterFailedRetirement: rollback,
            onBookDeleted: onDelete,
            bookImportEvents: bookImportEvents,
            currentAccountGeneration: currentAccountGeneration
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

    @Test("accepted import registration during the initial read queues a trailing snapshot")
    func importRegistrationDuringInitialReadRunsTrailingSnapshot() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        let identity = LibraryAccountIdentity(userID: userId, generation: 17)
        await store.suspendNext()
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { identity },
            currentAccountGeneration: { identity.generation }
        )
        let initialLoad = Task {
            await vm.loadInitialSnapshotAndSyncIfNeeded(
                accountIdentity: identity,
                consentGranted: false,
                autoSync: true,
                sync: {}
            )
        }
        await store.waitForRead()

        let imported = Book(userId: userId, title: "Imported", formatType: .pdf, fileURL: "imported.pdf")
        try await store.upsert(imported)
        let token = BookMaterializationToken(
            ownerID: userId,
            accountGeneration: identity.generation,
            bookID: imported.id,
            attemptID: UUID()
        )
        await vm.applyImportEvent(BookImportEvent(
            ownerID: userId,
            accountGeneration: identity.generation,
            token: token,
            kind: .registered(imported)
        ))
        await store.releaseRead()

        #expect(await initialLoad.value == .success)
        #expect(vm.books.map(\.id) == [imported.id])
        #expect(vm.loadReadiness == .success(identity))
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

    @Test("stale pre-begin and pending reads cannot publish or fail after terminal deletion; trailing reads remain usable", arguments: [false, true], [false, true])
    func staleReadAfterDeletionTerminal(_ failRead: Bool, _ failDeletion: Bool) async throws {
        // Exercise both a read started before confirmation and one admitted while pending.
        for readDuringPending in [false, true] {
            let owner = UUID()
            let book = Book(userId: owner, title: "Delete", formatType: .pdf, fileURL: "delete.pdf")
            let other = Book(userId: owner, title: "Keep", formatType: .pdf, fileURL: "keep.pdf")
            let store = SuspendedBookStore()
            try await store.upsert(book)
            try await store.upsert(other)
            let terminalReached = RefreshCompletion()
            let deletionFinished = RefreshCompletion()
            let loadFinished = RefreshCompletion()
            let vm = Self.makeVM(
                userId: owner, bookStore: store,
                positionStore: SlowPositionStore(perReadDelay: .zero),
                deleteBook: { book in
                    try await store.delete(book.id)
                    await terminalReached.finish()
                },
                onDelete: { _ in if failDeletion { throw TestReadFailure.failed } },
                rollback: { _, _ in await terminalReached.finish(); return .existingReady }
            )
            await vm.refresh()
            var operation: LibraryViewModel.BookDeletionOperation?
            if readDuringPending { operation = try #require(vm.beginDeletion(book)) }
            await store.suspendNext(capturingSnapshot: true, failOnRelease: failRead)
            let refresh = Task { await vm.refresh(); await loadFinished.finish() }
            var deletion: Task<Void, Never>?
            do {
                try #require(await store.waitForRead())
                if !readDuringPending { operation = try #require(vm.beginDeletion(book)) }
                let admitted = try #require(operation)
                deletion = Task { await vm.completeDeletion(admitted); await deletionFinished.finish() }
                try await terminalReached.wait()
                // Success and rollback both reach their terminal UI before the held read resumes.
                try await waitForTerminalPresentation(vm, book: book, failure: failDeletion)
                let expectedError = vm.deletionError
                #expect(vm.books.contains { $0.id == book.id } == failDeletion)
                #expect(vm.books.contains { $0.id == other.id })
                await store.releaseRead()
                try await loadFinished.wait()
                try await deletionFinished.wait()
                #expect(vm.books.contains { $0.id == book.id } == failDeletion)
                #expect(vm.books.contains { $0.id == other.id })
                #expect(vm.deletionError == expectedError)
                #expect(vm.loadReadiness == .success(nil))
                #expect(await store.readCount == 3)
                let added = Book(userId: owner, title: "Trailing usable", formatType: .pdf, fileURL: "added.pdf")
                try await store.upsert(added)
                await vm.refresh()
                #expect(vm.books.contains { $0.id == added.id })
                #expect(await store.readCount == 4)
                #expect(vm.loadReadiness == .success(nil))
            } catch {
                await store.releaseRead()
                refresh.cancel()
                deletion?.cancel()
                throw error
            }
        }
    }

    private func waitForTerminalPresentation(_ vm: LibraryViewModel, book: Book, failure: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while failure ? vm.deletionError == nil : vm.books.contains(where: { $0.id == book.id }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestReadFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
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

    @Test("initial snapshot read failure propagates without starting sync")
    func initialSnapshotFailurePropagates() async {
        let userId = UUID()
        let store = SuspendedBookStore()
        await store.failNext()
        let identity = LibraryAccountIdentity(userID: userId, generation: 19)
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
            consentGranted: true,
            autoSync: true,
            sync: { syncStarted = true }
        )

        #expect(result == .failure)
        #expect(!syncStarted)
        #expect(await store.readCount == 1)
    }

    @Test("canceled initial sync waiter still refreshes the account snapshot")
    func canceledInitialSyncWaiterRefreshesSnapshot() async throws {
        let userId = UUID()
        let store = SuspendedBookStore()
        let identity = LibraryAccountIdentity(userID: userId, generation: 13)
        let vm = Self.makeVM(
            userId: userId,
            bookStore: store,
            positionStore: SlowPositionStore(perReadDelay: .zero),
            accountIdentity: identity,
            currentIdentity: { identity }
        )
        let syncStarted = AsyncSignal()
        let waveFinished = AsyncSignal()
        let load = Task {
            await vm.loadInitialSnapshotAndSyncIfNeeded(
                accountIdentity: identity,
                consentGranted: true,
                autoSync: true,
                sync: {
                    await syncStarted.signal()
                    await waveFinished.wait()
                }
            )
        }
        await syncStarted.wait()
        load.cancel()
        let syncedBook = Book(userId: userId, title: "Synced", formatType: .pdf, fileURL: "synced.pdf")
        try await store.upsert(syncedBook)
        await waveFinished.signal()

        #expect(await load.value == .cancelled)
        #expect(vm.books.map(\.id) == [syncedBook.id])
        #expect(await store.readCount == 2)
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
        let concurrencyProbe = PositionReadConcurrencyProbe()
        let positionStore = SlowPositionStore(
            perReadDelay: .milliseconds(100),
            positions: positions,
            concurrencyProbe: concurrencyProbe
        )
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.positionsByBookId.count == 10)
        #expect(await concurrencyProbe.maximumConcurrentReads > 1)
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

        let overlapBarrier = HydrationOverlapBarrier()
        let book = Book(
            userId: userId,
            title: "Overlap",
            formatType: .pdf,
            fileURL: relativeFile
        )
        try await bookStore.upsert(book)
        let positionStore = SlowPositionStore(
            perReadDelay: .zero,
            positions: [book.id: Position(bookId: book.id, locator: "loc", percentComplete: 0.5)],
            overlapBarrier: overlapBarrier
        )
        let vm = Self.makeVM(
            userId: userId,
            bookStore: bookStore,
            positionStore: positionStore,
            root: root,
            coverExtractors: [
                "pdf": SlowCoverExtractor(delay: .zero, overlapBarrier: overlapBarrier)
            ]
        )

        await vm.refresh()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            await overlapBarrier.release()
        }
        let bothBranchesStarted = await overlapBarrier.waitForBothBranches()
        watchdog.cancel()
        await overlapBarrier.release()
        await vm.waitForHydration()

        #expect(bothBranchesStarted, "position and cover hydration should start before either branch is released")
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
        await vm.waitForHydration()

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
        await vm.waitForHydration()

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

private actor RefreshCompletion {
    private var finished = false
    func finish() { finished = true }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !finished {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestReadFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
