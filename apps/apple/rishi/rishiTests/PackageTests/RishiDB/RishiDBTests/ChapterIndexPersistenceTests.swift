@testable import rishi
import Foundation
import SwiftData
import Testing

@Suite("Chapter index persistence", .serialized)
struct ChapterIndexPersistenceTests {
    @Test("legacy books reopen without an index and can store a complete index")
    func legacyBooksAndRoundTrip() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chapter-index-\(UUID().uuidString).store")
        let container = try RishiDB.makeModelContainer(at: url)
        let db = RishiDBStore(container: container)
        let store = SwiftDataBookStore(dbStore: db)
        let book = Book(userId: UUID(), title: "Legacy", formatType: .epub, fileURL: "legacy.epub")
        try await store.upsert(book)

        #expect(try await store.chapterIndex(bookID: book.id, contentVersion: "v1") == nil)

        let index = ChapterIndex(
            bookID: book.id,
            contentVersion: "v1",
            status: .ready,
            modelIdentifier: "local.test",
            modelVersion: "1",
            progress: .init(completed: 2, total: 2),
            chapters: [
                .init(id: "c1", name: "One", summary: "First", sourcePosition: 0),
                .init(id: "c2", name: "Two", summary: "Second", sourcePosition: 1)
            ],
            errorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try await store.upsertChapterIndex(index)

        let restored = try await store.chapterIndex(bookID: book.id, contentVersion: "v1")
        #expect(restored == index)
        #expect(try await store.chapterIndex(bookID: book.id, contentVersion: "v2") == nil)
    }

    @Test("new book chapter content version survives the BookEntity round trip")
    func newBookVersionRoundTrip() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataBookStore(dbStore: db)
        let book = Book(userId: UUID(), title: "Versioned", formatType: .epub, fileURL: "versioned.epub", chapterIndexContentVersion: "content-v7")

        try await store.upsert(book)

        #expect(try await store.book(book.id)?.chapterIndexContentVersion == "content-v7")
    }

    @Test("deleting a book removes its chapter index and child summaries")
    func deletingBookCleansChapterIndexChildren() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataBookStore(dbStore: db)
        let bookID = UUID()
        let book = Book(id: bookID, userId: UUID(), title: "Delete me", formatType: .epub, fileURL: "delete-me.epub")
        let index = ChapterIndex(bookID: bookID, contentVersion: "v1", status: .ready, modelIdentifier: "m", modelVersion: "1", progress: .init(completed: 1, total: 1), chapters: [.init(id: "chapter-1", name: "One", summary: "Summary")])
        try await store.upsert(book)
        try await store.upsertChapterIndex(index)
        try await store.delete(bookID)

        #expect(try await store.book(bookID) == nil)
        #expect(try await store.chapterIndex(bookID: bookID, contentVersion: "v1") == nil)
        let remaining = try await db.read { context in
            (try context.fetch(FetchDescriptor<ChapterIndexEntity>()).count,
             try context.fetch(FetchDescriptor<ChapterSummaryEntity>()).count)
        }
        #expect(remaining == (0, 0))
    }

    @Test("new content version is stored separately and stale summaries remain readable")
    func contentVersionsDoNotOverwriteEachOther() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataBookStore(dbStore: db)
        let bookID = UUID()
        let base = ChapterIndex(bookID: bookID, contentVersion: "old", status: .ready, modelIdentifier: "m", modelVersion: "1", progress: .init(completed: 1, total: 1), chapters: [.init(id: "c", name: "C", summary: "old")])
        let newer = ChapterIndex(bookID: bookID, contentVersion: "new", status: .building, modelIdentifier: "m", modelVersion: "2", progress: .init(completed: 0, total: 1), chapters: [], errorMessage: "working")

        try await store.upsertChapterIndex(base)
        try await store.upsertChapterIndex(newer)

        #expect(try await store.chapterIndex(bookID: bookID, contentVersion: "old")?.chapters.first?.summary == "old")
        #expect(try await store.chapterIndex(bookID: bookID, contentVersion: "new") == newer)
    }

    @Test("chapter pages restore in source order instead of chapter ID order")
    func sourceOrderSurvivesPersistence() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataBookStore(dbStore: db)
        let bookID = UUID()
        let index = ChapterIndex(
            bookID: bookID,
            contentVersion: "v1",
            status: .ready,
            modelIdentifier: "m",
            modelVersion: "1",
            progress: .init(completed: 3, total: 3),
            chapters: [
                .init(id: "10", name: "Ten", summary: "ten", sourcePosition: 2),
                .init(id: "1", name: "One", summary: "one", sourcePosition: 0),
                .init(id: "2", name: "Two", summary: "two", sourcePosition: 1)
            ]
        )

        try await store.upsertChapterIndex(index)

        #expect(try await store.chapterIndex(bookID: bookID, contentVersion: "v1")?.chapters.map(\.id) == ["1", "2", "10"])
        #expect(try await store.chapterIndex(bookID: bookID, contentVersion: "v1")?.chapters.map(\.sourcePosition) == [0, 1, 2])
    }
}
