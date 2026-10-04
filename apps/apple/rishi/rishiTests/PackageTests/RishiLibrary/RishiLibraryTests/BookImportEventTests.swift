@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Book import events")
struct BookImportEventTests {
    @Test("event stream preserves attempt-scoped registration and readiness order")
    func streamPreservesOrder() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Event Book", formatType: .pdf, fileURL: "Books/event.pdf")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 4, bookID: book.id, attemptID: UUID())
        let events = BookImportEvents()
        var iterator = await events.stream().makeAsyncIterator()

        await events.publish(BookImportEvent(ownerID: owner, accountGeneration: 4, token: token, kind: .registered(book)))
        await events.publish(BookImportEvent(ownerID: owner, accountGeneration: 4, token: token, kind: .managedReady(book.id)))

        #expect(await iterator.next()?.kind == .registered(book))
        #expect(await iterator.next()?.kind == .managedReady(book.id))
    }

    @Test("pending registration publishes the normal fallback without extracting a cover")
    func pendingBookDoesNotExtractCover() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Pending PDF", formatType: .pdf, fileURL: "Books/pending.pdf")
        let store = InMemoryBookStore(initial: [book])
        let probe = CoverResolutionProbe()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { book in await probe.resolve(book) }),
            deleteBook: { _ in },
            currentAccountGeneration: { 12 }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 12, bookID: book.id, attemptID: UUID())

        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 12, token: token, kind: .registered(book)))
        await vm.waitForHydration()

        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.coverURLs[book.id] == nil)
        #expect(await probe.count == 0)
    }

    @Test("late cover and stale-generation events do not restore a deleted book")
    func staleEventsCannotRestoreDeletedBook() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Deleted PDF", formatType: .pdf, fileURL: "Books/deleted.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in URL(fileURLWithPath: "/tmp/cover.heic") }),
            deleteBook: { try await store.delete($0.id) },
            currentAccountGeneration: { 2 }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 2, bookID: book.id, attemptID: UUID())
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 2, token: token, kind: .registered(book)))
        await vm.delete(book)
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 2, token: token, kind: .coverReady(book.id)))
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 2, token: token, kind: .registered(book)))

        #expect(vm.books.isEmpty)
        #expect(vm.coverURLs[book.id] == nil)

        let stale = BookMaterializationToken(ownerID: owner, accountGeneration: 1, bookID: book.id, attemptID: UUID())
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 1, token: stale, kind: .registered(book)))
        #expect(vm.books.isEmpty)
    }

    @Test("queued registration cannot resurrect a book deleted before delivery")
    func queuedRegistrationCannotResurrectDeletedBook() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Queued Registration", formatType: .pdf, fileURL: "Books/queued.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { try await store.delete($0.id) },
            currentAccountGeneration: { 8 }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let events = BookImportEvents()
        var iterator = await events.stream().makeAsyncIterator()
        await events.publish(BookImportEvent(ownerID: owner, accountGeneration: 8, token: token, kind: .registered(book)))

        await vm.refresh()
        await vm.delete(book)
        await vm.refresh()
        if let delayed = await iterator.next() {
            await vm.applyImportEvent(delayed)
        }

        #expect(vm.books.isEmpty)
        #expect(try await store.book(book.id) == nil)
    }

    @Test("queued registration is rejected after an inbound tombstone deletes its row")
    func inboundTombstoneBlocksQueuedRegistration() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Remote Delete", formatType: .epub, fileURL: "Books/remote-delete.epub")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { try await store.delete($0.id) },
            currentAccountGeneration: { 10 }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 10, bookID: book.id, attemptID: UUID())
        let events = BookImportEvents()
        var iterator = await events.stream().makeAsyncIterator()
        await events.publish(BookImportEvent(ownerID: owner, accountGeneration: 10, token: token, kind: .registered(book)))

        await vm.refresh()
        // Models ChangeApplier's remote tombstone path, which deletes the
        // canonical row without calling LibraryViewModel.delete(_:).
        try await store.delete(book.id)
        await vm.refresh()
        if let delayed = await iterator.next() {
            await vm.applyImportEvent(delayed)
        }

        #expect(vm.books.isEmpty)
        #expect(try await store.book(book.id) == nil)
    }

    @Test("late pre-registration refresh cannot overwrite or retire a registered Book")
    func registrationWinsOverOlderRefresh() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Refresh Race", formatType: .epub, fileURL: "Books/race.epub")
        let store = DelayedSnapshotBookStore()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in },
            currentAccountGeneration: { 9 }
        )
        var readyCallbacks: [BookID] = []
        vm.onManagedBookReady = { readyCallbacks.append($0) }
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let refresh = Task { await vm.refresh() }
        await store.waitUntilSnapshotCaptured()
        try await store.upsert(book)

        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 9, token: token, kind: .registered(book)))
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 9, token: token, kind: .managedReady(book.id)))
        await store.releaseSnapshot()
        await refresh.value

        #expect(vm.books.map(\.id) == [book.id])
        #expect(readyCallbacks == [book.id])
    }

    @Test("managed-ready and cover callbacks coalesce into one snapshot refresh")
    func readyEventsCoalesceRefresh() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Coalesced", formatType: .epub, fileURL: "Books/coalesced.epub")
        let store = CountingBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in },
            currentAccountGeneration: { 5 }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 5, bookID: book.id, attemptID: UUID())
        await vm.refresh()
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 5, token: token, kind: .registered(book)))
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 5, token: token, kind: .managedReady(book.id)))
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 5, token: token, kind: .coverReady(book.id)))
        await vm.waitForImportEventRefresh()

        #expect(await store.booksReadCount == 2)
    }

    @Test("cover resolver defers work until the managed file is ready")
    func coverResolverRequiresManagedReadiness() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Deferred Cover", formatType: .epub, fileURL: "Books/deferred.epub")
        let probe = CoverResolutionProbe()
        let resolver = BookCoverResolver(
            resolve: { book in await probe.resolve(book) },
            isManagedReady: { _ in false }
        )

        #expect(await resolver.coverURL(for: book) == nil)
        #expect(await probe.count == 0)
    }

    @Test("book retirement drains admitted effects and rejects stale tokens after rollback")
    func retirementDrainsAndKeepsOldTokenRejected() async throws {
        let owner = UUID()
        let bookID = UUID()
        let registry = BookSourceRegistry(
            currentGeneration: { 3 },
            currentOwnerID: { owner },
            managedURL: { _ in nil }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 3 })
        let retired = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: bookID, attemptID: UUID())
        let lease = try #require(lifecycle.admitBookMaterialization(retired))
        lifecycle.retireBook(ownerID: owner, generation: 3, bookID: bookID)
        #expect(lifecycle.admitBookMaterialization(retired) == nil)
        lease.release()
        await lifecycle.drainBook(ownerID: owner, generation: 3, bookID: bookID)

        #expect(await lifecycle.restoreBookAfterFailedRetirement(ownerID: owner, generation: 3, bookID: bookID, retiredToken: retired))
        #expect(lifecycle.admitBookMaterialization(retired) == nil)
        let retry = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: bookID, attemptID: UUID())
        let retryLease = try #require(lifecycle.admitBookMaterialization(retry))
        retryLease.release()
    }

    private func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("BookImportEvents-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor CountingBookStore: BookStore {
    private var values: [Book]
    private(set) var booksReadCount = 0

    init(initial: [Book]) { values = initial }

    func books(for userId: UserID) async throws -> [Book] {
        booksReadCount += 1
        return values.filter { $0.userId == userId }.sorted { $0.addedAt > $1.addedAt }
    }

    func book(_ id: BookID) async throws -> Book? { values.first { $0.id == id } }
    func upsert(_ book: Book) async throws {
        values.removeAll { $0.id == book.id }
        values.append(book)
    }
    func delete(_ id: BookID) async throws { values.removeAll { $0.id == id } }
}

private actor DelayedSnapshotBookStore: BookStore {
    private var values: [Book] = []
    private var snapshotContinuation: CheckedContinuation<[Book], Never>?
    private var readStarted = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    func books(for userId: UserID) async throws -> [Book] {
        let snapshot = values.filter { $0.userId == userId }
        readStarted = true
        let waiters = readWaiters
        readWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { snapshotContinuation = $0 }
    }

    func waitUntilSnapshotCaptured() async {
        guard !readStarted else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseSnapshot() {
        snapshotContinuation?.resume(returning: [])
        snapshotContinuation = nil
    }

    func book(_ id: BookID) async throws -> Book? { values.first { $0.id == id } }
    func upsert(_ book: Book) async throws {
        values.removeAll { $0.id == book.id }
        values.append(book)
    }
    func delete(_ id: BookID) async throws { values.removeAll { $0.id == id } }
}

private actor CoverResolutionProbe {
    private(set) var count = 0

    func resolve(_ book: Book) -> URL? {
        count += 1
        return URL(fileURLWithPath: "/tmp/\(book.id.uuidString).heic")
    }
}
