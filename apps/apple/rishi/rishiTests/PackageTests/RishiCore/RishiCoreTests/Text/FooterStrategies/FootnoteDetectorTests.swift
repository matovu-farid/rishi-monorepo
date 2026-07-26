@testable import rishi
//
//  FootnoteDetectorTests.swift
//  RishiCoreTests (Phase 27 plan 27-05)
//
//  Swift Testing parity coverage for
//  `FootnoteDetector.detect(page:options:)` — direct port of electron
//  `apps/rishi-electron/src/renderer/src/components/pdf/utils/
//  detectFootnoteItems.ts`. Mirrors the 10-case test plan from
//  27-05-PLAN.md so any drift in the small-font + oversized-gap heuristic
//  surfaces immediately.
//

import Testing
import Foundation
import CoreGraphics


struct FootnoteDetectorTests {

    // MARK: - Helpers

    /// Standard page frame. Origin bottom-left, height 800, width 600.
    private static let pageFrame = CGRect(x: 0, y: 0, width: 600, height: 800)

    /// Build a `TextItem` at a given y baseline and font size.
    /// `text` defaults to a non-empty string so `hasText` is true.
    private func item(
        _ text: String = "line",
        y: CGFloat,
        height: CGFloat,
        x: CGFloat = 50
    ) -> TextItem {
        return TextItem(
            text: text,
            frame: CGRect(x: x, y: y, width: 200, height: height),
            fontSize: height
        )
    }

    private func page(_ items: [TextItem], frame: CGRect = pageFrame, pageIndex: Int = 0) -> PageText {
        return PageText(pageIndex: pageIndex, frame: frame, items: items)
    }

    // MARK: - 1. Plain body, no footnote

    @Test
    func returns_empty_for_uniform_body_with_no_footnote() {
        let items: [TextItem] = (0..<8).map { i in
            item("body line \(i)", y: 700 - CGFloat(i) * 20, height: 12)
        }
        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 2. Classic footnote — small font + big gap

    @Test
    func flags_classic_footnote_with_small_font_and_oversized_gap() {
        // 10 body items at y in [200..500] (descending), height 12.
        // 3 footnote items at y in [50..80], height 9 (9/12 = 0.75 < 0.85).
        // Body bottom = 200; footnote top = 80; gap = 120 >= 1.5 * 12 = 18.
        var items: [TextItem] = []
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        // body items now end at y = 500 - 9*30 = 230. Adjust:
        // Let's recompute. Indices 0..9 produces y from 500 down to 500-270=230.
        // Smallest body y = 230. Footnotes at y 50, 65, 80 — all < 230.
        // Gap = 230 - 80 = 150 >= 18. Good.
        items.append(item("note a", y: 80, height: 9))
        items.append(item("note b", y: 65, height: 9))
        items.append(item("note c", y: 50, height: 9))

        let result = FootnoteDetector.detect(page: page(items))
        // Three footnote items are at indices 10, 11, 12.
        #expect(result == Set([10, 11, 12]))
    }

    // MARK: - 3. Too-small gap — no flag

    @Test
    func does_not_flag_small_font_items_when_gap_below_threshold() {
        // Body items at y in 500, 480, ..., 320 (spacing 20 < clusterGap 24).
        // bodyBottomY = 320. Put footnote items just 10 units below
        // (gap = 10 < minGap = 18). Expect empty.
        var items: [TextItem] = []
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        items.append(item("note", y: 310, height: 9))
        items.append(item("note", y: 308, height: 9))

        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 4. Same-font item below body — page number — not flagged

    @Test
    func does_not_flag_same_font_page_number_below_body() {
        var items: [TextItem] = []
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        // "Page 47" with the SAME font size as body, well below the body
        // cluster. Font-size signal fails, so not flagged.
        items.append(item("Page 47", y: 50, height: 12))

        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 5. Mid-page superscript — small font INSIDE body — not flagged

    @Test
    func does_not_flag_mid_page_superscript_inside_body_cluster() {
        var items: [TextItem] = []
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        // Small superscript at y = 400 — inside the body cluster (body
        // bottom ~ 230). y is NOT < bodyBottomY, so not flagged.
        items.append(item("¹", y: 400, height: 8))

        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 6. Multi-cluster body — largest cluster defines bodyBottomY

    @Test
    func uses_largest_cluster_bottom_when_multiple_body_clusters_present() {
        // Body cluster A: 3 items at y = 500, 480, 460 (top of page).
        // Body cluster B (LARGEST): 6 items at y = 300, 280, 260, 240, 220, 200.
        // Gap between clusters: 460 - 300 = 160 > clusterGap (12*2=24).
        // bodyBottomY should be cluster B's bottom = 200.
        // Footnote: at y = 100, height 9. Gap = 200 - 100 = 100 >= 18. Should flag.
        var items: [TextItem] = []
        items.append(item("heading A1", y: 500, height: 12))
        items.append(item("heading A2", y: 480, height: 12))
        items.append(item("heading A3", y: 460, height: 12))
        items.append(item("body B1", y: 300, height: 12))
        items.append(item("body B2", y: 280, height: 12))
        items.append(item("body B3", y: 260, height: 12))
        items.append(item("body B4", y: 240, height: 12))
        items.append(item("body B5", y: 220, height: 12))
        items.append(item("body B6", y: 200, height: 12))
        items.append(item("note", y: 100, height: 9))

        let result = FootnoteDetector.detect(page: page(items))
        #expect(result == Set([9]))
    }

    // MARK: - 7. No body-sized items — empty

    @Test
    func returns_empty_when_no_body_sized_items_present() {
        // All items same small height — there's no body baseline; the
        // "below smallThreshold" filter catches NOTHING because every item
        // IS the body. Expect empty.
        let items: [TextItem] = [
            item("small a", y: 80, height: 9),
            item("small b", y: 65, height: 9),
            item("small c", y: 50, height: 9),
        ]
        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 8. NaN font sizes — guarded out

    @Test
    func handles_nan_font_sizes_without_crashing() {
        // Items with NaN fontSize are still added as entries (with height 0
        // because !isFinite). bodyHeights filter requires height > 0, so NaN
        // entries are skipped from the median. If ALL items are NaN-fonted,
        // bodyHeight is 0 and detector bails.
        let items: [TextItem] = [
            TextItem(
                text: "nan line a",
                frame: CGRect(x: 0, y: 500, width: 200, height: 12),
                fontSize: .nan
            ),
            TextItem(
                text: "nan line b",
                frame: CGRect(x: 0, y: 480, width: 200, height: 12),
                fontSize: .nan
            ),
        ]
        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    @Test
    func skips_items_with_nan_y_coordinate() {
        // An item with NaN y is filtered out by the isFinite guard. The
        // remaining items behave as in the empty/uniform case.
        let items: [TextItem] = [
            TextItem(
                text: "ghost",
                frame: CGRect(x: 0, y: CGFloat.nan, width: 200, height: 12),
                fontSize: 12
            )
        ]
        let result = FootnoteDetector.detect(page: page(items))
        #expect(result.isEmpty)
    }

    // MARK: - 9. Empty page

    @Test
    func returns_empty_for_empty_page() {
        let result = FootnoteDetector.detect(page: page([]))
        #expect(result.isEmpty)
    }

    // MARK: - 10. Options override — tighter ratio flags borderline items

    @Test
    func loosened_smallFontRatio_flags_borderline_items() {
        // Body at height 12, "borderline" notes at height 11 (11/12 ≈ 0.917).
        // Under default smallFontRatio = 0.85, threshold = 10.2 — items at
        // height 11 are NOT below threshold (they count as body-sized), so
        // bodyBottomY drops to include them and nothing is flagged.
        // Under smallFontRatio = 0.95, threshold = 11.4 — height-11 items
        // ARE below threshold and become candidates. With a big gap they
        // get flagged.
        var items: [TextItem] = []
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        // Smallest body y = 230. Notes at y = 100, 85 (gap 130 >> 18).
        items.append(item("borderline a", y: 100, height: 11))
        items.append(item("borderline b", y: 85, height: 11))

        let defaultResult = FootnoteDetector.detect(page: page(items))
        #expect(defaultResult.isEmpty)

        var opts = FootnoteDetectorOptions()
        opts.smallFontRatio = 0.95
        let loosened = FootnoteDetector.detect(page: page(items), options: opts)
        #expect(loosened == Set([10, 11]))
    }

    // MARK: - Bonus — whitespace-only items don't pollute bodyHeights

    @Test
    func whitespace_only_items_are_not_treated_as_body_text() {
        // A whitespace-only item with a wild "height" should NOT be in the
        // bodyHeights median. We construct a page where the whitespace
        // item's height is huge — if it leaked into the median, the
        // smallThreshold would lift past actual body height and break
        // detection. The classic footnote case must still flag.
        var items: [TextItem] = []
        // Whitespace-only "outlier" with height 100. hasText is false so it
        // is excluded from bodyHeights — median stays at 12.
        items.append(item("   ", y: 750, height: 100))
        for i in 0..<10 {
            items.append(item("body \(i)", y: 500 - CGFloat(i) * 20, height: 12))
        }
        items.append(item("note a", y: 80, height: 9))
        items.append(item("note b", y: 65, height: 9))

        let result = FootnoteDetector.detect(page: page(items))
        // Indices of footnote items are 11 and 12 (whitespace at 0, 10 body items at 1..10).
        #expect(result == Set([11, 12]))
    }
}
