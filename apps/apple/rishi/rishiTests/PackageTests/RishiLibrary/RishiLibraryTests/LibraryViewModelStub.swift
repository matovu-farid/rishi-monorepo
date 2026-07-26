@testable import rishi
import Foundation



/// Lightweight stand-in for the real `LibraryViewModel` that lands in
/// Plan 04-06. Holds plain arrays + closures so smoke tests can spin a
/// `LibraryView` against synthetic state without dragging an `@Observable`
/// view-model into this phase.
@MainActor
final class LibraryViewModelStub {
    var books: [Book]
    var positions: [BookID: Position]
    var deletedBooks: [Book] = []
    var openedBooks: [Book] = []

    init(books: [Book] = [], positions: [BookID: Position] = [:]) {
        self.books = books
        self.positions = positions
    }

    var readingNow: [ReadingNowEntry] {
        books.compactMap { book in
            guard let p = positions[book.id], ReadingNowEntry.isInProgress(p) else {
                return nil
            }
            return ReadingNowEntry(book: book, position: p)
        }
    }

    func positionLookup(_ id: BookID) -> Position? { positions[id] }
    func coverURL(_ book: Book) -> URL? { nil }            // smoke tests never hit disk
    func onOpen(_ book: Book) { openedBooks.append(book) }
    func onDelete(_ book: Book) { deletedBooks.append(book) }
}

/// Factory helpers used across smoke tests.
enum LibraryFixture {
    static let userId: UserID = UUID()

    static func book(title: String, author: String? = nil) -> Book {
        Book(
            id: UUID(),
            userId: userId,
            title: title,
            author: author,
            formatType: .epub,
            addedAt: Date(),
            openedAt: nil,
            fileURL: "Books/\(UUID().uuidString)/\(title).epub",
            coverPath: nil,
            positionId: nil,
            conversationId: nil
        )
    }

    static func position(bookId: BookID, percent: Double) -> Position {
        Position(
            id: UUID(),
            bookId: bookId,
            locator: "{\"page\":1}",
            percentComplete: percent,
            updatedAt: Date()
        )
    }
}
