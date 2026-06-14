//
//  FooterMaskBuilderTests.swift
//  RishiCoreTests (Phase 27 plan 27-06)
//
//  Coverage for the orchestrator that unions the three Phase 27 footer-
//  detection strategies. Mirrors the test plan in 27-06-PLAN.md so any drift
//  in the merged semantics surfaces immediately.
//

import Testing
import Foundation
import CoreGraphics
import RishiCore

struct FooterMaskBuilderTests {

    // MARK: - Helpers

    private func makeParagraphPage(_ pageNumber: Int, _ texts: [String]) -> PageParagraphs {
        let paragraphs = texts.enumerated().map { (i, t) in
            PageParagraph(index: i, text: t)
        }
        return PageParagraphs(pageNumber: pageNumber, paragraphs: paragraphs)
    }

    /// Build a synthetic 8.5x11 PDF-style page with one TextItem per text
    /// laid out top-to-bottom at uniform spacing. The last `trailerCount`
    /// items are placed in the bottom band to mimic page-number footers.
    private func makeLayoutPage(
        pageIndex: Int,
        body: [String],
        trailers: [String]
    ) -> PageText {
        // 612x792 = US letter in PDF user units.
        let pageFrame = CGRect(x: 0, y: 0, width: 612, height: 792)
        var items: [TextItem] = []

        // Body items: laid out top-down (large y first).
        let bodyTop: CGFloat = 700
        let bodyStep: CGFloat = 30
        for (i, text) in body.enumerated() {
            let y = bodyTop - CGFloat(i) * bodyStep
            items.append(TextItem(
                text: text,
                frame: CGRect(x: 72, y: y, width: 468, height: 14),
                fontSize: 12
            ))
        }

        // Trailers in the bottom band (y < bottomBandPct * 792 = 198 by default).
        let trailerStart: CGFloat = 100
        for (i, text) in trailers.enumerated() {
            let y = trailerStart - CGFloat(i) * 20
            items.append(TextItem(
                text: text,
                frame: CGRect(x: 72, y: y, width: 468, height: 12),
                fontSize: 10
            ))
        }

        return PageText(pageIndex: pageIndex, frame: pageFrame, items: items)
    }

    // MARK: - 1. No layout, no suffix match -> empty

    @Test
    func no_layout_and_under_min_pages_returns_empty() {
        let pages: [PageParagraphs] = (1...5).map { n in
            makeParagraphPage(n, ["body \(n)", "Page \(n)"])
        }
        let inputs = FooterMaskBuilder.Inputs(layout: nil, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.isEmpty)
    }

    // MARK: - 2. Suffix-only path (no layout)

    @Test
    func suffix_only_path_flags_last_paragraph_per_page() {
        // 10 pages each ending with "Page N" (varying N). After
        // FooterTokens.normalize -> "page __NUM__" on every page.
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [PageParagraphs] = (1...10).map { n in
            makeParagraphPage(n, ["body \(bodyTags[n - 1])", "Page \(n)"])
        }
        let inputs = FooterMaskBuilder.Inputs(layout: nil, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]), "Page \(n) should have its trailing paragraph (index 1) flagged")
        }
    }

    // MARK: - 3. Layout + suffix: set-union has exactly one index per page

    @Test
    func layout_and_suffix_no_double_flag() {
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [PageParagraphs] = (1...10).map { n in
            makeParagraphPage(n, ["body \(bodyTags[n - 1])", "Page \(n)"])
        }
        // Layout pages: body items + a trailing "Page N" item in the
        // bottom band so RepetitionFooterStrategy flags index 1.
        let layout: [PageText] = (0..<10).map { i in
            makeLayoutPage(
                pageIndex: i,
                body: ["body \(bodyTags[i])"],
                trailers: ["Page \(i + 1)"]
            )
        }
        let inputs = FooterMaskBuilder.Inputs(layout: layout, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]), "Page \(n) flagged set should be exactly {1}, got \(String(describing: mask[n]))")
        }
    }

    // MARK: - 4. Toggle off via empty layout AND no suffix match -> empty

    @Test
    func no_layout_with_unique_per_page_paragraphs_yields_empty() {
        // 10 pages with completely distinct trailing paragraphs and no
        // recurring pattern (each tag is a non-numeric token so
        // FooterTokens.normalize does NOT collapse them to a shared key).
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [PageParagraphs] = (1...10).map { n in
            let tag = bodyTags[n - 1]
            return makeParagraphPage(n, [
                "Body \(tag) intro sentence.",
                "Body \(tag) middle sentence.",
                "Body \(tag) conclusion sentence."
            ])
        }
        let inputs = FooterMaskBuilder.Inputs(layout: nil, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.isEmpty, "Per-page-unique paragraphs should not be flagged by the suffix strategy; got \(mask)")
    }

    // MARK: - 5. Line-mate expansion plumbed through

    @Test
    func line_mate_expansion_can_be_disabled() {
        // Build a layout where ExpandToLineMates would widen the flagged set.
        // We can't easily distinguish expansion in the merged paragraph mask
        // because Apple's PDFLayoutExtractor emits one item per line — but we
        // CAN assert the option is plumbed by toggling it and observing that
        // the build does not throw and behaviour matches the suffix-only mask
        // when layout has too few pages to engage layout strategies.
        let bodyTags = ["alpha","bravo","charlie","delta","echo",
                        "foxtrot","golf","hotel","india","juliet"]
        let pages: [PageParagraphs] = (1...10).map { n in
            makeParagraphPage(n, ["body \(bodyTags[n - 1])", "Page \(n)"])
        }
        let layout: [PageText] = (0..<10).map { i in
            makeLayoutPage(
                pageIndex: i,
                body: ["body \(bodyTags[i])"],
                trailers: ["Page \(i + 1)"]
            )
        }
        var opts = FooterMaskBuilder.Options()
        opts.enableLineMateExpansion = false
        let inputs = FooterMaskBuilder.Inputs(layout: layout, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs, options: opts)
        // Still flags trailing "Page N" — suffix + repetition agree.
        #expect(mask.count == 10)
        for n in 1...10 {
            #expect(mask[n] == Set([1]))
        }
    }

    // MARK: - 6. Below-minPages layout is skipped even when supplied

    @Test
    func layout_below_minPages_skips_layout_strategies() {
        // 5 layout pages (default minPages = 8) — should not run repetition
        // or footnote. Empty mask returned because suffix also requires >= 8.
        let pages: [PageParagraphs] = (1...5).map { n in
            makeParagraphPage(n, ["body \(n)", "Page \(n)"])
        }
        let layout: [PageText] = (0..<5).map { i in
            makeLayoutPage(
                pageIndex: i,
                body: ["body \(i)"],
                trailers: ["Page \(i + 1)"]
            )
        }
        let inputs = FooterMaskBuilder.Inputs(layout: layout, paragraphsByPage: pages)
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.isEmpty)
    }

    // MARK: - 7. Empty inputs

    @Test
    func empty_inputs_return_empty_mask() {
        let inputs = FooterMaskBuilder.Inputs(layout: [], paragraphsByPage: [])
        let mask = FooterMaskBuilder.build(inputs: inputs)
        #expect(mask.isEmpty)
    }
}
