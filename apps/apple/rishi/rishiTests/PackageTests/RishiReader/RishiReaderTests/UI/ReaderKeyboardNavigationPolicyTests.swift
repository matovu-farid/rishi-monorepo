@testable import rishi
#if canImport(UIKit)
import Testing
import ReadiumNavigator

@Suite("Reader keyboard navigation policy")
struct ReaderKeyboardNavigationPolicyTests {

    @Test("Only PDF readers expose PDF view modes")
    func pdfViewModeMenuVisibility() {
        #expect(ReaderKeyboardNavigationPolicy.showsPDFViewModeMenu(isPDF: true))
        #expect(!ReaderKeyboardNavigationPolicy.showsPDFViewModeMenu(isPDF: false))
    }

    @Test("EPUB left and right arrows request page navigation")
    func epubHorizontalArrowsNavigate() {
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowLeft,
            isPDF: false,
            pdfViewMode: .continuous
        ) == .pageBackward)
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowRight,
            isPDF: false,
            pdfViewMode: .continuous
        ) == .pageForward)
    }

    @Test("PDF paginated modes use left and right arrows")
    func paginatedPDFHorizontalArrowsNavigate() {
        for mode in [PDFViewModeSetting.singlePage, .twoPage] {
            #expect(ReaderKeyboardNavigationPolicy.action(
                for: .arrowLeft,
                isPDF: true,
                pdfViewMode: mode
            ) == .pageBackward)
            #expect(ReaderKeyboardNavigationPolicy.action(
                for: .arrowRight,
                isPDF: true,
                pdfViewMode: mode
            ) == .pageForward)
        }
    }

    @Test("PDF continuous mode scrolls vertically and consumes horizontal arrows")
    func continuousPDFArrowMapping() {
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowUp,
            isPDF: true,
            pdfViewMode: .continuous
        ) == .scrollUp)
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowDown,
            isPDF: true,
            pdfViewMode: .continuous
        ) == .scrollDown)
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowLeft,
            isPDF: true,
            pdfViewMode: .continuous
        ) == .consume)
        #expect(ReaderKeyboardNavigationPolicy.action(
            for: .arrowRight,
            isPDF: true,
            pdfViewMode: .automatic
        ) == .consume)
    }
}
#endif
