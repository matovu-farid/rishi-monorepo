import SwiftUI



/// Top-level Library screen. Pure SwiftUI; view-model wiring in Plan 04-06.
///
/// LibraryView is a function of its inputs — no `@State`, no `@Environment`.
/// Plan 04-05 will add `.searchable(...)` and Plan 04-06 mounts this inside
/// a `NavigationStack` (or `NavigationSplitView` for iPad/Catalyst) fed by
/// `LibraryViewModel`.
public struct LibraryView: View {

    public let books: [Book]
    public let readingNow: [ReadingNowEntry]
    public let libraryBookCount: Int?
    public let positionLookup: (BookID) -> Position?
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onDelete: (Book) -> Void
    public let selectionMode: Bool
    public let selectedBookIDs: Set<BookID>
    public let onBeginSelection: (Book) -> Void
    public let onToggleSelection: (Book) -> Void
    public let onShareSingle: (Book) -> Void

    public init(books: [Book],
                readingNow: [ReadingNowEntry] = [],
                libraryBookCount: Int? = nil,
                positionLookup: @escaping (BookID) -> Position?,
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void,
                onDelete: @escaping (Book) -> Void,
                selectionMode: Bool = false,
                selectedBookIDs: Set<BookID> = [],
                onBeginSelection: @escaping (Book) -> Void = { _ in },
                onToggleSelection: @escaping (Book) -> Void = { _ in },
                onShareSingle: @escaping (Book) -> Void = { _ in }) {
        self.books = books
        self.readingNow = readingNow
        self.libraryBookCount = libraryBookCount
        self.positionLookup = positionLookup
        self.coverURL = coverURL
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.selectionMode = selectionMode
        self.selectedBookIDs = selectedBookIDs
        self.onBeginSelection = onBeginSelection
        self.onToggleSelection = onToggleSelection
        self.onShareSingle = onShareSingle
    }

    public static func shouldShowReadingNow(_ entries: [ReadingNowEntry]) -> Bool {
        !entries.isEmpty
    }

    public var body: some View {
        ZStack{
            Color(RishiColor.accent)
                .opacity(0.1)
                .ignoresSafeArea()
            
            Group {
                if libraryBookCount.map { $0 == 0 } ?? (books.isEmpty && readingNow.isEmpty) {
                    LibraryEmptyStateView()
                } else {
                    ScrollView {
                        if Self.shouldShowReadingNow(readingNow) {
                            ReadingNowShelf(
                                entries: readingNow,
                                coverURL: coverURL,
                                onOpen: onOpen
                            )
                        }

                        if !books.isEmpty {
                            LibraryGrid(
                                books: books,
                                positionLookup: positionLookup,
                                coverURL: coverURL,
                                onOpen: onOpen,
                                onDelete: onDelete,
                                selectionMode: selectionMode,
                                selectedBookIDs: selectedBookIDs,
                                onBeginSelection: onBeginSelection,
                                onToggleSelection: onToggleSelection,
                                onShareSingle: onShareSingle
                            )
                        }
                    }
                    .tint(RishiColor.accent)
                    
                }
            }
        }
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
    
    static  let  populated:[Book] = [
        book("Project Hail Mary", author: "Andy Weir"),
        book("Sapiens", author: "Yuval Noah Harari"),
        book("The Pragmatic Programmer", author: "Hunt and Thomas"),
        book("Norwegian Wood", author: "Haruki Murakami"),
        book("Designing Data-Intensive Applications", author: "Martin Kleppmann"),
        book("Dune", author: "Frank Herbert"),
        book("1984", author: "George Orwell"),
        book("The Hobbit", author: "J.R.R. Tolkien"),
        
    ]
}


#Preview("Library - no shelf") {
    NavigationStack {
        LibraryView(
            books: LibraryViewPreviewFixtures.populated,
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
            positionLookup: { _ in nil },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
