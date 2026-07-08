import Foundation
import SwiftData
import Testing
import RishiCore
@testable import RishiDB

@Suite("RishiDB Schema round-trip")
struct SchemaRoundTripTests {

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        ModelContext(try RishiDB.makeModelContainer(at: URL(fileURLWithPath: ":memory:")))
    }

    // MARK: - Books

    @Test func bookRoundTrips() async throws {
        let context = try makeContext()
        let book = Book(
            userId: UUID(),
            title: "Round Trip Manor",
            author: "A. Schema",
            formatType: .epub,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            openedAt: Date(timeIntervalSince1970: 1_700_000_500.0),
            fileURL: "books/round-trip.epub",
            coverPath: "covers/round-trip.jpg"
        )

        context.insert(
            BookEntity(
                id: book.id,
                userId: book.userId,
                title: book.title,
                author: book.author,
                formatTypeRawValue: book.formatType.rawValue,
                addedAt: book.addedAt,
                openedAt: book.openedAt,
                fileURL: book.fileURL,
                coverPath: book.coverPath,
                positionId: book.positionId,
                conversationId: book.conversationId
            )
        )
        try context.save()

        let fetched: [BookEntity] = try context.fetch(FetchDescriptor<BookEntity>())
        let unwrapped = try #require(fetched.first?.bookValue)

        #expect(unwrapped == book)
    }

    @Test func bookOptionalsRoundTripAsNil() async throws {
        let context = try makeContext()
        let book = Book(
            userId: UUID(),
            title: "Sparse",
            author: nil,
            formatType: .pdf,
            fileURL: "books/sparse.pdf",
            coverPath: nil
        )

        context.insert(
            BookEntity(
                id: book.id,
                userId: book.userId,
                title: book.title,
                author: nil,
                formatTypeRawValue: book.formatType.rawValue,
                addedAt: book.addedAt,
                openedAt: nil,
                fileURL: book.fileURL,
                coverPath: nil,
                positionId: nil,
                conversationId: nil
            )
        )
        try context.save()

        let books: [BookEntity] = try context.fetch(FetchDescriptor<BookEntity>())
        let r = try #require(books.first)
        #expect(r.author == nil)
        #expect(r.coverPath == nil)
        #expect(r.openedAt == nil)
    }

    // MARK: - Position

    @Test func positionRoundTrips() async throws {
        let context = try makeContext()
        let bookId = UUID()

        let pos = Position(bookId: bookId, locator: "epubcfi(/6/4!/4/2)", percentComplete: 0.42, updatedAt: Date())
        context.insert(PositionEntity(
            id: pos.id,
            bookId: pos.bookId,
            locator: pos.locator,
            percentComplete: pos.percentComplete,
            updatedAt: pos.updatedAt
        ))
        try context.save()

        let positions: [PositionEntity] = try context.fetch(FetchDescriptor<PositionEntity>())
        let fetched = try #require(positions.first)
        #expect(fetched.positionValue == pos)
    }

    // MARK: - Highlight

    @Test func highlightRoundTrips() async throws {
        let context = try makeContext()
        let bookId = UUID()

        let h = Highlight(bookId: bookId, locatorStart: "{page:3,offset:120}", locatorEnd: "{page:3,offset:160}",
                          color: .blue, text: "highlighted span", note: "remember this")
        context.insert(HighlightEntity(
            id: h.id,
            bookId: h.bookId,
            locatorStart: h.locatorStart,
            locatorEnd: h.locatorEnd,
            colorRawValue: h.color.rawValue,
            text: h.text,
            note: h.note,
            createdAt: h.createdAt
        ))
        try context.save()

        let highlights: [HighlightEntity] = try context.fetch(FetchDescriptor<HighlightEntity>())
        let fetched = try #require(highlights.first)
        #expect(fetched.highlightValue == h)
    }

    // MARK: - Conversation + Message

    @Test func conversationAndMessageRoundTrip() async throws {
        let context = try makeContext()
        let conv = Conversation(userId: UUID(), bookId: nil, title: "Untitled chat")
        context.insert(ConversationEntity(
            id: conv.id,
            userId: conv.userId,
            bookId: conv.bookId,
            title: conv.title,
            createdAt: conv.createdAt,
            updatedAt: conv.updatedAt
        ))

        let msg = Message(conversationId: conv.id, role: .assistant, content: "hello", toolCalls: "{\"tool\":\"x\"}")
        context.insert(MessageEntity(
            id: msg.id,
            conversationId: msg.conversationId,
            roleRawValue: msg.role.rawValue,
            content: msg.content,
            toolCalls: msg.toolCalls,
            createdAt: msg.createdAt
        ))
        try context.save()

        let conversations: [ConversationEntity] = try context.fetch(FetchDescriptor<ConversationEntity>())
        let fetchedConversation = try #require(conversations.first)
        #expect(fetchedConversation.conversationValue == conv)

        let messages: [MessageEntity] = try context.fetch(FetchDescriptor<MessageEntity>())
        let m = try #require(messages.first)
        #expect(m.messageValue == msg)
    }

    // MARK: - User

    @Test func userRoundTrips() async throws {
        let context = try makeContext()
        let user = User(email: "test@example.com", name: "Test")
        context.insert(UserEntity(
            id: user.id,
            email: user.email ?? "",
            displayName: user.name,
            avatarURL: nil,
            hasPro: true,
            createdAt: .now
        ))
        try context.save()

        let users: [UserEntity] = try context.fetch(FetchDescriptor<UserEntity>())
        let r = try #require(users.first)
        #expect(r.email == "test@example.com")
        #expect(r.hasPro == true)
    }
}
