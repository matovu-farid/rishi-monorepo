@testable import rishi
import Testing
import CoreGraphics


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

    // MARK: - resolve(setting:isFullScreen:availableSize:) (Phase 31)

    @Test("explicit Single Page forces .singlePage regardless of size/full-screen")
    func explicitSinglePageForces() {
        let any = CGSize(width: 1200, height: 800)
        #expect(PDFReaderLayoutResolver.resolve(setting: .singlePage, isFullScreen: false, availableSize: any) == .singlePage)
        #expect(PDFReaderLayoutResolver.resolve(setting: .singlePage, isFullScreen: true, availableSize: any) == .singlePage)
    }

    @Test("explicit Continuous forces .singleFitWidth regardless of size/full-screen")
    func explicitContinuousForces() {
        let wide = CGSize(width: 2400, height: 1200)
        let narrow = CGSize(width: 400, height: 900)
        #expect(PDFReaderLayoutResolver.resolve(setting: .continuous, isFullScreen: false, availableSize: wide) == .singleFitWidth)
        #expect(PDFReaderLayoutResolver.resolve(setting: .continuous, isFullScreen: true, availableSize: narrow) == .singleFitWidth)
    }

    @Test("explicit Two Page forces .twoUpSpread regardless of size/full-screen")
    func explicitTwoPageForces() {
        let narrow = CGSize(width: 400, height: 900)
        #expect(PDFReaderLayoutResolver.resolve(setting: .twoPage, isFullScreen: false, availableSize: narrow) == .twoUpSpread)
        #expect(PDFReaderLayoutResolver.resolve(setting: .twoPage, isFullScreen: true, availableSize: narrow) == .twoUpSpread)
    }

    @Test("Automatic full-screen resolves to Two Page")
    func automaticFullScreenIsTwoUp() {
        let any = CGSize(width: 1200, height: 800)
        #expect(PDFReaderLayoutResolver.resolve(setting: .automatic, isFullScreen: true, availableSize: any) == .twoUpSpread)
    }

    @Test("Automatic windowed at ultra-wide STILL resolves to Continuous (LOCKED decision #1)")
    func automaticWideWindowedStaysContinuous() {
        #expect(
            PDFReaderLayoutResolver.resolve(
                setting: .automatic,
                isFullScreen: false,
                availableSize: CGSize(width: 2400, height: 1200)
            ) == .singleFitWidth
        )
    }

    @Test("Automatic windowed at narrow resolves to Continuous")
    func automaticNarrowWindowedIsContinuous() {
        #expect(
            PDFReaderLayoutResolver.resolve(
                setting: .automatic,
                isFullScreen: false,
                availableSize: CGSize(width: 600, height: 900)
            ) == .singleFitWidth
        )
    }

    // MARK: - fitWidthScaleFactor

    @Test("fit-width: 612pt page in 900pt viewport is ~1.47")
    func fitWidthNormalCase() {
        let factor = PDFReaderLayoutResolver.fitWidthScaleFactor(
            pageWidth: 612,
            availableWidth: 900
        )
        #expect(abs(factor - (900.0 / 612.0)) < 0.0001)
    }

    @Test("fit-width: zero page width returns 1 (no crash, no zero)")
    func fitWidthZeroPageWidth() {
        #expect(PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: 0, availableWidth: 900) == 1)
    }

    @Test("fit-width: negative page width returns 1")
    func fitWidthNegativePageWidth() {
        #expect(PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: -10, availableWidth: 900) == 1)
    }

    @Test("fit-width: zero available width returns 1")
    func fitWidthZeroAvailableWidth() {
        #expect(PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: 612, availableWidth: 0) == 1)
    }

    @Test("fit-width: negative available width returns 1")
    func fitWidthNegativeAvailableWidth() {
        #expect(PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: 612, availableWidth: -5) == 1)
    }

    @Test("fit-width: a wider viewport yields a larger factor for the same page")
    func fitWidthWiderViewportLargerFactor() {
        let narrow = PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: 612, availableWidth: 700)
        let wide = PDFReaderLayoutResolver.fitWidthScaleFactor(pageWidth: 612, availableWidth: 1200)
        #expect(wide > narrow)
    }

    // MARK: - isFullScreen size-proxy (Phase 31)

    @Test("scene width equal to screen width is full-screen")
    func sceneFillsScreenIsFullScreen() {
        #expect(
            PDFReaderLayoutResolver.isFullScreen(
                sceneSize: CGSize(width: 1512, height: 982),
                screenSize: CGSize(width: 1512, height: 982)
            )
        )
    }

    @Test("clearly smaller scene is not full-screen")
    func smallSceneIsNotFullScreen() {
        #expect(
            !PDFReaderLayoutResolver.isFullScreen(
                sceneSize: CGSize(width: 900, height: 700),
                screenSize: CGSize(width: 1512, height: 982)
            )
        )
    }

    @Test("gap exactly at tolerance is full-screen; above tolerance is not")
    func toleranceEdge() {
        let screen = CGSize(width: 1512, height: 982)
        // gap == tolerance (default 4) -> true
        #expect(
            PDFReaderLayoutResolver.isFullScreen(
                sceneSize: CGSize(width: 1508, height: 982),
                screenSize: screen
            )
        )
        // gap == 5 (> tolerance 4) -> false
        #expect(
            !PDFReaderLayoutResolver.isFullScreen(
                sceneSize: CGSize(width: 1507, height: 982),
                screenSize: screen
            )
        )
    }
}
