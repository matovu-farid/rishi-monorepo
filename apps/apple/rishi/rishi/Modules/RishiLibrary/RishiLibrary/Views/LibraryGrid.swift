

import SwiftUI

struct LibraryGrid: View {
    public let books: [Book]
    public let positionLookup: (BookID) -> Position?
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onDelete: (Book) -> Void
    public let selectionMode: Bool
    public let selectedBookIDs: Set<BookID>
    public let onBeginSelection: (Book) -> Void
    public let onToggleSelection: (Book) -> Void
    public let onShareSingle: (Book) -> Void

    @State private var pendingDelete: Book?

    static let coverWidth: CGFloat = 150

    private let columns: [GridItem] = [
        GridItem(
            .adaptive(minimum: coverWidth),
            spacing: 20
        )
    ]


    public init(
        books: [Book],
        positionLookup: @escaping (BookID) -> Position?,
        coverURL: @escaping (Book) -> URL?,
        onOpen: @escaping (Book) -> Void,
        onDelete: @escaping (Book) -> Void,
        selectionMode: Bool = false,
        selectedBookIDs: Set<BookID> = [],
        onBeginSelection: @escaping (Book) -> Void = { _ in },
        onToggleSelection: @escaping (Book) -> Void = { _ in },
        onShareSingle: @escaping (Book) -> Void = { _ in }
    ) {
        self.books = books
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
    

    public var body: some View {
        VStack {
            LazyVGrid(columns: columns, spacing: RishiSpacing.m) {
                ForEach(books) { book in
                    cell(for: book)
                       
                }
            }
            .padding(.horizontal, RishiSpacing.xl)
            .padding(.vertical, RishiSpacing.l)
        }

        .tint(RishiColor.accent)
        .alert(
            "Delete book?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { isPresented in if !isPresented { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { book in
            Button("Delete", role: .destructive) {
                onDelete(book)
                pendingDelete = nil
            }

            .accessibilityLabel("Delete \(book.title)")
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { book in
            Text(
                "Are you sure you want to delete \"\(book.title)\"? This cannot be undone."
            )
        }
    }

    @ViewBuilder
    private func cell(for book: Book) -> some View {
        let hasPosition = positionLookup(book.id) != nil
        Button {
            if selectionMode {
                onToggleSelection(book)
            } else {
                onOpen(book)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                BookCoverImageView(book: book, coverURL: coverURL(book))
                    .frame(width: Self.coverWidth)
                if selectionMode {
                    Image(systemName: selectedBookIDs.contains(book.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, RishiColor.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)

        .accessibilityIdentifier("library-book-cell")
        .accessibilityLabel(accessibilityText(for: book))
        .accessibilityHint(selectionMode ? "Double-tap to select." : "Double-tap to open. Long-press for actions.")
        .contextMenu {
            Button {
                onShareSingle(book)
            } label: {
                Label("Share Book", systemImage: "square.and.arrow.up")
            }
            Button {
                onBeginSelection(book)
            } label: {
                Label("Select to Share", systemImage: "checkmark.circle")
            }
            if hasPosition {
                Button {
                    onOpen(book)
                } label: {
                    Label("Continue Reading", systemImage: "book")
                }
            }
            Button(role: .destructive) {
                pendingDelete = book
            } label: {
                Label("Delete\u{2026}", systemImage: "trash")
            }

            .accessibilityLabel("Delete \(book.title)")
        }
    }

    private func accessibilityText(for book: Book) -> String {
        if let author = book.author, !author.isEmpty {
            return "\(book.title) by \(author)"
        }
        return "\(book.title) by unknown author"
    }
}

private enum LibraryGridPreviewFixtures {
    static let userId: UserID = UUID()

    static func book(
        _ title: String,
        author: String? = "Preview Author",
        format: BookFormat = .epub
    ) -> Book {
        Book(
            id: UUID(),
            userId: userId,
            title: title,
            author: author,
            formatType: format,
            fileURL: "Books/\(UUID().uuidString)/\(title).\(format.rawValue)"
        )
    }

    static let manyBooks: [Book] = [
        book("Project Hail Mary", author: "Andy Weir"),
        book("Sapiens", author: "Yuval Noah Harari"),
        book("The Pragmatic Programmer", author: "Hunt and Thomas"),
        book("Norwegian Wood", author: "Haruki Murakami"),
        book(
            "Designing Data-Intensive Applications",
            author: "Martin Kleppmann"
        ),
        book("Dune", author: "Frank Herbert"),
        book("1984", author: "George Orwell"),
        book("The Hobbit", author: "J.R.R. Tolkien"),
        book("Brave New World", author: "Aldous Huxley"),
        book("Ulysses", author: nil),
        book("PDF Reference", author: "Adobe", format: .pdf),
        book(
            "A Very Very Very Long Title That Wraps Three Lines Or More",
            author: "Anonymous"
        ),
    ]

    static let inProgressIds: Set<BookID> = Set(manyBooks.prefix(3).map(\.id))

    static func positionLookup(_ id: BookID) -> Position? {
        guard inProgressIds.contains(id) else { return nil }
        return Position(
            id: UUID(),
            bookId: id,
            locator: "{\"page\":42}",
            percentComplete: 0.42,
            updatedAt: Date()
        )
    }
}

#Preview("Grid - populated") {
    LibraryGrid(
        books: LibraryGridPreviewFixtures.manyBooks,
        positionLookup: LibraryGridPreviewFixtures.positionLookup,
        coverURL: { _ in nil },
        onOpen: { _ in },
        onDelete: { _ in }
    )
    .background(RishiColor.background)
}

#Preview("Grid - small list") {
    LibraryGrid(
        books: Array(LibraryGridPreviewFixtures.manyBooks.prefix(3)),
        positionLookup: LibraryGridPreviewFixtures.positionLookup,
        coverURL: { _ in nil },
        onOpen: { _ in },
        onDelete: { _ in }
    )
    .background(RishiColor.background)
}

#Preview("Grid - single book") {
    LibraryGrid(
        books: [
            LibraryGridPreviewFixtures.book("Solo Title", author: "Lone Author")
        ],
        positionLookup: { _ in nil },
        coverURL: { _ in nil },
        onOpen: { _ in },
        onDelete: { _ in }
    )
    .background(RishiColor.background)
}

#Preview("Grid - dark mode") {
    LibraryGrid(
        books: LibraryGridPreviewFixtures.manyBooks,
        positionLookup: LibraryGridPreviewFixtures.positionLookup,
        coverURL: { _ in nil },
        onOpen: { _ in },
        onDelete: { _ in }
    )
    .background(RishiColor.background)
    .preferredColorScheme(.dark)
}
