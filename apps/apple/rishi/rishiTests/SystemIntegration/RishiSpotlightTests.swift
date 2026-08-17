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
