import SwiftUI
import RishiCore
import RishiUIKit

/// LIB-04: adaptive `LazyVGrid` of all books. Each cell carries a
/// `.contextMenu` with "Continue Reading" (when a `Position` exists) and a
/// destructive "Delete…" that opens a SwiftUI `.alert` confirmation.
///
/// The grid is intentionally state-light: it owns ONLY the pending-delete
/// `Book?` for the confirmation alert. Everything else is upstream input.
public struct LibraryGrid: View {
    public let books: [Book]
    public let positionLookup: (BookID) -> Position?
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onDelete: (Book) -> Void

    @State private var pendingDelete: Book?

    /// Fixed 2-column grid. Phase 21 UI pass: the prior adaptive layout
    /// combined with per-tile text labels produced uneven row heights and
    /// visible bleed between rows. A fixed 2-column grid + fixed 2:3 aspect
    /// tiles + no per-tile chrome guarantees a uniform mosaic.
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: RishiSpacing.m),
        GridItem(.flexible(), spacing: RishiSpacing.m)
    ]

    public init(books: [Book],
                positionLookup: @escaping (BookID) -> Position?,
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void,
                onDelete: @escaping (Book) -> Void) {
        self.books = books
        self.positionLookup = positionLookup
        self.coverURL = coverURL
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: RishiSpacing.l) {
                ForEach(books) { book in
                    cell(for: book)
                }
            }
            .padding(.horizontal, RishiSpacing.l)
            .padding(.vertical, RishiSpacing.m)
        }
        .background(RishiColor.background)
        .alert(
            "Delete book?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { book in
            Button("Delete", role: .destructive) {
                onDelete(book)
                pendingDelete = nil
            }
            // Per-book label so VoiceOver users know which title is about
            // to be deleted before they confirm. A11Y-01 — A11yLabel only
            // ships the verb; we interpolate the book title here.
            .accessibilityLabel("Delete \(book.title)")
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { book in
            Text("Are you sure you want to delete \"\(book.title)\"? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func cell(for book: Book) -> some View {
        let hasPosition = positionLookup(book.id) != nil
        Button {
            onOpen(book)
        } label: {
            // Phase 21 UI pass: the tile is pure cover art at a fixed 2:3
            // portrait aspect ratio (standard book-cover proportion). No
            // title / author labels — they pushed multi-line text into the
            // next row's tile and made the grid look ragged. Tap reveals
            // the book; VoiceOver still announces "<title> by <author>"
            // via the accessibility label below.
            BookCoverImageView(book: book, coverURL: coverURL(book))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: book))
        .accessibilityHint("Double-tap to open. Long-press for actions.")
        .contextMenu {
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
            // Per-book label so VoiceOver users hear which book the
            // destructive action targets.
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

    static func book(_ title: String, author: String? = "Preview Author", format: BookFormat = .epub) -> Book {
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
        book("Designing Data-Intensive Applications", author: "Martin Kleppmann"),
        book("Dune", author: "Frank Herbert"),
        book("1984", author: "George Orwell"),
        book("The Hobbit", author: "J.R.R. Tolkien"),
        book("Brave New World", author: "Aldous Huxley"),
        book("Ulysses", author: nil),
        book("PDF Reference", author: "Adobe", format: .pdf),
        book("A Very Very Very Long Title That Wraps Three Lines Or More", author: "Anonymous"),
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
        books: [LibraryGridPreviewFixtures.book("Solo Title", author: "Lone Author")],
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
