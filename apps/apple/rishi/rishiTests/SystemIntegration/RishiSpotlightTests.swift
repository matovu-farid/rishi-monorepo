import Foundation
import Testing
@testable import rishi

@Suite("Rishi Spotlight integration")
struct RishiSpotlightTests {
    @Test("descriptor IDs, domains, URLs, and searchable metadata are account scoped")
    func descriptorIdentity() {
        let userID = UUID()
        let bookID = UUID()
        let book = Book(
            id: bookID,
            userId: userID,
            title: "Book",
            author: "Author",
            formatType: .epub,
            fileURL: "books/book.epub"
        )

        let descriptor = RishiSpotlightDescriptor.book(book)

        #expect(descriptor.uniqueIdentifier == "book:\(bookID.uuidString)")
        #expect(descriptor.domainIdentifier == "user:\(userID.uuidString)")
        #expect(descriptor.url == URL(string: "https://rishi.fidexa.org/app/book/\(bookID.uuidString)"))
        #expect(descriptor.title == "Book")
        #expect(descriptor.keywords.contains("Author"))
        #expect(DeepLinkRouter().route(descriptor.url) == .openBook(bookID))

        let highlight = Highlight(
            id: UUID(),
            bookId: bookID,
            locatorStart: "start",
            locatorEnd: "end",
            color: .yellow,
            text: "A memorable sentence",
            note: "Remember this"
        )
        let highlightDescriptor = RishiSpotlightDescriptor.highlight(highlight, book: book)

        #expect(highlightDescriptor.uniqueIdentifier == "highlight:\(highlight.id.uuidString)")
        #expect(highlightDescriptor.domainIdentifier == descriptor.domainIdentifier)
        #expect(highlightDescriptor.url == descriptor.url)
        #expect(highlightDescriptor.contentDescription.contains("A memorable sentence"))
        #expect(!highlightDescriptor.contentDescription.contains("start"))
    }

    @Test("entity queries filter by account and match title or author case insensitively")
    func entityQueriesFilterAndMatch() async throws {
        let first = RishiBookEntity(id: UUID(), title: "The Odyssey", author: "Homer")
        let second = RishiBookEntity(id: UUID(), title: "A Separate Peace", author: "John Knowles")
        let query = RishiBookEntityQuery(
            loadByIDs: { ids in [first, second].filter { ids.contains($0.id) } },
            loadAll: { [first, second] }
        )

        #expect(try await query.entities(for: [first.id, UUID()]) == [first])
        #expect(try await query.entities(matching: "HOMER") == [first])
        #expect(try await query.entities(matching: "separate") == [second])
    }

    @Test("reindex deletes the account domain before indexing only the current user's records")
    func reindexIsAccountScoped() async throws {
        let userID = UUID()
        let otherUserID = UUID()
        let currentBook = Book(userId: userID, title: "Current", formatType: .epub, fileURL: "current.epub")
        let otherBook = Book(userId: otherUserID, title: "Other", formatType: .epub, fileURL: "other.epub")
        let client = RecordingSearchIndexingClient()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: InMemoryBookStore(initial: [currentBook, otherBook]),
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { userID },
            indexingClient: client
        )

        await coordinator.reindexCurrentUser()

        let events = await client.events
        #expect(events.count == 2)
        #expect(events.first == .delete(domainIdentifiers: ["user:\(userID.uuidString)"]))
        guard case let .index(descriptors) = events.last else {
            Issue.record("Expected an index event")
            return
        }
        #expect(descriptors.map(\.title) == ["Current"])
    }

    @Test("missing current user clears the named Rishi index without indexing")
    func signedOutReindexClears() async {
        let client = RecordingSearchIndexingClient()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: InMemoryBookStore(),
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { nil },
            indexingClient: client
        )

        await coordinator.reindexCurrentUser()

        #expect(await client.events == [.deleteAll])
    }

    @Test("account transition returns before the new account Spotlight rebuild finishes")
    func accountTransitionDoesNotWaitForNewIndex() async {
        let userID = UUID()
        let client = GatedSearchIndexingClient()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: InMemoryBookStore(initial: [Book(userId: userID, title: "Current", formatType: .epub, fileURL: "current.epub")]),
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { userID },
            indexingClient: client
        )

        let completion = TransitionCompletion()
        let transition = Task {
            let result = await coordinator.transitionAccount { true }
            await completion.finish(result)
            return result
        }
        let indexStarted = await client.waitUntilIndexStarts()
        let completedWhileIndexBlocked = await completion.wait(timeout: .seconds(1))
        let indexIsBlocked = await client.isIndexBlocked
        await client.finishIndex()

        let result = await transition.value
        #expect(result.identityApplied)
        #expect(result.cleanupComplete)
        #expect(indexStarted)
        #expect(completedWhileIndexBlocked)
        #expect(indexIsBlocked)
    }

    @Test("A and B rebuild reads cannot publish after later account transitions")
    func staleAccountRebuildsAreRejected() async {
        let userA = UUID()
        let userB = UUID()
        let identity = MutableSpotlightIdentity()
        await identity.set(userA)
        let store = GatedSpotlightBookStore(initial: [
            Book(userId: userA, title: "A", formatType: .epub, fileURL: "a.epub"),
            Book(userId: userB, title: "B", formatType: .epub, fileURL: "b.epub")
        ])
        let client = GatedSearchIndexingClient()
        let completion = ReindexCompletion()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: store,
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { await identity.value },
            indexingClient: client
        )

        let activeReindex = Task {
            await coordinator.requestReindex()
            await completion.finish()
        }
        let aReadStarted = await store.waitUntilBooksRequested(for: userA)
        let transitionToB = await coordinator.transitionAccount {
            await identity.set(userB)
            return true
        }
        await store.releaseBooks(for: userA)
        let aReadReturned = await store.waitUntilBooksReturned(for: userA)
        let bReadStarted = await store.waitUntilBooksRequested(for: userB)
        let signOut = await coordinator.transitionAccount {
            await identity.set(nil)
            return true
        }

        await store.releaseBooks(for: userB)
        await client.finishIndex()
        let bReadReturned = await store.waitUntilBooksReturned(for: userB)
        let rebuildCompleted = await completion.wait(timeout: .seconds(2))
        if rebuildCompleted {
            await activeReindex.value
        } else {
            activeReindex.cancel()
        }
        await coordinator.waitForScheduledPostCommitReindexes()
        #expect(aReadStarted && bReadStarted)
        #expect(aReadReturned && bReadReturned)
        #expect(transitionToB.identityApplied)
        #expect(signOut.identityApplied)
        #expect(rebuildCompleted)
        guard rebuildCompleted else { return }
        #expect(await client.events.allSatisfy { $0 == .deleteAll })
    }

    @Test("failed outgoing cleanup blocks identity activation until retry succeeds")
    func failedCleanupBlocksIdentityUntilRetry() async {
        let outgoingID = UUID()
        let client = FailOnceCleanupSearchIndexingClient()
        let activation = SpotlightActivationProbe()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: InMemoryBookStore(),
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { outgoingID },
            indexingClient: client
        )

        let result = await coordinator.transitionAccount {
            await activation.markActivated()
            return true
        }
        let eventsAfterFailure = await client.events
        let retried = await client.waitForDeleteAllCount(2)
        let wasActivated = await activation.wasActivated
        let retryResult = await coordinator.transitionAccount {
            await activation.markActivated()
            return true
        }
        let activatedAfterRetry = await activation.wasActivated
        #expect(!result.identityApplied)
        #expect(!result.cleanupComplete)
        #expect(eventsAfterFailure == [.deleteAll])
        #expect(retried)
        #expect(!wasActivated)
        #expect(retryResult.identityApplied)
        #expect(retryResult.cleanupComplete)
        #expect(activatedAfterRetry)
    }

    @Test("repeated foreground reindex requests coalesce into one trailing rebuild")
    func repeatedRequestsCoalesce() async {
        let userID = UUID()
        let client = GatedSearchIndexingClient()
        let coordinator = RishiSpotlightCoordinator(
            bookStore: InMemoryBookStore(initial: [Book(userId: userID, title: "Current", formatType: .epub, fileURL: "current.epub")]),
            highlightStore: InMemoryHighlightStore(),
            conversationStore: InMemoryConversationStore(),
            currentUserID: { userID },
            indexingClient: client
        )
        let reindex = Task { await coordinator.requestReindex() }
        let indexStarted = await client.waitUntilIndexStarts()
        await coordinator.requestReindex()
        await coordinator.requestReindex()
        await client.finishIndex()
        await reindex.value

        #expect(indexStarted)
        #expect(await client.indexCount == 2)
    }
}

private actor TransitionCompletion {
    private var result: RishiSpotlightTransitionResult?

    func finish(_ result: RishiSpotlightTransitionResult) {
        self.result = result
    }

    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return result != nil
    }
}

private actor ReindexCompletion {
    private var isFinished = false

    func finish() {
        isFinished = true
    }

    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isFinished
    }
}

private actor RecordingSearchIndexingClient: RishiSearchIndexingClient {
    enum Event: Equatable {
        case deleteAll
        case delete(domainIdentifiers: [String])
        case index([RishiSpotlightDescriptor])
    }

    private(set) var events: [Event] = []

    func deleteAll() async throws {
        events.append(.deleteAll)
    }

    func delete(domainIdentifiers: [String]) async throws {
        events.append(.delete(domainIdentifiers: domainIdentifiers))
    }

    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws {
        events.append(.index(descriptors))
    }
}

private actor GatedSearchIndexingClient: RishiSearchIndexingClient {
    enum Event: Equatable {
        case deleteAll
        case delete(domainIdentifiers: [String])
        case index
    }

    private(set) var events: [Event] = []
    private(set) var indexCount = 0
    private var indexRelease: CheckedContinuation<Void, Never>?
    private var hasStartedIndex = false
    private var hasBlockedIndex = false
    private var indexWasReleased = false
    private(set) var isIndexBlocked = false

    func deleteAll() async throws {
        events.append(.deleteAll)
    }

    func delete(domainIdentifiers: [String]) async throws {
        events.append(.delete(domainIdentifiers: domainIdentifiers))
    }

    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws {
        events.append(.index)
        indexCount += 1
        hasStartedIndex = true
        guard !hasBlockedIndex, !indexWasReleased else { return }
        hasBlockedIndex = true
        isIndexBlocked = true
        await withCheckedContinuation { continuation in
            indexRelease = continuation
        }
        isIndexBlocked = false
    }

    func waitUntilIndexStarts(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !hasStartedIndex, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hasStartedIndex
    }

    func finishIndex() {
        indexWasReleased = true
        indexRelease?.resume()
        indexRelease = nil
    }
}

private actor MutableSpotlightIdentity {
    private(set) var value: UserID?

    func set(_ value: UserID?) {
        self.value = value
    }
}

private actor GatedSpotlightBookStore: BookStore {
    private let backing: InMemoryBookStore
    private var bookReleaseWaiters: [UserID: CheckedContinuation<Void, Never>] = [:]
    private var requestedUsers: Set<UserID> = []
    private var returnedUsers: Set<UserID> = []
    private var releasedUsers: Set<UserID> = []

    init(initial: [Book]) {
        backing = InMemoryBookStore(initial: initial)
    }

    func books(for userId: UserID) async throws -> [Book] {
        requestedUsers.insert(userId)
        if releasedUsers.remove(userId) == nil {
            await withCheckedContinuation { continuation in
                bookReleaseWaiters[userId] = continuation
            }
        }
        let books = try await backing.books(for: userId)
        returnedUsers.insert(userId)
        return books
    }

    func book(_ id: BookID) async throws -> Book? { try await backing.book(id) }
    func upsert(_ book: Book) async throws { try await backing.upsert(book) }
    func delete(_ id: BookID) async throws { try await backing.delete(id) }

    func waitUntilBooksRequested(for userID: UserID, timeout: Duration = .seconds(1)) async -> Bool {
        await wait(timeout: timeout) { requestedUsers.contains(userID) }
    }

    func waitUntilBooksReturned(for userID: UserID, timeout: Duration = .seconds(1)) async -> Bool {
        await wait(timeout: timeout) { returnedUsers.contains(userID) }
    }

    func releaseBooks(for userID: UserID) {
        if let waiter = bookReleaseWaiters.removeValue(forKey: userID) {
            waiter.resume()
        } else {
            releasedUsers.insert(userID)
        }
    }

    private func wait(timeout: Duration, condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private actor FailOnceCleanupSearchIndexingClient: RishiSearchIndexingClient {
    enum Event: Equatable {
        case deleteAll
        case delete(domainIdentifiers: [String])
        case index
    }

    private(set) var events: [Event] = []
    private var shouldFailFirstDeleteAll = true

    func deleteAll() async throws {
        events.append(.deleteAll)
        if shouldFailFirstDeleteAll {
            shouldFailFirstDeleteAll = false
            throw SpotlightCleanupTestError.failed
        }
    }

    func delete(domainIdentifiers: [String]) async throws {
        events.append(.delete(domainIdentifiers: domainIdentifiers))
    }

    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws {
        events.append(.index)
    }

    func waitForDeleteAllCount(_ count: Int, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while events.filter({ $0 == .deleteAll }).count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events.filter({ $0 == .deleteAll }).count >= count
    }
}

private actor SpotlightActivationProbe {
    private(set) var wasActivated = false

    func markActivated() {
        wasActivated = true
    }
}

private enum SpotlightCleanupTestError: Error {
    case failed
}
