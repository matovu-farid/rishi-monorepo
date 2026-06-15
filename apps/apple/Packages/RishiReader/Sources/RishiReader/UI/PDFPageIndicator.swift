import SwiftUI
import RishiUIKit

/// Floating page indicator pill shown at the bottom of the PDF reader.
///
/// Pure value-driven view: callers pass current + total pages already
/// adjusted to 1-based human display. Surfaces a single combined
/// accessibility label so VoiceOver speaks "Page 4 of 200" instead of
/// reading the slash separator.
public struct PDFPageIndicator: View {
    public let currentPage: Int
    public let totalPages: Int

    public init(currentPage: Int, totalPages: Int) {
        self.currentPage = currentPage
        self.totalPages = totalPages
    }

    public var body: some View {
        Text("\(currentPage) of \(max(totalPages, 1))")
            .font(RishiTypography.caption)
            .foregroundStyle(RishiColor.textSecondary)
            .padding(.horizontal, RishiSpacing.m)
            .padding(.vertical, RishiSpacing.s)
            .background(
                Capsule().fill(RishiColor.surface.opacity(0.85))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(currentPage) of \(totalPages)")
            // Stable id so UI tests can read the live page number and assert
            // read-aloud crossed a page boundary (label carries "Page X of Y").
            .accessibilityIdentifier("reader.pdf.pageIndicator")
    }
}

#Preview("Mid-book") {
    PDFPageIndicator(currentPage: 42, totalPages: 320)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundLight)
}

#Preview("First page") {
    PDFPageIndicator(currentPage: 1, totalPages: 320)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundSepia)
}

#Preview("Single-page document") {
    PDFPageIndicator(currentPage: 1, totalPages: 1)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundDark)
}
