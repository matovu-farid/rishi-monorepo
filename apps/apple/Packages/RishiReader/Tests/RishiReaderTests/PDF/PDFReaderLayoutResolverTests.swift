import Testing
import CoreGraphics
@testable import RishiReader

/// Unit coverage for the pure PDF reader layout-decision seam: the A/B
/// breakpoint (single fit-to-width vs two-up spread) and the spread-left-page
/// mapping used to preserve reading position across a live mode switch
/// (RESEARCH Pitfall 8). The resolver is `#if`-free and platform-agnostic, so
/// the whole decision surface is verified here on the dev host.
@Suite("PDFReaderLayoutResolver")
struct PDFReaderLayoutResolverTests {

    // MARK: - mode breakpoint

    @Test("wide window resolves to two-up spread")
    func wideWindowIsTwoUp() {
        // 440*2 + 24 = 904 <= 1200
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 1200, height: 800),
            minPageWidth: 440
        )
        #expect(mode == .twoUpSpread)
    }

    @Test("narrow window resolves to single fit-to-width")
    func narrowWindowIsSingleFitWidth() {
        // 904 > 800
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 800, height: 800),
            minPageWidth: 440
        )
        #expect(mode == .singleFitWidth)
    }

    @Test("exactly at the breakpoint resolves to two-up")
    func exactlyAtBreakpointIsTwoUp() {
        // 440*2 + 24 = 904, available width == 904
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 904, height: 800),
            minPageWidth: 440,
            gutter: 24
        )
        #expect(mode == .twoUpSpread)
    }

    @Test("one point below the breakpoint resolves to single fit-to-width")
    func onePointBelowBreakpointIsSingleFitWidth() {
        let mode = PDFReaderLayoutResolver.mode(
            availableSize: CGSize(width: 903, height: 800),
            minPageWidth: 440,
            gutter: 24
        )
        #expect(mode == .singleFitWidth)
    }

    @Test("default minPageWidth comes from the shared metrics constant")
    func defaultMinPageWidthUsesMetrics() {
        let size = CGSize(width: 905, height: 800)
        let withDefault = PDFReaderLayoutResolver.mode(availableSize: size)
        let explicit = PDFReaderLayoutResolver.mode(
            availableSize: size,
            minPageWidth: PDFReaderLayoutMetrics.minPageWidth
        )
        #expect(withDefault == explicit)
    }

    // MARK: - spreadLeftPage (displaysAsBook == true)

    @Test("displaysAsBook: page 1 is the lone cover")
    func bookCoverIsLone() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 0, displaysAsBook: true) == 0)
    }

    @Test("displaysAsBook: index 1 is the left of spread (2,3)")
    func bookIndexOneIsLeft() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 1, displaysAsBook: true) == 1)
    }

    @Test("displaysAsBook: index 2 is the right of spread (2,3) -> left index 1")
    func bookIndexTwoMapsToLeftOne() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 2, displaysAsBook: true) == 1)
    }

    @Test("displaysAsBook: index 3 is the left of spread (4,5)")
    func bookIndexThreeIsLeft() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 3, displaysAsBook: true) == 3)
    }

    @Test("displaysAsBook: index 4 maps to left index 3")
    func bookIndexFourMapsToLeftThree() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 4, displaysAsBook: true) == 3)
    }

    // MARK: - spreadLeftPage (displaysAsBook == false)

    @Test("non-book: index 0 stays at 0 (pairs (1,2)(3,4) -> left even)")
    func nonBookIndexZero() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 0, displaysAsBook: false) == 0)
    }

    @Test("non-book: index 3 maps to left even index 2")
    func nonBookIndexThree() {
        #expect(PDFReaderLayoutResolver.spreadLeftPage(forPageIndex: 3, displaysAsBook: false) == 2)
    }
}
