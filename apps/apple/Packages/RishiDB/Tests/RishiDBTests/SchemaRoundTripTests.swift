import Foundation
import Testing
import GRDB
import RishiCore
@testable import RishiDB

@Suite("RishiDB Schema round-trip")
struct SchemaRoundTripTests {

    // MARK: - Helpers

    private func makeQueue() throws -> DatabaseQueue {
        try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))
    }

    // MARK: - Books

    @Test func bookRoundTrips() async throws {
        let queue = try makeQueue()
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

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Books.table)
                  (\(Tables.Books.id), \(Tables.Books.userId), \(Tables.Books.title), \(Tables.Books.author),
                   \(Tables.Books.formatType), \(Tables.Books.addedAt), \(Tables.Books.openedAt),
                   \(Tables.Books.fileURL), \(Tables.Books.coverPath),
                   \(Tables.Books.positionId), \(Tables.Books.conversationId))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                book.id.uuidString, book.userId.uuidString, book.title, book.author,
                book.formatType.rawValue, book.addedAt.timeIntervalSince1970, book.openedAt?.timeIntervalSince1970,
                book.fileURL, book.coverPath,
                book.positionId?.uuidString, book.conversationId?.uuidString,
            ])
        }

        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Books.table) WHERE \(Tables.Books.id) = ?",
                             arguments: [book.id.uuidString])
        }
        let unwrapped = try #require(row)

        #expect(unwrapped[Tables.Books.id] as String? == book.id.uuidString)
        #expect(unwrapped[Tables.Books.title] as String? == "Round Trip Manor")
        #expect(unwrapped[Tables.Books.author] as String? == "A. Schema")
        #expect(unwrapped[Tables.Books.formatType] as String? == "epub")
        let storedAddedAt: Double? = unwrapped[Tables.Books.addedAt]
        #expect(abs((storedAddedAt ?? 0) - book.addedAt.timeIntervalSince1970) < 0.001)
    }

    @Test func bookOptionalsRoundTripAsNil() async throws {
        let queue = try makeQueue()
        let book = Book(
            userId: UUID(),
            title: "Sparse",
            author: nil,
            formatType: .pdf,
            fileURL: "books/sparse.pdf",
            coverPath: nil
        )

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Books.table)
                  (\(Tables.Books.id), \(Tables.Books.userId), \(Tables.Books.title), \(Tables.Books.author),
                   \(Tables.Books.formatType), \(Tables.Books.addedAt), \(Tables.Books.openedAt),
                   \(Tables.Books.fileURL), \(Tables.Books.coverPath),
                   \(Tables.Books.positionId), \(Tables.Books.conversationId))
                VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, NULL, NULL, NULL)
            """, arguments: [
                book.id.uuidString, book.userId.uuidString, book.title,
                book.formatType.rawValue, book.addedAt.timeIntervalSince1970,
                book.fileURL,
            ])
        }

        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Books.table)")
        }
        let r = try #require(row)
        #expect(r[Tables.Books.author] as String? == nil)
        #expect(r[Tables.Books.coverPath] as String? == nil)
        #expect(r[Tables.Books.openedAt] as Double? == nil)
    }

    // MARK: - Position

    @Test func positionRoundTrips() async throws {
        let queue = try makeQueue()
        let bookId = UUID()
        // need a parent books row because of FK
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Books.table)
                  (\(Tables.Books.id), \(Tables.Books.userId), \(Tables.Books.title),
                   \(Tables.Books.formatType), \(Tables.Books.addedAt), \(Tables.Books.fileURL))
                VALUES (?, ?, 'host', 'epub', ?, 'books/host.epub')
            """, arguments: [bookId.uuidString, UUID().uuidString, Date().timeIntervalSince1970])
        }

        let pos = Position(bookId: bookId, locator: "epubcfi(/6/4!/4/2)", percentComplete: 0.42, updatedAt: Date())
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Positions.table)
                  (\(Tables.Positions.id), \(Tables.Positions.bookId), \(Tables.Positions.locator),
                   \(Tables.Positions.percentComplete), \(Tables.Positions.updatedAt))
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [pos.id.uuidString, pos.bookId.uuidString, pos.locator,
                             pos.percentComplete, pos.updatedAt.timeIntervalSince1970])
        }

        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Positions.table) WHERE \(Tables.Positions.id) = ?",
                             arguments: [pos.id.uuidString])
        }
        let r = try #require(row)
        #expect(r[Tables.Positions.locator] as String? == "epubcfi(/6/4!/4/2)")
        #expect(abs((r[Tables.Positions.percentComplete] as Double? ?? -1) - 0.42) < 0.0001)
    }

    // MARK: - Highlight

    @Test func highlightRoundTrips() async throws {
        let queue = try makeQueue()
        let bookId = UUID()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Books.table)
                  (\(Tables.Books.id), \(Tables.Books.userId), \(Tables.Books.title),
                   \(Tables.Books.formatType), \(Tables.Books.addedAt), \(Tables.Books.fileURL))
                VALUES (?, ?, 'host', 'pdf', ?, 'books/host.pdf')
            """, arguments: [bookId.uuidString, UUID().uuidString, Date().timeIntervalSince1970])
        }

        let h = Highlight(bookId: bookId, locatorStart: "{page:3,offset:120}", locatorEnd: "{page:3,offset:160}",
                          color: .blue, text: "highlighted span", note: "remember this")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Highlights.table)
                  (\(Tables.Highlights.id), \(Tables.Highlights.bookId), \(Tables.Highlights.locatorStart),
                   \(Tables.Highlights.locatorEnd), \(Tables.Highlights.color), \(Tables.Highlights.text),
                   \(Tables.Highlights.note), \(Tables.Highlights.createdAt))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [h.id.uuidString, h.bookId.uuidString, h.locatorStart, h.locatorEnd,
                             h.color.rawValue, h.text, h.note, h.createdAt.timeIntervalSince1970])
        }

        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Highlights.table) WHERE \(Tables.Highlights.id) = ?",
                             arguments: [h.id.uuidString])
        }
        let r = try #require(row)
        #expect(r[Tables.Highlights.color] as String? == "blue")
        #expect(r[Tables.Highlights.note] as String? == "remember this")
    }

    // MARK: - Conversation + Message

    @Test func conversationAndMessageRoundTrip() async throws {
        let queue = try makeQueue()
        let conv = Conversation(userId: UUID(), bookId: nil, title: "Untitled chat")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Conversations.table)
                  (\(Tables.Conversations.id), \(Tables.Conversations.userId), \(Tables.Conversations.bookId),
                   \(Tables.Conversations.title), \(Tables.Conversations.createdAt), \(Tables.Conversations.updatedAt))
                VALUES (?, ?, NULL, ?, ?, ?)
            """, arguments: [conv.id.uuidString, conv.userId.uuidString, conv.title,
                             conv.createdAt.timeIntervalSince1970, conv.updatedAt.timeIntervalSince1970])
        }

        let msg = Message(conversationId: conv.id, role: .assistant, content: "hello", toolCalls: "{\"tool\":\"x\"}")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Messages.table)
                  (\(Tables.Messages.id), \(Tables.Messages.conversationId), \(Tables.Messages.role),
                   \(Tables.Messages.content), \(Tables.Messages.toolCalls), \(Tables.Messages.createdAt))
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [msg.id.uuidString, msg.conversationId.uuidString, msg.role.rawValue,
                             msg.content, msg.toolCalls, msg.createdAt.timeIntervalSince1970])
        }

        let mRow: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Messages.table) WHERE \(Tables.Messages.id) = ?",
                             arguments: [msg.id.uuidString])
        }
        let m = try #require(mRow)
        #expect(m[Tables.Messages.role] as String? == "assistant")
        #expect(m[Tables.Messages.toolCalls] as String? == "{\"tool\":\"x\"}")
    }

    // MARK: - User

    @Test func userRoundTrips() async throws {
        let queue = try makeQueue()
        let user = User(email: "test@example.com", displayName: "Test", avatarURL: URL(string: "https://x/y.jpg"),
                        hasPro: true)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO \(Tables.Users.table)
                  (\(Tables.Users.id), \(Tables.Users.email), \(Tables.Users.displayName),
                   \(Tables.Users.avatarURL), \(Tables.Users.hasPro), \(Tables.Users.createdAt))
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [user.id.uuidString, user.email, user.displayName,
                             user.avatarURL?.absoluteString, user.hasPro ? 1 : 0,
                             user.createdAt.timeIntervalSince1970])
        }

        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(Tables.Users.table) WHERE \(Tables.Users.id) = ?",
                             arguments: [user.id.uuidString])
        }
        let r = try #require(row)
        #expect(r[Tables.Users.email] as String? == "test@example.com")
        #expect(r[Tables.Users.hasPro] as Int? == 1)
    }
}
