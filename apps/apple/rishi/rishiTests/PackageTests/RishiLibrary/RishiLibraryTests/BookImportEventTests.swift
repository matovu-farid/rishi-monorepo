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

    @Test("cancelled registration caller is rejected at event actor ingress")
    func cancelledQueuedRegistrationDoesNotFanOut() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Cancelled Registration", formatType: .epub, fileURL: "Books/cancelled.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 14, bookID: book.id, attemptID: UUID())
        let events = BookImportEvents()
        var iterator = await events.stream().makeAsyncIterator()
        let barrier = BookImportEvent(ownerID: owner, accountGeneration: 14, token: token,
                                      kind: .failed(book.id, retryableCode: "completion_barrier"))
        let gate = EventActorIngressGate()
        let dispatch = Task<Bool, Error> {
            await gate.holdCaller()
            return await events.publishIfNotCancelled(
                BookImportEvent(ownerID: owner, accountGeneration: 14, token: token, kind: .registered(book))
            )
        }

        _ = try #require(await gate.waitUntilEntered())
        dispatch.cancel()
        await gate.release()
        #expect(try await boundedEventValue(dispatch) == false)
        await events.publish(barrier)
        #expect(await iterator.next() == barrier)
    }

    @Test("cancelled retry still delivers its terminal failure event")
    func cancelledRetryStillPublishesFailure() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Cancelled Retry", formatType: .epub, fileURL: "Books/retry-failure.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 15, bookID: book.id, attemptID: UUID())
        let event = BookImportEvent(ownerID: owner, accountGeneration: 15, token: token,
                                    kind: .failed(book.id, retryableCode: "selected_source_changed"))
        let events = BookImportEvents()
        var iterator = await events.stream().makeAsyncIterator()
        let gate = EventActorIngressGate()
        let dispatch = Task<Bool, Error> {
            await gate.holdCaller()
            await events.publish(event)
            return true
        }

        _ = try #require(await gate.waitUntilEntered())
        dispatch.cancel()
        await gate.release()
        #expect(try await boundedEventValue(dispatch))
        #expect(await iterator.next() == event)
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

private actor EventActorIngressGate {
    private var entered = false
    private var released = false

    func holdCaller() async {
        entered = true
        for _ in 0..<400 {
            if released { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() { released = true }
}

private final class EventActorIngressResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ outcome: Result<Value, Error>) -> Bool {
        lock.lock()
        guard case .none = self.outcome else { lock.unlock(); return false }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: outcome)
        return true
    }
}

private func boundedEventValue<Value: Sendable>(_ task: Task<Value, Error>, timeout: Duration = .seconds(4)) async throws -> Value {
    let result = EventActorIngressResult<Value>()
    Task {
        do { _ = result.resolve(.success(try await task.value)) }
        catch { _ = result.resolve(.failure(error)) }
    }
    Task {
        try? await Task.sleep(for: timeout)
        if result.resolve(.failure(EventActorIngressTimeout.expired)) { task.cancel() }
    }
    return try await result.value()
}

private enum EventActorIngressTimeout: Error { case expired }

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
        // Only the pre-registration read is held. Registration invalidates
        // that snapshot and refresh legitimately rereads the current store.
        guard !readStarted else { return snapshot }
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
