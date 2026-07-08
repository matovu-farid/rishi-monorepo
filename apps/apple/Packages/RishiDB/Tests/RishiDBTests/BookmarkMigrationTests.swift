import Foundation
import Testing
import SwiftData
import RishiCore
@testable import RishiDB

@Suite("RishiDB cascade semantics")
struct BookmarkMigrationTests {

    @Test func deletingBookRemovesDependentRowsButNotConversation() async throws {
        let store = try makeStore()
        let bookId = UUID()
        let userId = UUID()
        let conversationId = UUID()

        let book = Book(id: bookId, userId: userId, title: "Cascade", formatType: .epub, fileURL: "books/cascade.epub")
        let position = Position(bookId: bookId, locator: "cfi-1")
        let highlight = Highlight(bookId: bookId, locatorStart: "a", locatorEnd: "b", color: .yellow, text: "note")
        let bookmark = Bookmark(bookId: bookId, locator: "loc-1", label: "label")
        let conversation = Conversation(id: conversationId, userId: userId, bookId: bookId, title: "Thread")
        let message = Message(conversationId: conversationId, role: .user, content: "hello")

        let books = SwiftDataBookStore(dbStore: store)
        let positions = SwiftDataPositionStore(dbStore: store)
        let highlights = SwiftDataHighlightStore(dbStore: store)
        let bookmarks = SwiftDataBookmarkStore(dbStore: store)
        let conversations = SwiftDataConversationStore(dbStore: store)
        let messages = SwiftDataMessageStore(dbStore: store)

        try await books.upsert(book)
        try await positions.upsert(position)
        try await highlights.upsert(highlight)
        try await bookmarks.upsert(bookmark)
        try await conversations.upsert(conversation)
        try await messages.upsert(message)

        try await books.delete(bookId)

        #expect((try await positions.position(for: bookId)) == nil)
        #expect((try await highlights.highlights(for: bookId)) == [])
        #expect((try await bookmarks.bookmarks(for: bookId)) == [])
        #expect((try await conversations.conversation(conversationId)) != nil)
        #expect((try await messages.message(message.id)) != nil)
    }

    @Test func deletingConversationRemovesMessages() async throws {
        let store = try makeStore()
        let conversationId = UUID()
        let userId = UUID()
        let conversation = Conversation(id: conversationId, userId: userId, title: "Thread")
        let messageA = Message(conversationId: conversationId, role: .user, content: "hello")
        let messageB = Message(conversationId: conversationId, role: .assistant, content: "world")

        let conversations = SwiftDataConversationStore(dbStore: store)
        let messages = SwiftDataMessageStore(dbStore: store)

        try await conversations.upsert(conversation)
        try await messages.upsert(messageA)
        try await messages.upsert(messageB)

        try await conversations.delete(conversationId)

        #expect((try await conversations.conversation(conversationId)) == nil)
        #expect((try await messages.messages(for: conversationId)).isEmpty)
    }

    private func makeStore() throws -> RishiDBStore {
        try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
    }
}
