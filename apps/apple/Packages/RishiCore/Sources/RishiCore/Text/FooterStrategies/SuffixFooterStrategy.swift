//
//  SuffixFooterStrategy.swift
//  RishiCore (Phase 27 plan 27-03)
//
//  Direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/findRepeatingPageSuffix.ts:28-95`. Pure paragraph-text + page-
//  index strategy with NO layout dependency — usable for both layout-aware
//  (PDFs) and text-only (EPUB / scanned PDF fallback) paths.
//
//  Identifies the bottom-most paragraphs of each page that repeat (after
//  `FooterTokens.normalize`) across at least `threshold` proportion of pages.
//  Returns a per-page mask of paragraph indices to drop.
//
//  Known divergence from electron source: electron sorts page paragraphs by
//  `dimensions.bottom` ascending (spatial). Apple text-only port uses the
//  TAIL of reading order (last N paragraphs of the page). For PDFs whose
//  body renders in top-to-bottom reading order the two definitions coincide.
//  Multi-column PDFs are a known weak case (electron also handles them
//  inconsistently per electron tests).
//

import Foundation

/// Per-paragraph identity inside a page. The `index` field is the
/// stream-order position (0-based) so callers can preserve slot
/// stability when dropping flagged paragraphs (mirrors electron's
/// "preserve index slot" semantics at `buildFooterMask.ts:23-24`).
public struct PageParagraph: Sendable, Equatable {
    public let index: Int
    public let text: String
    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

/// One page's paragraph stream in reading order.
public struct PageParagraphs: Sendable, Equatable {
    public let pageNumber: Int
    public let paragraphs: [PageParagraph]
    public init(pageNumber: Int, paragraphs: [PageParagraph]) {
        self.pageNumber = pageNumber
        self.paragraphs = paragraphs
    }
}

/// `pageNumber -> set of paragraph indices flagged as footer chrome`.
public typealias TextFooterMask = [Int: Set<Int>]

/// Tunables for `SuffixFooterStrategy.detect`. Defaults mirror the
/// electron `DEFAULT_SUFFIX_MATCH_OPTIONS` constants.
public struct SuffixFooterOptions: Sendable {
    /// Don't engage below this page count. Default 8.
    public var minPages: Int = 8
    /// How many paragraphs from the bottom of each page to consider.
    /// Default 6.
    public var suffixDepth: Int = 6
    /// Pages-share threshold (fraction of `pages.count`). Default 0.30.
    public var threshold: Double = 0.30
    /// Mirror of `BuildFooterMaskOptions.maxCharsPerLine` — skips long
    /// paragraphs as suffix candidates so a repeating body paragraph
    /// (>250 chars) is not falsely flagged. Default 250.
    public var maxCharsPerLine: Int = 250

    public init() {}
}

/// Text-only suffix-repetition footer detector.
///
/// Detect footers that span multiple of our internal paragraph divisions
/// by pattern-matching the bottom-most paragraphs across pages. A copyright
/// block can be grouped logically (not spatially) into one or more
/// paragraphs; this strategy masks each one independently when it repeats
/// near the foot of many pages.
public enum SuffixFooterStrategy {

    /// One per-page suffix slot: original paragraph index + the
    /// `FooterTokens.normalize`d text.
    private struct SuffixEntry {
        let index: Int
        let normalizedText: String
    }

    /// Detect repeating bottom-of-page paragraphs across the page stream.
    ///
    /// - Parameters:
    ///   - pages: per-page paragraph streams in reading order.
    ///   - options: tunables; defaults mirror electron's
    ///     `DEFAULT_SUFFIX_MATCH_OPTIONS`.
    /// - Returns: `pageNumber -> set of paragraph indices` flagged as
    ///   footer chrome. Empty mask when `pages.count < options.minPages`.
    public static func detect(
        pages: [PageParagraphs],
        options: SuffixFooterOptions = SuffixFooterOptions()
    ) -> TextFooterMask {
        var mask: TextFooterMask = [:]

        if pages.count < options.minPages { return mask }

        // Per-page bottom-most slice in reading order. Index 0 of the
        // slice is the BOTTOM-most paragraph (mirrors electron's
        // `sorted.slice(0, suffixDepth)` after the spatial sort, where
        // smallest `bottom` first == lowest paragraph on the page).
        var suffixesByPage: [Int: [SuffixEntry]] = [:]
        suffixesByPage.reserveCapacity(pages.count)

        for p in pages {
            if p.paragraphs.isEmpty { continue }
            // Take last `suffixDepth` paragraphs, reversed so index 0
            // is the bottom-most. Skip entries that exceed the
            // `maxCharsPerLine` cap or whose normalized form is empty.
            let tailCount = min(options.suffixDepth, p.paragraphs.count)
            var slice: [SuffixEntry] = []
            slice.reserveCapacity(tailCount)
            // Walk from the last paragraph upward.
            let end = p.paragraphs.count
            let start = end - tailCount
            for i in stride(from: end - 1, through: start, by: -1) {
                let paragraph = p.paragraphs[i]
                if paragraph.text.count > options.maxCharsPerLine { continue }
                let normalized = FooterTokens.normalize(paragraph.text)
                if normalized.isEmpty { continue }
                slice.append(
                    SuffixEntry(index: paragraph.index, normalizedText: normalized)
                )
            }
            if slice.isEmpty { continue }
            suffixesByPage[p.pageNumber] = slice
        }

        let threshold = options.threshold * Double(pages.count)

        for d in 0..<options.suffixDepth {
            // text -> pages where this depth-d paragraph appears
            var pagesByText: [String: Set<Int>] = [:]
            for p in pages {
                guard let slice = suffixesByPage[p.pageNumber] else { continue }
                if slice.count <= d { continue }
                let entry = slice[d]
                if entry.normalizedText.isEmpty { continue }
                pagesByText[entry.normalizedText, default: []].insert(p.pageNumber)
            }

            for (text, pageSet) in pagesByText {
                // Electron uses `pageSet.size < threshold` to skip;
                // i.e. flag when `pageSet.size >= threshold`. Preserve
                // that exact comparison.
                if Double(pageSet.count) < threshold { continue }
                for pageNumber in pageSet {
                    guard let slice = suffixesByPage[pageNumber] else { continue }
                    if slice.count <= d { continue }
                    let entry = slice[d]
                    if entry.normalizedText != text { continue }
                    mask[pageNumber, default: []].insert(entry.index)
                }
            }
        }

        return mask
    }
}
