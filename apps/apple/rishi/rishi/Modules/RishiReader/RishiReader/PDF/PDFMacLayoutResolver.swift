#if canImport(UIKit)
import UIKit
import CoreGraphics

/// Phase 34 Plan 34-02 (SRP P0) — extracts the Mac-only full-screen scene probe
/// and layout-mode resolution out of `PDFReaderScreen`'s `View` body.
///
/// Previously the screen exposed two computed properties — `isWindowFullScreen`
/// (an IMPURE `UIApplication.shared.connectedScenes` read) and
/// `resolvedLayoutMode` — directly inside the `View` struct. This helper keeps
/// the thin impure scene read in ONE place and delegates ALL comparison /
/// resolution math to the pure ``PDFReaderLayoutResolver``, so the view just
/// asks for a resolved ``PDFReaderLayoutMode`` value.
///
/// `@MainActor` because `UIApplication.shared.connectedScenes` is main-actor
/// isolated. The math it calls (`PDFReaderLayoutResolver`) is pure/`nonisolated`.
///
/// iOS parity: on iOS the screen never consults `pdfViewMode` — ``PDFReaderView``'s
/// iOS `#else` block ignores `layoutMode` entirely, so the resolved value is
/// inert there and the iOS render path stays byte-identical (Phase 30/31).
@MainActor
public struct PDFMacLayoutResolver {

    /// Mac-only full-screen proxy. No clean public Catalyst full-screen API
    /// exists (31-RESEARCH.md Q3), so the scene is treated as full-screen when
    /// it effectively fills the screen width. The impure `connectedScenes`
    /// read is kept thin; the comparison is the pure
    /// ``PDFReaderLayoutResolver/isFullScreen(sceneSize:screenSize:tolerance:)``.
    /// `readerAreaSize` is the live page-area size so it re-evaluates on
    /// resize / full-screen toggle.
    public static func isWindowFullScreen(readerAreaSize: CGSize) -> Bool {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            return PDFReaderLayoutResolver.isFullScreen(
                sceneSize: readerAreaSize,
                screenSize: windowScene.screen.bounds.size
            )
        }
        return false
        #else
        return false
        #endif
    }

    /// Resolved Mac PDF layout mode. The Mac branch routes the user's live
    /// `pdfViewMode` setting + the full-screen proxy through
    /// ``PDFReaderLayoutResolver/resolve(setting:isFullScreen:availableSize:minPageWidth:gutter:)``.
    /// The iOS branch resolves with `.automatic` / not-full-screen so the call
    /// site stays unbranched and the iOS rendering path is byte-identical to
    /// Phase 30 (PDFReaderView's iOS `#else` ignores `layoutMode`).
    public static func resolvedLayoutMode(
        pdfViewMode: PDFViewModeSetting,
        readerAreaSize: CGSize
    ) -> PDFReaderLayoutMode {
        #if targetEnvironment(macCatalyst)
        return PDFReaderLayoutResolver.resolve(
            setting: pdfViewMode,
            isFullScreen: isWindowFullScreen(readerAreaSize: readerAreaSize),
            availableSize: readerAreaSize
        )
        #else
        return PDFReaderLayoutResolver.resolve(
            setting: .automatic,
            isFullScreen: false,
            availableSize: readerAreaSize
        )
        #endif
    }
}
#endif
