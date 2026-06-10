import SwiftUI
import RishiUIKit
import RishiCore

#if canImport(UIKit)
import UIKit

/// SwiftUI overlay that draws tinted rectangles for saved highlights on top
/// of the currently visible PDF page.
///
/// Mounted as a sibling of `PDFReaderView` inside the `PDFReaderScreen`
/// `ZStack` (plan 05-06 Task 5). Receives:
///   - `highlights` — the filtered list (typically
///     `viewModel.highlightsForCurrentPage`).
///   - `mapRect` — a closure that converts a single PDF user-space `CGRect`
///     into the overlay's local view-space. The screen wires this from the
///     `PDFView` coordinator using `PDFView.convert(_:to:)` so the rects
///     follow scroll/zoom.
///
/// The overlay is non-interactive (`allowsHitTesting(false)`) so the
/// underlying PDFView still receives taps for chrome toggle + selection.
/// Hidden from accessibility — saved highlights are surfaced via the
/// highlights sheet (plan 05-07), not the page overlay.
public struct PDFHighlightOverlay: View {

    public let highlights: [Highlight]
    public let mapRect: (CGRect) -> CGRect

    public init(highlights: [Highlight], mapRect: @escaping (CGRect) -> CGRect) {
        self.highlights = highlights
        self.mapRect = mapRect
    }

    public var body: some View {
        Canvas { context, _ in
            for hl in highlights {
                guard let locator = try? PDFHighlightLocator.decode(jsonString: hl.locatorStart)
                else { continue }
                let color = hl.color
                for rect in locator.rects {
                    let mapped = mapRect(rect)
                    context.fill(
                        Path(mapped),
                        with: .color(color.swiftUIColor.opacity(color.pageOverlayOpacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
