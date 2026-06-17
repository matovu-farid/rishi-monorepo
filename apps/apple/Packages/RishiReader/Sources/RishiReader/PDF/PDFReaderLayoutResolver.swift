import CoreGraphics

/// Layout mode for the Mac PDF reader. Mode A keeps a single page at a readable
/// width with vertical scrolling and overscroll page turns; Mode B shows a
/// two-page spread when the window is wide enough to hold both pages.
public enum PDFReaderLayoutMode: Sendable, Equatable {
    case singlePage       // Phase 31: pre-Phase-30 horizontal page-turn (usePageViewController)
    case singleFitWidth   // Mode A / Continuous: one page, fit width, vertical scroll, overscroll-turn
    case twoUpSpread      // Mode B / Two Page: two pages, fit height, swipe = one spread
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

/// Pure, preprocessor-free decision seam for the Mac PDF reader. Kept free of PDFKit
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

    /// Maps the user-facing ``PDFViewModeSetting`` to the effective
    /// ``PDFReaderLayoutMode``. Explicit cases FORCE their layout regardless of
    /// window size/state (LOCKED); `.automatic` resolves by full-screen state.
    ///
    /// Pre-resolved decision #1 (LOCKED): when windowed, Automatic is ALWAYS
    /// Continuous (`.singleFitWidth`) — even an ultra-wide windowed window does
    /// NOT get a Two Page spread. Two Page is reserved for full-screen. The
    /// `minPageWidth`/`gutter` params are retained for signature stability and a
    /// possible future width-breakpoint decay path, but the strict windowed
    /// branch deliberately does not consult them.
    public static func resolve(
        setting: PDFViewModeSetting,
        isFullScreen: Bool,
        availableSize: CGSize,
        minPageWidth: CGFloat = PDFReaderLayoutMetrics.minPageWidth,
        gutter: CGFloat = PDFReaderLayoutMetrics.gutter
    ) -> PDFReaderLayoutMode {
        switch setting {
        case .singlePage: return .singlePage
        case .continuous: return .singleFitWidth
        case .twoPage:    return .twoUpSpread
        case .automatic:
            // LOCKED decision #1: full-screen -> Two Page, windowed -> Continuous.
            return isFullScreen ? .twoUpSpread : .singleFitWidth
        }
    }

    /// Pure size-proxy: treat the scene as full-screen when it effectively fills
    /// the screen width. No clean public Catalyst full-screen API exists
    /// (31-RESEARCH.md Q3), so this is the documented fallback. Host-testable;
    /// the impure `connectedScenes` scene read lands in Wave 3 and consumes this.
    public static func isFullScreen(
        sceneSize: CGSize,
        screenSize: CGSize,
        tolerance: CGFloat = 4
    ) -> Bool {
        screenSize.width - sceneSize.width <= tolerance
    }

    /// Fit-to-WIDTH scale factor for a single PDF page: the multiplier that
    /// makes the page exactly fill the available viewport width (so the page
    /// overflows vertically and the user scrolls within it). PDFKit has no
    /// built-in fit-width, so the Mac Continuous (Mode A) path computes it here.
    /// Guarded: a non-positive `pageWidth` or `availableWidth` returns 1 so the
    /// caller never applies a zero/NaN scale (no crash, no collapsed page).
    public static func fitWidthScaleFactor(pageWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard pageWidth > 0, availableWidth > 0 else { return 1 }
        return availableWidth / pageWidth
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
