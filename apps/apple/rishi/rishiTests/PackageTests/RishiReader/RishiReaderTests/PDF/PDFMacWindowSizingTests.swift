@testable import rishi
import Testing
import CoreGraphics


/// Unit coverage for the Phase 30 plan 30-05 Mac window minimum-width clamp.
///
/// The `clampedMinimum` helper is pure (`max()` semantics) so the floor logic is
/// verified on the dev host without a live `UIWindowScene`. Those cases are
/// `#if targetEnvironment(macCatalyst)`-gated because `PDFMacWindowSizing` only
/// exists on Catalyst; the iOS test host still compiles (the gated cases simply
/// drop out).
///
/// The shared-constant invariant (`PDFReaderLayoutMetrics.minPageWidth == 440`)
/// stays UNGATED — the metrics type is platform-agnostic — so a regression that
/// desyncs the resolver breakpoint from the window clamp fails here regardless
/// of platform.
@Suite("PDFMacWindowSizing")
struct PDFMacWindowSizingTests {

    @Test("min-page-width is the locked single source of truth (440)")
    func minPageWidthIsLocked() {
        // Both the resolver breakpoint and the window clamp default to this
        // constant; locking it here catches any desync at its source.
        #expect(PDFReaderLayoutMetrics.minPageWidth == 440)
        #expect(PDFReaderLayoutMetrics.minWindowHeight == 480)
    }

    #if targetEnvironment(macCatalyst)
    @Test("clampedMinimum raises a smaller existing minimum up to the floor")
    func clampRaisesSmallerMinimum() {
        let result = PDFMacWindowSizing.clampedMinimum(
            existing: CGSize(width: 100, height: 100),
            minWidth: 440,
            minHeight: 480
        )
        #expect(result == CGSize(width: 440, height: 480))
    }

    @Test("clampedMinimum keeps a larger existing minimum (never shrinks)")
    func clampKeepsLargerMinimum() {
        let result = PDFMacWindowSizing.clampedMinimum(
            existing: CGSize(width: 900, height: 700),
            minWidth: 440,
            minHeight: 480
        )
        #expect(result == CGSize(width: 900, height: 700))
    }

    @Test("clampedMinimum clamps each dimension independently")
    func clampPerDimension() {
        let result = PDFMacWindowSizing.clampedMinimum(
            existing: CGSize(width: 900, height: 100),
            minWidth: 440,
            minHeight: 480
        )
        #expect(result == CGSize(width: 900, height: 480))
    }
    #endif
}
