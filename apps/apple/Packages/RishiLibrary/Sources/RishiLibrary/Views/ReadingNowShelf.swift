import SwiftUI
import RishiCore
import RishiUIKit

/// LIB-05: horizontal shelf showing in-progress books at the top of the
/// Library screen. Filtered by `ReadingNowEntry.isInProgress(_:)` upstream
/// (the view itself trusts the caller).
public struct ReadingNowShelf: View {
    public let entries: [ReadingNowEntry]
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void

    public init(entries: [ReadingNowEntry],
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void) {
        self.entries = entries
        self.coverURL = coverURL
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            Text("Reading Now")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textSecondary)
                .padding(.horizontal, RishiSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RishiSpacing.m) {
                    ForEach(entries) { entry in
                        card(for: entry)
                    }
                }
                .padding(.horizontal, RishiSpacing.l)
            }
        }
        .padding(.vertical, RishiSpacing.m)
        .background(RishiColor.surface)
    }

    @ViewBuilder
    private func card(for entry: ReadingNowEntry) -> some View {
        Button {
            onOpen(entry.book)
        } label: {
            VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                BookCoverImageView(book: entry.book, coverURL: coverURL(entry.book))
                    .frame(width: 110, height: 165)
                Text(entry.book.title)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textPrimary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.book.title), \(Int(entry.percentComplete * 100))% read")
    }
}

private enum ReadingNowPreviewFixtures {
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

    static func entry(_ title: String, percent: Double, author: String? = "Preview Author") -> ReadingNowEntry {
        let b = book(title, author: author)
        let p = Position(
            id: UUID(),
            bookId: b.id,
            locator: "{\"page\":1}",
            percentComplete: percent,
            updatedAt: Date()
        )
        return ReadingNowEntry(book: b, position: p)
    }

    static let mixedEntries: [ReadingNowEntry] = [
        entry("Project Hail Mary", percent: 0.42, author: "Andy Weir"),
        entry("Sapiens", percent: 0.18, author: "Yuval Noah Harari"),
        entry("The Pragmatic Programmer", percent: 0.77, author: "Hunt and Thomas"),
        entry("Norwegian Wood", percent: 0.05, author: "Haruki Murakami"),
        entry("Designing Data-Intensive Applications", percent: 0.61, author: "Martin Kleppmann"),
    ]
}

#Preview("Reading Now - populated") {
    ReadingNowShelf(
        entries: ReadingNowPreviewFixtures.mixedEntries,
        coverURL: { _ in nil },
        onOpen: { _ in }
    )
    .background(RishiColor.background)
}

#Preview("Reading Now - single entry") {
    ReadingNowShelf(
        entries: [ReadingNowPreviewFixtures.entry("Dune", percent: 0.33, author: "Frank Herbert")],
        coverURL: { _ in nil },
        onOpen: { _ in }
    )
    .background(RishiColor.background)
}

#Preview("Reading Now - dark mode") {
    ReadingNowShelf(
        entries: ReadingNowPreviewFixtures.mixedEntries,
        coverURL: { _ in nil },
        onOpen: { _ in }
    )
    .background(RishiColor.background)
    .preferredColorScheme(.dark)
}
