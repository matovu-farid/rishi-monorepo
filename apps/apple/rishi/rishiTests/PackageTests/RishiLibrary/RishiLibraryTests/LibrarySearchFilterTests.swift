@testable import rishi
import Testing
import Foundation



@Suite("LibrarySearchFilter")
struct LibrarySearchFilterTests {

    private func book(
        _ title: String,
        author: String? = nil,
        fileURL: String? = nil
    ) -> Book {
        Book(
            userId: UUID(),
            title: title,
            author: author,
            formatType: .epub,
            fileURL: fileURL ?? "Books/x/\(title).epub"
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

    @Test("Multi-word substring works (contiguous substring)")
    func multiWordSubstring() {
        let books = [book("Alice's Adventures in Wonderland")]
        let out = LibrarySearchFilter.filter(books: books, query: "adventures in")
        #expect(out.count == 1)
    }

    @Test("Multi-token query: 'alice wonder' matches 'Alice in Wonderland' (AND across tokens)")
    func multiTokenAndAcrossTitle() {
        let books = [
            book("Alice in Wonderland"),
            book("Moby Dick"),
        ]
        let out = LibrarySearchFilter.filter(books: books, query: "alice wonder")
        #expect(out.map(\.title) == ["Alice in Wonderland"])
    }

    @Test("Multi-token query AND across title + author (token can hit either field)")
    func multiTokenAcrossTitleAndAuthor() {
        let books = [
            book("Alice in Wonderland", author: "Lewis Carroll"),
            book("Through the Looking Glass", author: "Lewis Carroll"),
            book("Moby Dick", author: "Herman Melville"),
        ]
        // "carroll alice": author hits the first token, title hits the second.
        let out = LibrarySearchFilter.filter(books: books, query: "carroll alice")
        #expect(out.map(\.title) == ["Alice in Wonderland"])
    }

    @Test("Author substring is case-insensitive (CARROLL matches Carroll)")
    func authorCaseInsensitive() {
        let books = [book("Untitled", author: "Lewis Carroll")]
        let out = LibrarySearchFilter.filter(books: books, query: "CARROLL")
        #expect(out.count == 1)
    }

    @Test("Filename basename is searched as a fallback (covers metadata-less imports)")
    func filenameFallbackMatches() {
        // Simulates the user-reported case: file dropped in as
        // `1751655520501062500_alice.epub`, embedded metadata missing, so the
        // import path stored `title == "1751655520501062500 alice"`. The user
        // types "alice"; we still want a hit.
        let books = [
            book(
                "1751655520501062500 alice",
                author: nil,
                fileURL: "Books/abc/1751655520501062500_alice.epub"
            ),
            book("Moby Dick", author: "Herman Melville"),
        ]
        let out = LibrarySearchFilter.filter(books: books, query: "alice")
        #expect(out.count == 1)
        #expect(out.first?.fileURL.contains("alice.epub") == true)
    }

    @Test("Query whitespace is trimmed before tokenisation")
    func queryWhitespaceTrim() {
        let books = [book("Alice in Wonderland")]
        let out = LibrarySearchFilter.filter(books: books, query: "  alice   wonder  ")
        #expect(out.count == 1)
    }
}
