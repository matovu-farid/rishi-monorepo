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

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 140), spacing: RishiSpacing.m)
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
            VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                BookCoverImageView(book: book, coverURL: coverURL(book))
                    .frame(height: 200)
                Text(book.title)
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                    .lineLimit(1)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .lineLimit(1)
                }
            }
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
