import SwiftUI



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

private func previewHighlight(color: HighlightColor, rects: [CGRect], text: String) -> Highlight {
    let locator = PDFHighlightLocator(page: 0, rects: rects, text: text)
    let json = (try? locator.encodedJSONString()) ?? ""
    return Highlight(
        bookId: UUID(),
        locatorStart: json,
        locatorEnd: json,
        color: color,
        text: text
    )
}

#Preview("Single highlight") {
    PDFHighlightOverlay(
        highlights: [
            previewHighlight(
                color: .yellow,
                rects: [CGRect(x: 40, y: 80, width: 280, height: 22)],
                text: "Alice was beginning to get very tired"
            )
        ],
        mapRect: { $0 }
    )
    .frame(width: 360, height: 480)
    .background(RishiColor.readerBackgroundLight)
}

#Preview("All four colors") {
    PDFHighlightOverlay(
        highlights: [
            previewHighlight(color: .yellow, rects: [CGRect(x: 30, y: 60, width: 300, height: 20)], text: "Yellow"),
            previewHighlight(color: .green,  rects: [CGRect(x: 30, y: 110, width: 240, height: 20)], text: "Green"),
            previewHighlight(color: .blue,   rects: [CGRect(x: 30, y: 160, width: 280, height: 20)], text: "Blue"),
            previewHighlight(color: .pink,   rects: [CGRect(x: 30, y: 210, width: 200, height: 20)], text: "Pink")
        ],
        mapRect: { $0 }
    )
    .frame(width: 360, height: 320)
    .background(RishiColor.readerBackgroundSepia)
}

#Preview("Multi-line highlight") {
    PDFHighlightOverlay(
        highlights: [
            previewHighlight(
                color: .yellow,
                rects: [
                    CGRect(x: 40, y: 80, width: 300, height: 22),
                    CGRect(x: 30, y: 108, width: 320, height: 22),
                    CGRect(x: 30, y: 136, width: 180, height: 22)
                ],
                text: "A paragraph spanning three lines."
            )
        ],
        mapRect: { $0 }
    )
    .frame(width: 360, height: 320)
    .background(RishiColor.readerBackgroundDark)
}
#endif
