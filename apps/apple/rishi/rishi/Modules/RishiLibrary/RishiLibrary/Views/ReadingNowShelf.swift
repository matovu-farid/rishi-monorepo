import SwiftUI



/// LIB-05: horizontal shelf showing in-progress books at the top of the
/// Library screen. Filtered by `ReadingNowEntry.isInProgress(_:)` upstream
/// (the view itself trusts the caller).
struct ReadingNowShelf: View {
    public let entries: [ReadingNowEntry]
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onBookVisibilityChange: (BookID, Bool) -> Void
    @State private var visibility = ReadingNowShelfVisibility()

    public init(entries: [ReadingNowEntry],
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void,
                onBookVisibilityChange: @escaping (BookID, Bool) -> Void = { _, _ in }) {
        self.entries = entries
        self.coverURL = coverURL
        self.onOpen = onOpen
        self.onBookVisibilityChange = onBookVisibilityChange
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
        // Card visibility is measured in the horizontal scroll view. Gate it
        // by the shelf's own visibility in the parent vertical scroll view.
        .onScrollVisibilityChange { isVisible in
            let update = visibility.setShelfVisible(isVisible)
            for bookID in update.visibleCardIDs {
                onBookVisibilityChange(bookID, update.shelfVisible)
            }
        }
        .onDisappear {
            for bookID in visibility.reset() {
                onBookVisibilityChange(bookID, false)
            }
        }
        .onChange(of: entries.map(\.id)) { _, bookIDs in
            for bookID in visibility.removeCards(notIn: Set(bookIDs)) {
                onBookVisibilityChange(bookID, false)
            }
        }
    }

    @ViewBuilder
    private func card(for entry: ReadingNowEntry) -> some View {
        let clampedPercent = min(max(entry.percentComplete, 0), 1)
        let author = entry.book.author.flatMap { $0.isEmpty ? nil : $0 }
        let accessibilityLabel = author.map {
            "\(entry.book.title), \($0), \(Int(clampedPercent * 100))% read"
        } ?? "\(entry.book.title), \(Int(clampedPercent * 100))% read"

        Button {
            onOpen(entry.book)
        } label: {
            VStack(alignment: .leading, spacing: RishiSpacing.xs) {
                BookCoverImageView(book: entry.book, coverURL: coverURL(entry.book))
                    .frame(width: 110, height: 165)

                Text(entry.book.title)
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 110, alignment: .leading)

                if let author = entry.book.author, !author.isEmpty {
                    Text(author)
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }

                ProgressView(value: clampedPercent)
                    .tint(RishiColor.accent)
                    .frame(width: 110)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onScrollVisibilityChange { isVisible in
            let isEffectivelyVisible = visibility.setCardVisible(entry.book.id, isVisible)
            onBookVisibilityChange(entry.book.id, isEffectivelyVisible)
        }
        .onDisappear {
            _ = visibility.setCardVisible(entry.book.id, false)
            onBookVisibilityChange(entry.book.id, false)
        }
    }
}

struct ReadingNowShelfVisibility: Equatable {
    private(set) var shelfIsVisible = false
    private(set) var visibleCardIDs: Set<BookID> = []

    mutating func setShelfVisible(_ visible: Bool) -> (shelfVisible: Bool, visibleCardIDs: Set<BookID>) {
        shelfIsVisible = visible
        return (visible, visibleCardIDs)
    }

    mutating func setCardVisible(_ bookID: BookID, _ visible: Bool) -> Bool {
        if visible { visibleCardIDs.insert(bookID) }
        else { visibleCardIDs.remove(bookID) }
        return shelfIsVisible && visible
    }

    mutating func reset() -> Set<BookID> {
        let ids = visibleCardIDs
        shelfIsVisible = false
        visibleCardIDs.removeAll()
        return ids
    }

    mutating func removeCards(notIn validBookIDs: Set<BookID>) -> Set<BookID> {
        let removed = visibleCardIDs.subtracting(validBookIDs)
        visibleCardIDs.subtract(removed)
        return removed
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
