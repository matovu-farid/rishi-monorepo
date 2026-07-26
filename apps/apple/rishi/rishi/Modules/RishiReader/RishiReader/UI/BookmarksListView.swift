import SwiftUI



/// Modal sheet listing the book's saved bookmarks.
///
/// Engine-agnostic by design: it operates purely on `[Bookmark]` and three
/// callbacks, so both the PDF reader (37-02) and the EPUB reader (37-03) present
/// the same view from the shared `ReaderSheet.bookmarks` case. The caller owns
/// decoding the locator and jumping (PDF via `seek(toPage:)`, EPUB via Readium
/// `go(to:)`).
///
/// Mirrors ``ReaderTOCView``'s plain-header chrome rather than a `NavigationStack`
/// + toolbar "Done": on Mac Catalyst the sheet's NavigationStack bar leaks into
/// the window chrome and its confirmationAction button does not reliably fire,
/// so a plain header Button is used for a cross-platform-reliable dismiss. Each
/// row adds a native destructive `.swipeActions` Delete.
public struct BookmarksListView: View {

    public let bookmarks: [Bookmark]
    public let onSelect: (Bookmark) -> Void
    public let onDelete: (Bookmark) -> Void
    public let onClose: () -> Void

    public init(
        bookmarks: [Bookmark],
        onSelect: @escaping (Bookmark) -> Void,
        onDelete: @escaping (Bookmark) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.bookmarks = bookmarks
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark button while reading to save a page.")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            onSelect(bookmark)
                        } label: {
                            row(for: bookmark)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete(bookmark)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(for bookmark: Bookmark) -> some View {
        HStack(spacing: RishiSpacing.m) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(RishiColor.accent)
            VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                Text(bookmark.label ?? bookmark.snippet ?? "Bookmark")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let snippet = bookmark.snippet, bookmark.label != nil {
                    Text(snippet)
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Bookmarks")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
            Spacer()
            Button("Done", action: onClose)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.accent)
        }
        .padding(.horizontal, RishiSpacing.l)
        .padding(.vertical, RishiSpacing.m)
    }
}

#Preview("Populated") {
    BookmarksListView(
        bookmarks: [
            Bookmark(bookId: UUID(), locator: "", snippet: "It was the best of times"),
            Bookmark(bookId: UUID(), locator: "", label: "Chapter 3", snippet: "a long way from home"),
        ],
        onSelect: { _ in },
        onDelete: { _ in },
        onClose: {}
    )
}

#Preview("Empty") {
    BookmarksListView(
        bookmarks: [],
        onSelect: { _ in },
        onDelete: { _ in },
        onClose: {}
    )
}
