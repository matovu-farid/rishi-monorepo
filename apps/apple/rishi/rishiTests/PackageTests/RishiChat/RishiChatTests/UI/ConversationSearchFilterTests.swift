@testable import rishi
import Testing
import Foundation




/// Behavioral contract for ``ConversationSearchFilter``.
///
/// Pure value-type filter — no async, no I/O, no SwiftUI. Each case asserts a
/// single behavior so a regression points to one line in the implementation.
@Suite("ConversationSearchFilter")
struct ConversationSearchFilterTests {

    // MARK: - Fixtures

    private struct Bag {
        let conversations: [Conversation]
        let messagesByConversation: [ConversationID: [Message]]
    }

    private func makeBag() -> Bag {
        // Three conversations with distinct updatedAt to lock ordering.
        let c1 = Conversation(
            userId: UUID(),
            title: "Reading Café notes",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let c2 = Conversation(
            userId: UUID(),
            title: "Philosophy chat",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let c3 = Conversation(
            userId: UUID(),
            title: "Mystery thread",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        // c1 has no matching content; c2 has a message with "espresso";
        // c3 has a message with the title-word "café" diacritic-flipped.
        let messagesByConversation: [ConversationID: [Message]] = [
            c1.id: [
                Message(conversationId: c1.id, role: .user, content: "What does the author mean by transcendence?"),
            ],
            c2.id: [
                Message(conversationId: c2.id, role: .user, content: "I drank an espresso while reading."),
            ],
            c3.id: [
                Message(conversationId: c3.id, role: .user, content: "We went to the cafe yesterday."),
            ],
        ]

        return Bag(conversations: [c2, c3, c1], messagesByConversation: messagesByConversation)
    }

    // MARK: - 1. Empty query returns the input, sorted by updatedAt desc.

    @Test("empty query returns all conversations sorted by updatedAt desc")
    func emptyQueryReturnsAll() {
        let bag = makeBag()
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: ""
        )
        #expect(result.count == 3)
        #expect(result.map { $0.title } == ["Reading Café notes", "Philosophy chat", "Mystery thread"])
    }

    // MARK: - 2. Whitespace-only query is treated as empty.

    @Test("whitespace-only query is treated as empty")
    func whitespaceQueryReturnsAll() {
        let bag = makeBag()
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: "   \n\t "
        )
        #expect(result.count == 3)
    }

    // MARK: - 3. Title match (case-insensitive, diacritic-insensitive).

    @Test("'cafe' matches 'Reading Café notes' (diacritic + case insensitive)")
    func titleMatchDiacriticInsensitive() {
        let bag = makeBag()
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: "cafe"
        )
        // Hits c1 by title AND c3 by message content ("cafe").
        let titles = result.map { $0.title }
        #expect(titles.contains("Reading Café notes"))
        #expect(titles.contains("Mystery thread"))
        #expect(!titles.contains("Philosophy chat"))
    }

    // MARK: - 4. Message-content match.

    @Test("query matching only message content surfaces the parent conversation")
    func messageContentMatch() {
        let bag = makeBag()
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: "espresso"
        )
        #expect(result.count == 1)
        #expect(result.first?.title == "Philosophy chat")
    }

    // MARK: - 5. Result preserves updatedAt-desc ordering.

    @Test("filtered result preserves updatedAt-desc ordering")
    func filteredPreservesOrdering() {
        let bag = makeBag()
        // Match a token that hits c1 (title) AND c3 (message via diacritic-fold) —
        // ensure c1 (newer updatedAt) precedes c3.
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: "cafe"
        )
        #expect(result.count == 2)
        #expect(result[0].title == "Reading Café notes")
        #expect(result[1].title == "Mystery thread")
    }

    // MARK: - 6. Same conversation matched twice (title + message) appears once.

    @Test("a conversation matching by BOTH title and message appears exactly once")
    func dedupedWhenMatchedTwice() {
        let userId = UUID()
        let convo = Conversation(
            userId: userId,
            title: "espresso talks",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let messages = [
            Message(conversationId: convo.id, role: .user, content: "I love espresso."),
            Message(conversationId: convo.id, role: .assistant, content: "Me too — espresso is great."),
        ]
        let result = ConversationSearchFilter.apply(
            conversations: [convo],
            messagesByConversation: [convo.id: messages],
            query: "espresso"
        )
        #expect(result.count == 1)
        #expect(result.first?.id == convo.id)
    }

    // MARK: - 7. No-result query returns empty.

    @Test("query with no matches returns an empty array")
    func noResults() {
        let bag = makeBag()
        let result = ConversationSearchFilter.apply(
            conversations: bag.conversations,
            messagesByConversation: bag.messagesByConversation,
            query: "zzzzzzzzz"
        )
        #expect(result.isEmpty)
    }
}
