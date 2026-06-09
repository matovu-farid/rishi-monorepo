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
