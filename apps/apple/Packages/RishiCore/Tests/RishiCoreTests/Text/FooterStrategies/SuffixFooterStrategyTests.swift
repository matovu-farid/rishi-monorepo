//
//  SuffixFooterStrategyTests.swift
//  RishiCoreTests (Phase 27 plan 27-03)
//
//  Swift Testing parity coverage for `SuffixFooterStrategy.detect(pages:options:)`
//  — direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/findRepeatingPageSuffix.ts:28-95`. Mirrors the 12-case test plan
//  in 27-03-PLAN.md so any drift in suffix matching semantics surfaces
//  immediately.
//

import Testing
import Foundation
import RishiCore

struct SuffixFooterStrategyTests {

    // MARK: - Helpers

    /// Build a `PageParagraphs` from a one-based page number and an ordered
    /// list of paragraph text strings; the paragraph `.index` field is the
    /// 0-based reading-order slot.
    private func makePage(_ pageNumber: Int, _ texts: [String]) -> PageParagraphs {
        let paragraphs = texts.enumerated().map { (i, t) in
            PageParagraph(index: i, text: t)
        }
        return PageParagraphs(pageNumber: pageNumber, paragraphs: paragraphs)
    }

    /// Non-numeric per-page word tags so body paragraphs do not collapse
    /// to a shared normalized key (FooterTokens.normalize strips `\b\d+\b`,
    /// so "body 1" and "body 2" both normalize to "body __NUM__"). Using a
    /// non-numeric tag per page keeps body paragraphs genuinely distinct.
    private static let bodyTags: [String] = [
        "alpha", "bravo", "charlie", "delta", "echo",
        "foxtrot", "golf", "hotel", "india", "juliet",
    ]
    private func tag(_ pageIndexZeroBased: Int) -> String {
        return Self.bodyTags[pageIndexZeroBased % Self.bodyTags.count]
    }

    // MARK: - 1. Under-min-pages no-op

    @Test
    func under_min_pages_returns_empty_mask() {
        // 5 pages each ending with "Page N". Default minPages = 8 -> no-op.
        let pages: [PageParagraphs] = (1...5).map { n in
            makePage(n, ["body text", "Page \(n)"])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 2. Pure-numeric repetition

    @Test
    func pure_numeric_repetition_flags_last_paragraph_on_every_page() {
        // 10 pages, last paragraph is just "\(n)". Body text uses a
        // non-numeric per-page tag so bodies normalize to distinct keys.
        let pages: [PageParagraphs] = (1...10).map { n in
            makePage(n, ["unique \(tag(n - 1)) body paragraph xyz", "\(n)"])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]))
        }
    }

    // MARK: - 3. Roman numeral repetition

    @Test
    func roman_numeral_repetition_flags_last_paragraph_on_every_page() {
        let romans = ["vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv", "xvi"]
        let pages: [PageParagraphs] = romans.enumerated().map { (i, r) in
            makePage(i + 1, ["unique \(tag(i)) body paragraph xyz", r])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]))
        }
    }

    // MARK: - 4. Mixed "Page N" repetition

    @Test
    func mixed_page_n_repetition_flags_last_paragraph_on_every_page() {
        let pages: [PageParagraphs] = (1...10).map { n in
            makePage(n, ["lorem ipsum \(tag(n - 1)) body here", "Page \(n)"])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]))
        }
    }

    // MARK: - 5. Multi-line copyright block

    @Test
    func multi_line_copyright_block_flags_three_trailing_indices() {
        // Page layout: ["body...", copyright, all-rights, printed-in-usa]
        // The trailing 3 paragraphs repeat verbatim — depths 0, 1, 2 should
        // each accumulate above-threshold matches. Body text uses a
        // non-numeric tag per page so it does not falsely repeat.
        let pages: [PageParagraphs] = (1...10).map { n in
            makePage(n, [
                "body \(tag(n - 1)) paragraph text content",
                "(c) 2024 Foo Press",
                "All rights reserved",
                "Printed in USA",
            ])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1, 2, 3]))
        }
    }

    // MARK: - 6. Threshold edge case (>= threshold)

    @Test
    func threshold_edge_case_three_of_ten_at_thirty_percent_is_flagged() {
        // 0.30 * 10 = 3.0; comparison is `>=`, so exactly 3 matching pages
        // is flagged. Pages 1..3 share footer "Common"; pages 4..10 have
        // unique footers.
        var pages: [PageParagraphs] = []
        for n in 1...3 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Common"]))
        }
        for n in 4...10 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Unique-\(tag(n - 1))-zzz-tail"]))
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask[1] == Set([1]))
        #expect(mask[2] == Set([1]))
        #expect(mask[3] == Set([1]))
        for n in 4...10 {
            #expect(mask[n] == nil)
        }
    }

    // MARK: - 7. Below threshold

    @Test
    func below_threshold_two_of_ten_returns_empty_mask() {
        var pages: [PageParagraphs] = []
        for n in 1...2 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Common"]))
        }
        for n in 3...10 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Unique-\(tag(n - 1))-zzz-tail"]))
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 8. Long-body paragraph cap

    @Test
    func long_body_paragraph_under_cap_is_flagged() {
        // 201-char repeating paragraph at the tail. maxCharsPerLine default
        // 250 -> WOULD be flagged.
        let long201 = String(repeating: "a", count: 201)
        let pages: [PageParagraphs] = (1...10).map { n in
            makePage(n, ["body \(tag(n - 1))", long201])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]))
        }
    }

    @Test
    func long_body_paragraph_over_cap_is_not_flagged() {
        // 251-char repeating paragraph; cap fires -> NOT flagged.
        let long251 = String(repeating: "a", count: 251)
        let pages: [PageParagraphs] = (1...10).map { n in
            makePage(n, ["body \(tag(n - 1))", long251])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - 9. Mixed pages where some have a footer and some don't

    @Test
    func only_pages_with_repeating_footer_are_flagged() {
        // 6 of 10 pages have "Page N" footer; the other 4 have unique
        // long body tails. 6/10 = 60% >= 30%. Only the 6 footer pages
        // should have flags.
        var pages: [PageParagraphs] = []
        for n in 1...6 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Page \(n)"]))
        }
        for n in 7...10 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Unique \(tag(n - 1)) tail text that does not repeat anywhere else"]))
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        for n in 1...6 {
            #expect(mask[n] == Set([1]))
        }
        for n in 7...10 {
            #expect(mask[n] == nil)
        }
    }

    // MARK: - 10. Reading-order semantics

    @Test
    func reading_order_semantics_flags_last_index_not_first() {
        // 10 pages with 4 paragraphs each, footer at index 3 (last).
        // Must flag 3, not 0. Body paragraphs use non-numeric tags so
        // they do not collapse to a shared normalized key.
        let pages: [PageParagraphs] = (1...10).map { n in
            let t = tag(n - 1)
            return makePage(n, [
                "intro \(t) paragraph",
                "middle \(t) paragraph",
                "another body \(t) paragraph",
                "Page \(n)",
            ])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        for n in 1...10 {
            #expect(mask[n] == Set([3]))
        }
    }

    // MARK: - 11. Empty pages don't crash

    @Test
    func empty_pages_do_not_crash_and_contribute_no_entries() {
        // 10 pages; 2 of them are empty. Remaining 8 share "Page N" tail.
        // 8/10 = 80% >= 30% -> the 8 non-empty pages get flagged.
        var pages: [PageParagraphs] = []
        pages.append(makePage(1, []))
        for n in 2...9 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Page \(n)"]))
        }
        pages.append(makePage(10, []))

        let mask = SuffixFooterStrategy.detect(pages: pages)
        for n in 2...9 {
            #expect(mask[n] == Set([1]))
        }
        #expect(mask[1] == nil)
        #expect(mask[10] == nil)
    }

    // MARK: - 12. Slot stability — mask carries paragraph INDICES

    @Test
    func mask_returns_paragraph_indices_not_text() {
        // Same shape as test 10 but explicitly assert the integer slot
        // semantics: an out-of-band caller dropping by index should
        // preserve the indices of surviving paragraphs.
        let pages: [PageParagraphs] = (1...10).map { n in
            let t = tag(n - 1)
            return makePage(n, [
                "p \(t) one",
                "p \(t) two",
                "Page \(n)",   // index 2 = footer
            ])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        for n in 1...10 {
            let dropped = mask[n] ?? []
            #expect(dropped == Set([2]))
            // Caller filters by index — surviving indices are {0, 1}.
            let survivors = (0..<3).filter { !dropped.contains($0) }
            #expect(survivors == [0, 1])
        }
    }

    // MARK: - Bonus: suffixDepth respected

    @Test
    func paragraph_outside_suffix_depth_window_is_not_flagged() {
        // 10 pages with 8 paragraphs. The repeating "Page N" lives at
        // index 1 (i.e. 7 from the bottom). suffixDepth = 6 means only
        // the last 6 paragraphs are inspected -> NOT flagged. Body
        // paragraphs use non-numeric tags so the strategy cannot match
        // them either.
        let pages: [PageParagraphs] = (1...10).map { n in
            let t = tag(n - 1)
            return makePage(n, [
                "p \(t) zero",
                "Page \(n)",   // index 1 — above the bottom-6 window
                "p \(t) two",
                "p \(t) three",
                "p \(t) four",
                "p \(t) five",
                "p \(t) six",
                "p \(t) seven",
            ])
        }
        let mask = SuffixFooterStrategy.detect(pages: pages)
        #expect(mask.isEmpty)
    }

    // MARK: - Bonus: custom repetitionThreshold

    @Test
    func custom_lower_threshold_catches_sparser_repeats() {
        // 2 of 10 pages share a footer: at default 0.30 -> not flagged,
        // at custom 0.20 -> flagged.
        var pages: [PageParagraphs] = []
        for n in 1...2 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "RareFooter"]))
        }
        for n in 3...10 {
            pages.append(makePage(n, ["body \(tag(n - 1))", "Unique-\(tag(n - 1))-zzz-tail"]))
        }
        var opts = SuffixFooterOptions()
        opts.threshold = 0.20
        let mask = SuffixFooterStrategy.detect(pages: pages, options: opts)
        #expect(mask[1] == Set([1]))
        #expect(mask[2] == Set([1]))
        for n in 3...10 {
            #expect(mask[n] == nil)
        }
    }
}
