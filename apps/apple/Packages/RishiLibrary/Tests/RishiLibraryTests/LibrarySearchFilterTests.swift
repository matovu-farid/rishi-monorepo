import Testing
import Foundation
@testable import RishiLibrary
import RishiCore

@Suite("LibrarySearchFilter")
struct LibrarySearchFilterTests {

    private func book(_ title: String, author: String? = nil) -> Book {
        Book(
            userId: UUID(),
            title: title,
            author: author,
            formatType: .epub,
            fileURL: "Books/x/\(title).epub"
        )
    }

    @Test("Empty query returns the input array unchanged")
    func emptyQueryIdentity() {
        let books = [book("A"), book("B")]
        let out = LibrarySearchFilter.filter(books: books, query: "")
        #expect(out.map(\.title) == ["A", "B"])
        let ws = LibrarySearchFilter.filter(books: books, query: "   ")
        #expect(ws.map(\.title) == ["A", "B"])
    }

    @Test("Title substring is matched case-insensitively")
    func titleMatch() {
        let books = [book("Alice's Adventures in Wonderland"), book("Moby Dick")]
        let out = LibrarySearchFilter.filter(books: books, query: "alice")
        #expect(out.map(\.title) == ["Alice's Adventures in Wonderland"])
    }

    @Test("Author substring is matched case-insensitively")
    func authorMatch() {
        let books = [
            book("Untitled", author: "Lewis Carroll"),
            book("Moby Dick", author: "Herman Melville"),
        ]
        let out = LibrarySearchFilter.filter(books: books, query: "carroll")
        #expect(out.map(\.title) == ["Untitled"])
    }

    @Test("Diacritic-insensitive: 'cafe' matches 'Café'")
    func diacriticInsensitive() {
        let books = [book("Café"), book("Diner")]
        let out = LibrarySearchFilter.filter(books: books, query: "cafe")
        #expect(out.map(\.title) == ["Café"])
    }

    @Test("No match returns empty array")
    func noMatch() {
        let books = [book("Alpha"), book("Beta")]
        let out = LibrarySearchFilter.filter(books: books, query: "gamma")
        #expect(out.isEmpty)
    }

    @Test("nil author does not crash and is not matched")
    func nilAuthorSafety() {
        let books = [book("Alpha", author: nil)]
        let out = LibrarySearchFilter.filter(books: books, query: "nil")
        #expect(out.isEmpty)
    }

    @Test("Multi-word substring works (single-substring semantics)")
    func multiWordSubstring() {
        let books = [book("Alice's Adventures in Wonderland")]
        let out = LibrarySearchFilter.filter(books: books, query: "adventures in")
        #expect(out.count == 1)
        let outNonContiguous = LibrarySearchFilter.filter(books: books, query: "alice wonderland")
        // Non-contiguous: NOT matched. Explicit decision — matches electron's substring search.
        #expect(outNonContiguous.isEmpty)
    }
}
