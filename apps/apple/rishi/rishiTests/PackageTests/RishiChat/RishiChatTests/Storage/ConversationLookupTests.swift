@testable import rishi
import Testing
import Foundation




@Suite("ConversationLookup")
struct ConversationLookupTests {

    private func makeLookup(initial: [Conversation] = []) -> (ConversationLookup, InMemoryConversationStore) {
        let store = InMemoryConversationStore(initial: initial)
        let lookup = ConversationLookup(store: store)
        return (lookup, store)
    }

    @Test("first call for (user, book) creates and persists a new Conversation")
    func firstCallCreatesAndPersists() async throws {
        let (lookup, store) = makeLookup()
        let userId = UUID()
        let bookId = UUID()

        let created = try await lookup.findOrCreate(userId: userId, bookId: bookId)

        #expect(created.userId == userId)
        #expect(created.bookId == bookId)
        let roundTrip = try await store.conversation(created.id)
        #expect(roundTrip?.id == created.id)
    }

    @Test("second call with same (user, book) returns the same conversation id")
    func secondCallReturnsSameId() async throws {
        let (lookup, _) = makeLookup()
        let userId = UUID()
        let bookId = UUID()

        let first = try await lookup.findOrCreate(userId: userId, bookId: bookId)
        let second = try await lookup.findOrCreate(userId: userId, bookId: bookId)

        #expect(first.id == second.id)
    }

    @Test("(user, b1) and (user, b2) yield distinct conversations")
    func distinctBooksYieldDistinctConversations() async throws {
        let (lookup, _) = makeLookup()
        let userId = UUID()
        let b1 = UUID()
        let b2 = UUID()

        let convo1 = try await lookup.findOrCreate(userId: userId, bookId: b1)
        let convo2 = try await lookup.findOrCreate(userId: userId, bookId: b2)

        #expect(convo1.id != convo2.id)
        #expect(convo1.bookId == b1)
        #expect(convo2.bookId == b2)
    }

    @Test("bookId nil matches another nil-bookId conversation")
    func nilBookIdMatchesNil() async throws {
        let (lookup, _) = makeLookup()
        let userId = UUID()

        let first = try await lookup.findOrCreate(userId: userId, bookId: nil)
        let second = try await lookup.findOrCreate(userId: userId, bookId: nil)

        #expect(first.id == second.id)
        #expect(first.bookId == nil)
    }

    @Test("returns the most-recently-updated conversation when multiple match")
    func returnsMostRecentlyUpdated() async throws {
        let userId = UUID()
        let bookId = UUID()
        let older = Conversation(
            userId: userId,
            bookId: bookId,
            title: "Older",
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1000)
        )
        let newer = Conversation(
            userId: userId,
            bookId: bookId,
            title: "Newer",
            createdAt: Date(timeIntervalSinceReferenceDate: 2000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2000)
        )
        let (lookup, _) = makeLookup(initial: [older, newer])

        let found = try await lookup.findOrCreate(userId: userId, bookId: bookId)

        #expect(found.id == newer.id)
    }
}
