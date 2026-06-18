import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level Library screen. Pure SwiftUI; view-model wiring in Plan 04-06.
///
/// LibraryView is a function of its inputs — no `@State`, no `@Environment`.
/// Plan 04-05 will add `.searchable(...)` and Plan 04-06 mounts this inside
/// a `NavigationStack` (or `NavigationSplitView` for iPad/Catalyst) fed by
/// `LibraryViewModel`.
struct LibraryView: View {

    public let books: [Book]
    public let readingNow: [ReadingNowEntry]
    public let positionLookup: (BookID) -> Position?
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onDelete: (Book) -> Void

    public init(books: [Book],
                readingNow: [ReadingNowEntry],
                positionLookup: @escaping (BookID) -> Position?,
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void,
                onDelete: @escaping (Book) -> Void) {
        self.books = books
        self.readingNow = readingNow
        self.positionLookup = positionLookup
        self.coverURL = coverURL
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    public var body: some View {
        Group {
            if books.isEmpty {
                LibraryEmptyStateView()
            } else {
                ScrollView{
                    if !readingNow.isEmpty {
                        ReadingNowShelf(
                            entries: readingNow,
                            coverURL: coverURL,
                            onOpen: onOpen
                        )
                        Divider().background(RishiColor.divider)
                    }
                    LibraryGrid(
                        books: books,
                        positionLookup: positionLookup,
                        coverURL: coverURL,
                        onOpen: onOpen,
                        onDelete: onDelete
                    )
                }
                .background(RishiColor.background)
            }
        }
        .navigationTitle("Library")
    }
}

private enum LibraryViewPreviewFixtures {
    static let userId: UserID = UUID()

    static func book(_ title: String, author: String? = "Preview Author") -> Book {
        Book(
            id: UUID(),
            userId: userId,
            title: title,
            author: author,
            formatType: .epub,
            fileURL: "Books/\(UUID().uuidString)/\(title).epub"
        )
    }

    static let populated: [Book] = [
        book("Project Hail Mary", author: "Andy Weir"),
        book("Sapiens", author: "Yuval Noah Harari"),
        book("The Pragmatic Programmer", author: "Hunt and Thomas"),
        book("Norwegian Wood", author: "Haruki Murakami"),
        book("Designing Data-Intensive Applications", author: "Martin Kleppmann"),
        book("Dune", author: "Frank Herbert"),
        book("1984", author: "George Orwell"),
        book("The Hobbit", author: "J.R.R. Tolkien"),
    ]

    static func readingNow(for books: [Book]) -> [ReadingNowEntry] {
        books.prefix(3).map { b in
            ReadingNowEntry(
                book: b,
                position: Position(
                    id: UUID(),
                    bookId: b.id,
                    locator: "{\"page\":1}",
                    percentComplete: 0.35,
                    updatedAt: Date()
                )
            )
        }
    }
}

#Preview("Library - populated with shelf") {
    NavigationStack {
        LibraryView(
            books: LibraryViewPreviewFixtures.populated,
            readingNow: LibraryViewPreviewFixtures.readingNow(for: LibraryViewPreviewFixtures.populated),
            positionLookup: { _ in nil },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
    }
}

#Preview("Library - no shelf") {
    NavigationStack {
        LibraryView(
            books: LibraryViewPreviewFixtures.populated,
            readingNow: [],
            positionLookup: { _ in nil },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
    }
}

#Preview("Library - empty") {
    NavigationStack {
        LibraryView(
            books: [],
            readingNow: [],
            positionLookup: { _ in nil },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
    }
}

#Preview("Library - dark mode") {
    NavigationStack {
        LibraryView(
            books: LibraryViewPreviewFixtures.populated,
            readingNow: LibraryViewPreviewFixtures.readingNow(for: LibraryViewPreviewFixtures.populated),
            positionLookup: { _ in nil },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
