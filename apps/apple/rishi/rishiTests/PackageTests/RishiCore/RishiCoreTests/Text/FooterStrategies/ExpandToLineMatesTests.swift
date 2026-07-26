@testable import rishi
//
//  ExpandToLineMatesTests.swift
//  RishiCoreTests (Phase 27 plan 27-05 — supplemental)
//
//  Swift Testing parity coverage for `ExpandToLineMates.expand`. Port of
//  electron `apps/rishi-electron/src/renderer/src/components/pdf/utils/
//  footerStrategies/expandToLineMates.ts`.
//
//  NOTE: PDFLayoutExtractor (Phase 27-01) emits one `TextItem` per LINE
//  (via PDFKit `selectionsByLine`). In practice, baseline-mates collapse
//  into a single item before this post-processor sees them, so on the
//  Apple side this function is usually a no-op. The tests construct
//  synthetic multi-item-per-line pages to verify the algorithm is still
//  correct when callers feed it finer-grained data.
//

import Testing
import Foundation
import CoreGraphics


struct ExpandToLineMatesTests {

    private func item(
        _ text: String = "x",
        y: CGFloat,
        x: CGFloat = 50,
        width: CGFloat = 50,
        height: CGFloat = 12
    ) -> TextItem {
        return TextItem(
            text: text,
            frame: CGRect(x: x, y: y, width: width, height: height),
            fontSize: height
        )
    }

    // MARK: - 1. Single flagged item pulls in baseline-mate within tolerance

    @Test
    func expands_to_baseline_mate_within_tolerance() {
        // Two items with y = 100 and y = 100.5 — within default tolerance 1.0.
        let items = [
            item("flagged", y: 100, x: 0),
            item("mate", y: 100.5, x: 60),
            item("body", y: 400, x: 0),
        ]
        let flagged: Set<Int> = [0]
        let result = ExpandToLineMates.expand(flagged: flagged, in: items)
        #expect(result.contains(0))
        #expect(result.contains(1))
        #expect(!result.contains(2))
    }

    // MARK: - 2. Two distinct lines, each independently expanded

    @Test
    func handles_multiple_independent_baselines() {
        // Line A: items 0, 1 at y = 100 (flagged via 0).
        // Line B: items 2, 3 at y = 200 (flagged via 3).
        // Body item 4 at y = 500 — should NOT be flagged.
        let items = [
            item("a-flag", y: 100, x: 0),
            item("a-mate", y: 100, x: 60),
            item("b-mate", y: 200, x: 0),
            item("b-flag", y: 200, x: 60),
            item("body", y: 500, x: 0),
        ]
        let flagged: Set<Int> = [0, 3]
        let result = ExpandToLineMates.expand(flagged: flagged, in: items)
        #expect(result == Set([0, 1, 2, 3]))
    }

    // MARK: - 3. Items outside tolerance are not pulled in

    @Test
    func does_not_pull_in_items_outside_tolerance() {
        // Flagged at y=100. "Mate" at y=102 — outside default tolerance 1.0.
        let items = [
            item("flag", y: 100, x: 0),
            item("nope", y: 102, x: 60),
        ]
        let flagged: Set<Int> = [0]
        let result = ExpandToLineMates.expand(flagged: flagged, in: items)
        #expect(result == Set([0]))
    }

    // MARK: - 4. Custom tolerance broadens the baseline window

    @Test
    func custom_tolerance_widens_baseline_window() {
        // y=100 (flagged) and y=102 (mate). Tolerance 1.0 misses; 2.5 catches.
        let items = [
            item("flag", y: 100, x: 0),
            item("mate", y: 102, x: 60),
        ]
        let flagged: Set<Int> = [0]
        let tight = ExpandToLineMates.expand(flagged: flagged, in: items, baselineTolerance: 1.0)
        #expect(tight == Set([0]))
        let loose = ExpandToLineMates.expand(flagged: flagged, in: items, baselineTolerance: 2.5)
        #expect(loose == Set([0, 1]))
    }

    // MARK: - 5. Empty flagged set yields empty result

    @Test
    func returns_empty_for_empty_flagged_set() {
        let items = [
            item("a", y: 100, x: 0),
            item("b", y: 100, x: 60),
        ]
        let result = ExpandToLineMates.expand(flagged: [], in: items)
        #expect(result.isEmpty)
    }

    // MARK: - 6. Empty items yields empty result

    @Test
    func returns_empty_when_items_array_empty() {
        let result = ExpandToLineMates.expand(flagged: [], in: [])
        #expect(result.isEmpty)
    }

    // MARK: - 7. Idempotent — running twice produces the same result

    @Test
    func is_idempotent() {
        let items = [
            item("flag", y: 100, x: 0),
            item("mate", y: 100.5, x: 60),
            item("body", y: 400, x: 0),
        ]
        let flagged: Set<Int> = [0]
        let once = ExpandToLineMates.expand(flagged: flagged, in: items)
        let twice = ExpandToLineMates.expand(flagged: once, in: items)
        #expect(once == twice)
    }

    // MARK: - 8. Items with non-finite y are skipped

    @Test
    func skips_items_with_non_finite_y() {
        let items: [TextItem] = [
            item("flag", y: 100, x: 0),
            TextItem(
                text: "ghost",
                frame: CGRect(x: 50, y: CGFloat.nan, width: 50, height: 12),
                fontSize: 12
            ),
        ]
        let flagged: Set<Int> = [0]
        let result = ExpandToLineMates.expand(flagged: flagged, in: items)
        #expect(result == Set([0]))
    }

    // MARK: - 9. Flagged index out of bounds is silently ignored

    @Test
    func ignores_out_of_bounds_flagged_indices() {
        let items = [
            item("a", y: 100, x: 0),
        ]
        let flagged: Set<Int> = [0, 5, 99]
        let result = ExpandToLineMates.expand(flagged: flagged, in: items)
        // Index 0 remains; ghost indices passed through unchanged.
        #expect(result.contains(0))
    }

    // MARK: - Mask-overload (whole-document)

    private func page(
        _ pageIndex: Int,
        items: [TextItem],
        height: CGFloat = 792
    ) -> PageText {
        PageText(
            pageIndex: pageIndex,
            frame: CGRect(x: 0, y: 0, width: 612, height: height),
            items: items
        )
    }

    @Test
    func mask_overload_empty_input_returns_empty() {
        let result = ExpandToLineMates.expand(
            mask: [:],
            pages: [page(0, items: [item("x", y: 100)])],
            yBinPct: 0.02
        )
        #expect(result.isEmpty)
    }

    @Test
    func mask_overload_widens_to_y_bin_siblings_on_each_page() {
        // page 0: three items at near-identical y; mask flags index 0 -> all flagged.
        // tolerance = 792 * 0.02 = 15.84, items within ±1 are well inside.
        let p0 = page(0, items: [
            item("a", y: 100, x: 0),
            item("b", y: 100.5, x: 100),
            item("c", y: 99.5, x: 200),
        ])
        let mask: LayoutFooterMask = [0: Set([0])]
        let result = ExpandToLineMates.expand(mask: mask, pages: [p0], yBinPct: 0.02)
        #expect(result[0] == Set([0, 1, 2]))
    }

    @Test
    func mask_overload_yBinPct_zero_short_circuits() {
        let p0 = page(0, items: [
            item("a", y: 100, x: 0),
            item("b", y: 100.5, x: 100),
        ])
        let mask: LayoutFooterMask = [0: Set([0])]
        let result = ExpandToLineMates.expand(mask: mask, pages: [p0], yBinPct: 0)
        // No expansion -> verbatim input.
        #expect(result[0] == Set([0]))
    }

    @Test
    func mask_overload_pages_at_different_y_bins_not_pulled_in() {
        let p0 = page(0, items: [
            item("a", y: 100, x: 0),
            item("b", y: 500, x: 100),  // far away
        ])
        let mask: LayoutFooterMask = [0: Set([0])]
        let result = ExpandToLineMates.expand(mask: mask, pages: [p0], yBinPct: 0.02)
        #expect(result[0] == Set([0]))
    }

    @Test
    func mask_overload_pages_not_in_mask_are_absent_from_output() {
        let p0 = page(0, items: [item("a", y: 100, x: 0)])
        let p1 = page(1, items: [item("b", y: 200, x: 0)])
        let mask: LayoutFooterMask = [0: Set([0])]
        let result = ExpandToLineMates.expand(mask: mask, pages: [p0, p1], yBinPct: 0.02)
        #expect(result[0] == Set([0]))
        #expect(result[1] == nil, "Page 1 was not in the input mask; must not appear in output")
    }
}
