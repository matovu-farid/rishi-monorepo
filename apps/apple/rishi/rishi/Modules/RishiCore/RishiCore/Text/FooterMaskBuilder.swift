//
//  FooterMaskBuilder.swift
//  RishiCore (Phase 27 plan 27-06)
//
//  Orchestrator that unions the three ported strategies (`SuffixFooterStrategy`,
//  `RepetitionFooterStrategy`, `FootnoteDetector`) plus the
//  `ExpandToLineMates` post-processor into a single per-page paragraph mask
//  that the indexer (`PdfTextExtractor`) can apply before chunking.
//
//  Direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/buildFooterMask.ts`. Apple parity goal: given equivalent input,
//  produce the same set of dropped paragraphs.
//
//  Layout-mask -> paragraph-mask translation (per 27-06-PLAN.md §"Layout ->
//  paragraph translation"): Apple does not yet plumb the `itemIndex ->
//  paragraph` mapping through the layout extractor (a stretch follow-up).
//  For the first landing we use a conservative substring-match rule: a
//  paragraph is flagged iff its `FooterTokens.normalize`d text appears as a
//  substring inside any masked item's normalized text on the same page.
//  False-negative-friendly, false-positive-hostile — matches the electron
//  intent ("every contributing item is masked") on the page-number-trailer
//  cases that drive the integration test.
//

import Foundation
import CoreGraphics

/// Orchestrator for the three Phase 27 footer-detection strategies.
///
/// Pure namespace — `build(inputs:options:)` is a pure function over its
/// inputs with no I/O and no shared mutable state.
public enum FooterMaskBuilder {

    /// Knobs threaded through to each strategy.
    public struct Options: Sendable {
        public var suffix: SuffixFooterOptions
        public var repetition: RepetitionFooterOptions
        public var footnote: FootnoteDetectorOptions
        /// When true, layout-mask flagged items widen to their y-bin line
        /// mates via `ExpandToLineMates` before paragraph translation.
        public var enableLineMateExpansion: Bool

        public init(
            suffix: SuffixFooterOptions = SuffixFooterOptions(),
            repetition: RepetitionFooterOptions = RepetitionFooterOptions(),
            footnote: FootnoteDetectorOptions = FootnoteDetectorOptions(),
            enableLineMateExpansion: Bool = true
        ) {
            self.suffix = suffix
            self.repetition = repetition
            self.footnote = footnote
            self.enableLineMateExpansion = enableLineMateExpansion
        }
    }

    /// Inputs to the builder. `layout` is optional so EPUB / text-only
    /// pipelines can run the suffix strategy alone.
    public struct Inputs: Sendable {
        /// Layout-aware view of the document, when available. Pass nil for
        /// EPUB / text-only extraction.
        public var layout: [PageText]?
        /// Per-page paragraphs that the indexer will eventually consume.
        public var paragraphsByPage: [PageParagraphs]

        public init(layout: [PageText]?, paragraphsByPage: [PageParagraphs]) {
            self.layout = layout
            self.paragraphsByPage = paragraphsByPage
        }
    }

    /// Build a per-page paragraph mask. The mask key is `pageNumber` (matching
    /// `PageParagraphs.pageNumber`); values are sets of paragraph indices to
    /// drop. Layout-aware strategies (repetition + footnote) are skipped when
    /// `inputs.layout` is nil or below the suffix minimum-pages floor.
    ///
    /// - Parameters:
    ///   - inputs: layout + paragraph streams.
    ///   - options: per-strategy tunables.
    /// - Returns: union of every strategy's flagged paragraph indices per page.
    public static func build(
        inputs: Inputs,
        options: Options = Options()
    ) -> TextFooterMask {
        var result: TextFooterMask = [:]

        // 1. Text-only suffix strategy.
        let suffixMask = SuffixFooterStrategy.detect(
            pages: inputs.paragraphsByPage,
            options: options.suffix
        )
        merge(into: &result, from: suffixMask)

        // 2. Layout-aware strategies — only when layout is available + enough pages.
        if let layout = inputs.layout, layout.count >= options.suffix.minPages {

            // 2a. Repetition strategy -> layout mask.
            var repetitionLayoutMask = RepetitionFooterStrategy.detect(
                pages: layout,
                options: options.repetition
            )

            // 2b. Optional line-mate expansion.
            if options.enableLineMateExpansion {
                repetitionLayoutMask = ExpandToLineMates.expand(
                    mask: repetitionLayoutMask,
                    pages: layout,
                    yBinPct: options.repetition.yBinPct
                )
            }

            // 2c. Footnote detector — per-page; union into a layout mask.
            var footnoteLayoutMask: LayoutFooterMask = [:]
            for page in layout {
                let perPage = FootnoteDetector.detect(page: page, options: options.footnote)
                if !perPage.isEmpty {
                    footnoteLayoutMask[page.pageIndex] = perPage
                }
            }

            // 2d. Translate layout (item-index) masks to paragraph-index
            //     masks via the conservative substring match documented above.
            //
            //     PageParagraphs.pageNumber convention used by callers in
            //     Apple is 1-based (mirrors `PdfTextExtractor`'s
            //     `pageIndex + 1`); PageText.pageIndex is 0-based. The
            //     producer (PdfTextExtractor) emits parallel arrays so the
            //     i-th paragraph page matches the i-th layout page; we key
            //     translation by ARRAY INDEX rather than ID to stay agnostic
            //     to the producer's numbering scheme.
            let mergedLayoutMask = unionLayoutMasks(repetitionLayoutMask, footnoteLayoutMask)
            let translated = translateLayoutMaskToParagraphMask(
                mergedLayoutMask,
                layout: layout,
                paragraphsByPage: inputs.paragraphsByPage
            )
            merge(into: &result, from: translated)
        }

        return result
    }

    // MARK: - Helpers

    /// In-place union of two `TextFooterMask`s.
    private static func merge(into result: inout TextFooterMask, from incoming: TextFooterMask) {
        for (page, indices) in incoming {
            result[page, default: []].formUnion(indices)
        }
    }

    /// In-place union of two `LayoutFooterMask`s.
    private static func unionLayoutMasks(_ a: LayoutFooterMask, _ b: LayoutFooterMask) -> LayoutFooterMask {
        var result = a
        for (page, indices) in b {
            result[page, default: []].formUnion(indices)
        }
        return result
    }

    /// Conservative translation: a paragraph is flagged iff its normalized
    /// text appears as a substring inside any masked item's normalized text
    /// on the same page (array-index aligned).
    ///
    /// This is the first-landing approximation per 27-06-PLAN.md §Risks R1.
    /// A future phase plumbs the `itemIndex -> paragraph` map through the
    /// layout extractor so the strict electron "every contributing item is
    /// masked" rule can be preserved exactly.
    private static func translateLayoutMaskToParagraphMask(
        _ layoutMask: LayoutFooterMask,
        layout: [PageText],
        paragraphsByPage: [PageParagraphs]
    ) -> TextFooterMask {
        var result: TextFooterMask = [:]
        let pairCount = min(layout.count, paragraphsByPage.count)
        for i in 0..<pairCount {
            let page = layout[i]
            let paragraphs = paragraphsByPage[i]
            guard let maskedItemIndices = layoutMask[page.pageIndex],
                  !maskedItemIndices.isEmpty else { continue }

            // Normalize the masked items once per page.
            let maskedNormalizedTexts: [String] = maskedItemIndices.compactMap { idx in
                guard idx >= 0, idx < page.items.count else { return nil }
                let t = FooterTokens.normalize(page.items[idx].text)
                return t.isEmpty ? nil : t
            }
            if maskedNormalizedTexts.isEmpty { continue }

            for paragraph in paragraphs.paragraphs {
                let normalized = FooterTokens.normalize(paragraph.text)
                if normalized.isEmpty { continue }
                // One-directional substring: paragraph text must be a
                // substring of some masked item's text. This mirrors the
                // electron intent ("the whole paragraph is footer
                // content"). The reverse direction (item is substring of
                // paragraph) would catch a footer LINE embedded inside a
                // longer body paragraph — that is exactly the false
                // positive we want to AVOID on the first landing
                // (otherwise a body paragraph that happens to end with
                // "Page 7" gets dropped wholesale).
                let hit = maskedNormalizedTexts.contains { itemText in
                    itemText.contains(normalized)
                }
                if hit {
                    result[paragraphs.pageNumber, default: []].insert(paragraph.index)
                }
            }
        }
        return result
    }
}
