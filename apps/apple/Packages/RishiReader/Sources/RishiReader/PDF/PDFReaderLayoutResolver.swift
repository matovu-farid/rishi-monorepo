import CoreGraphics

/// Layout mode for the Mac PDF reader. Mode A keeps a single page at a readable
/// width with vertical scrolling and overscroll page turns; Mode B shows a
/// two-page spread when the window is wide enough to hold both pages.
public enum PDFReaderLayoutMode: Sendable, Equatable {
    case singleFitWidth   // Mode A: one page, fit width, vertical scroll, overscroll-turn
    case twoUpSpread      // Mode B: two pages, fit height, swipe = one spread
}

/// Single source of truth for the PDF reader layout metrics. The minimum page
/// width is consumed both by `PDFReaderLayoutResolver.mode` (as the default
/// breakpoint argument) and, in plan 30-05, by the window
/// `sizeRestrictions.minimumSize` clamp — sharing this constant guarantees the
/// breakpoint and the window floor can never desync.
public enum PDFReaderLayoutMetrics {
    /// Minimum readable on-screen width for a single PDF page.
    public static let minPageWidth: CGFloat = 440
    /// Gutter between the two pages of a spread.
    public static let gutter: CGFloat = 24
    /// Minimum usable window height for the reader.
    public static let minWindowHeight: CGFloat = 480
}

/// Pure, `#if`-free decision seam for the Mac PDF reader. Kept free of PDFKit
/// and UIKit so the breakpoint and spread mapping are fully unit-testable on the
/// dev host; UIKit-touching plans (30-03, 30-05) only READ its results.
public enum PDFReaderLayoutResolver {
    /// Picks single fit-to-width vs two-up spread. Two-up engages only when the
    /// available width can hold two pages at >= the minimum page width plus a
    /// gutter.
    public static func mode(
        availableSize: CGSize,
        minPageWidth: CGFloat = PDFReaderLayoutMetrics.minPageWidth,
        gutter: CGFloat = PDFReaderLayoutMetrics.gutter
    ) -> PDFReaderLayoutMode {
        let twoPageWidth = (minPageWidth * 2) + gutter
        return availableSize.width >= twoPageWidth ? .twoUpSpread : .singleFitWidth
    }

    /// Maps a single pageIndex to the LEFT page index of the spread it belongs
    /// to, used to preserve reading position when switching single <-> two-up
    /// (RESEARCH Pitfall 8). With `displaysAsBook`, page 1 (index 0) is a lone
    /// cover and subsequent pages pair as (2,3), (4,5), ...; otherwise pages
    /// pair as (1,2), (3,4), ... so the left page is the even index.
    public static func spreadLeftPage(forPageIndex pageIndex: Int, displaysAsBook: Bool) -> Int {
        if displaysAsBook {
            return pageIndex == 0 ? 0 : ((pageIndex - 1) & ~1) + 1
        } else {
            return pageIndex & ~1
        }
    }
}
