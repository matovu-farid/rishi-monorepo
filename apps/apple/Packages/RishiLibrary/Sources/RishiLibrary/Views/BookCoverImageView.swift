import SwiftUI
import RishiCore
import RishiUIKit

/// Renders a book cover. Falls back to a tokenized accent gradient with the
/// title painted on top when no cover image is available on disk.
///
/// ALL visuals come from `RishiColor` / `RishiTypography` / `RishiSpacing` /
/// `RishiRadius` tokens — no inline hex, RGB literals, or fixed font sizes.
public struct BookCoverImageView: View {
    public let book: Book
    public let coverURL: URL?
    public let cornerRadius: CGFloat

    public init(book: Book,
                coverURL: URL?,
                cornerRadius: CGFloat = RishiRadius.medium) {
        self.book = book
        self.coverURL = coverURL
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let url = coverURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        gradientFallback
                    }
                }
            } else {
                gradientFallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(RishiColor.divider, lineWidth: 1)
        )
        // Cover art is decorative — the grid cell already carries a
        // `"<title> by <author>"` accessibility label. Hiding the cover
        // keeps VoiceOver from saying "Image" before announcing the row.
        .accessibilityHidden(true)
    }

    private var gradientFallback: some View {
        ZStack {
            LinearGradient(
                colors: [RishiColor.accent, RishiColor.accentMuted],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(book.title)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textPrimary)
                .multilineTextAlignment(.center)
                .padding(RishiSpacing.s)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
        }
    }
}
