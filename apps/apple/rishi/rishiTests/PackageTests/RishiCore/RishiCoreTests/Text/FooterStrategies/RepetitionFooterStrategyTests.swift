@testable import rishi
//
//  RepetitionFooterStrategyTests.swift
//  RishiCoreTests (Phase 27 plan 27-04)
//
//  Swift Testing parity coverage for
//  `RepetitionFooterStrategy.detect(pages:options:)` — direct port of
//  electron `apps/rishi-electron/src/renderer/src/components/pdf/utils/
//  footerStrategies/repetitionStrategy.ts`. Mirrors the 10-case test plan
//  in 27-04-PLAN.md so any drift in y-bin x text-repetition semantics
//  surfaces immediately.
//

import Testing
import Foundation
import CoreGraphics


struct RepetitionFooterStrategyTests {

    // MARK: - Helpers

    /// Standard page frame used in tests. Origin bottom-left, height 800,
    /// width 600. With bottomBandPct = 0.25 the "bottom band" is the region
    /// where y < 200 (low y == near page origin == bottom of page).
    private static let pageFrame = CGRect(x: 0, y: 0, width: 600, height: 800)

    /// Build a `TextItem` at a given y baseline (PDF bottom-left coords).
    private func item(_ text: String, y: CGFloat, x: CGFloat = 50, height: CGFloat = 12) -> TextItem {
        return TextItem(
            text: text,
            frame: CGRect(x: x, y: y, width: 200, height: height),
            fontSize: height
        )
    }

    /// Build a `PageText` from a 0-based page index and a list of items.
    private func page(_ pageIndex: Int, _ items: [TextItem], frame: CGRect = pageFrame) -> PageText {
        return PageText(pageIndex: pageIndex, frame: frame, items: items)
    }

    /// Body items per page, at y values WELL above the 200 bottom-band
    /// cutoff. Distinct text per page so they never collapse into a shared
    /// normalised key.
    private func bodyItems(forPage p: Int) -> [TextItem] {
        return [
            item("body line alpha page \(p)", y: 700),
            item("body line bravo page \(p)", y: 600),
            item("body line charlie page \(p)", y: 500),
        ]
    }

    // MARK: - 1. Under-min-pages no-op

    @Test
    func returns_empty_when_pages_below_minPages_threshold() {
        let pages: [PageText] = (0..<5).map { p in
            page(p, bodyItems(forPage: p) + [item("Page \(p + 1)", y: 50)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 2. Repeating page number flagged

    @Test
    func repeating_page_number_at_bottom_band_is_flagged_on_every_page() {
        let pages: [PageText] = (0..<10).map { p in
            // Footer "Page N" at y=50 (bottom band). Body at y=700/600/500.
            page(p, bodyItems(forPage: p) + [item("Page \(p + 1)", y: 50)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for p in 0..<10 {
            // Footer is the 4th item (index 3) on each page.
            #expect(mask[p] == [3], "Page \(p) should drop only index 3")
        }
    }

    // MARK: - 3. Roman numeral repetition flagged

    @Test
    func roman_numeral_footer_at_bottom_band_is_flagged_on_every_page() {
        let romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
        let pages: [PageText] = (0..<10).map { p in
            page(p, bodyItems(forPage: p) + [item(romans[p], y: 50)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for p in 0..<10 {
            #expect(mask[p] == [3])
        }
    }

    // MARK: - 4. Bottom-band cutoff (out-of-band) not flagged

    @Test
    func page_number_above_bottom_band_is_not_flagged() {
        // y = 300 is above the 200 cutoff (with default 0.25 band on 800h).
        let pages: [PageText] = (0..<10).map { p in
            page(p, bodyItems(forPage: p) + [item("Page \(p + 1)", y: 300)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 5. maxCharsPerLine cap

    @Test
    func items_exceeding_maxCharsPerLine_are_excluded_from_detection() {
        let longText = String(repeating: "x", count: 260)
        let pages: [PageText] = (0..<10).map { p in
            page(p, bodyItems(forPage: p) + [item(longText, y: 50)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 6. maxFooterLines cap (keep lowest-y first)

    @Test
    func maxFooterLines_cap_keeps_only_lowest_y_items() {
        // Eight distinct footer lines per page, all in bottom band, at
        // distinct y bins (10, 30, 50, 70, 90, 110, 130, 150). Each line
        // recurs on every page so all pass the threshold. Default
        // maxFooterLines = 5 → only the 5 LOWEST-y items survive per page,
        // i.e. y = 10, 30, 50, 70, 90 — corresponding to items[3..<8] in
        // our construction (body is [0,1,2], footers appended below).
        let yValues: [CGFloat] = [10, 30, 50, 70, 90, 110, 130, 150]
        let pages: [PageText] = (0..<10).map { p in
            var items = bodyItems(forPage: p)
            for (i, y) in yValues.enumerated() {
                items.append(item("Footer slot \(i)", y: y))
            }
            return page(p, items)
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for p in 0..<10 {
            // Indices 3..<8 correspond to footer items with y = 10, 30, 50,
            // 70, 90 — the five lowest. Indices 8, 9, 10 (y = 110, 130, 150)
            // are higher and trimmed by the maxFooterLines cap.
            #expect(mask[p] == [3, 4, 5, 6, 7], "Page \(p) should keep five lowest-y footers")
        }
    }

    // MARK: - 7. Below threshold (no flagging)

    @Test
    func footer_appearing_below_threshold_on_two_of_ten_pages_returns_empty() {
        let pages: [PageText] = (0..<10).map { p in
            var items = bodyItems(forPage: p)
            if p < 2 {
                items.append(item("Page \(p + 1)", y: 50))
            }
            return page(p, items)
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 8. Sentinel: no-finite-y guard

    @Test
    func sentinel_when_all_items_have_non_finite_y_returns_empty() {
        let nan: CGFloat = .nan
        let pages: [PageText] = (0..<10).map { p in
            // Build items with .nan y for every TextItem.
            let body: [TextItem] = [
                item("body alpha \(p)", y: nan),
                item("body bravo \(p)", y: nan),
                item("body charlie \(p)", y: nan),
                item("Page \(p + 1)", y: nan),
            ]
            return page(p, body)
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 9. Multi-page running title (no digits)

    @Test
    func multi_page_running_title_at_same_y_bin_is_flagged() {
        let pages: [PageText] = (0..<10).map { p in
            page(p, bodyItems(forPage: p) + [item("Foo: A History", y: 50)])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for p in 0..<10 {
            #expect(mask[p] == [3])
        }
    }

    // MARK: - 10. Mixed-content page (only some pages flagged)

    @Test
    func only_pages_carrying_the_repeating_footer_appear_in_the_mask() {
        // 6 of 10 pages share footer "Page N" at y=50. The other 4 have no
        // footer at all. 6/10 = 0.60 >= 0.30 threshold, so the six pages
        // that DO carry the footer get flagged; the other four do not.
        let pages: [PageText] = (0..<10).map { p in
            var items = bodyItems(forPage: p)
            if p < 6 {
                items.append(item("Page \(p + 1)", y: 50))
            }
            return page(p, items)
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.count == 6)
        for p in 0..<6 {
            #expect(mask[p] == [3])
        }
        for p in 6..<10 {
            #expect(mask[p] == nil)
        }
    }

    // MARK: - Bonus: y-bin separation (port behavior)

    @Test
    func same_text_in_different_y_bins_is_not_collapsed_below_threshold() {
        // Same normalized footer text but each page puts it at a DIFFERENT
        // y bin (10, 30, 50, ..., 190). Default yBinPct = 0.02 * 800 = 16,
        // so y / 16 rounds to distinct bins (1, 2, 3, ..., 12). Each (bin,
        // text) key appears on exactly one page → all far below 30%
        // threshold → nothing flagged.
        let yValues: [CGFloat] = [10, 30, 50, 70, 90, 110, 130, 150, 170, 190]
        let pages: [PageText] = (0..<10).map { p in
            page(p, bodyItems(forPage: p) + [item("Page footer", y: yValues[p])])
        }
        let mask = RepetitionFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }
}
