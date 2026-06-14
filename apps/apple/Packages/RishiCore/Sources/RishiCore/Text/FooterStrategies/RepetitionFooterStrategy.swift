//
//  RepetitionFooterStrategy.swift
//  RishiCore (Phase 27 plan 27-04)
//
//  Direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/footerStrategies/repetitionStrategy.ts` (lines 18-101). Flags
//  text items that share both a y-bin and a normalised text token across at
//  least `repetitionThreshold` proportion of pages. Catches page numbers,
//  running titles, copyright lines — anything that repeats at the same
//  vertical baseline with (after `FooterTokens.normalize`) the same text.
//
//  Coordinate convention: PDFKit user-space coordinates put the origin at
//  the page's BOTTOM-LEFT corner with Y growing upwards. Electron's pdf.js
//  uses the same convention (the `transform[5]` translation component is
//  bottom-left-origin user-space Y). The "bottom band" check is therefore
//  identical: `y < bandThreshold` means "near the bottom of the page" in
//  both runtimes.
//
//  Pure function with no global state. Sendable input + Sendable output.
//

import Foundation
import CoreGraphics

/// `pageIndex -> set of TextItem stream indices to drop`.
///
/// Output identity matches the input `PageText.items` array index so callers
/// (Phase 27-06 mask consumer) can drop items in stream-order without
/// re-resolving by text content.
public typealias LayoutFooterMask = [Int: Set<Int>]

/// Tunables for `RepetitionFooterStrategy.detect`. Defaults mirror
/// electron's `DEFAULT_FOOTER_OPTIONS` so detection behaviour is identical
/// across platforms for the same input.
public struct RepetitionFooterOptions: Sendable, Equatable {
    /// Minimum number of pages required before any detection runs. Short
    /// books / extracts have too little signal to distinguish "footer" from
    /// "happens to recur once or twice".
    public var minPages: Int

    /// Fraction of page height counted as the bottom band. Items with
    /// `frame.minY < pageHeight * bottomBandPct` (in bottom-left-origin
    /// PDF coords) are candidates.
    public var bottomBandPct: Double

    /// Fraction of page height used to quantise the y baseline into bins.
    /// Items in the same bin AND with the same normalised text count as
    /// "the same footer line" for repetition purposes.
    public var yBinPct: Double

    /// Minimum fraction of pages on which a (y-bin, normalised-text) key
    /// must appear before items matching it are flagged as footer.
    public var repetitionThreshold: Double

    /// Maximum number of footer lines dropped from a single page. When more
    /// than this many candidates pass the threshold on one page, the LOWEST
    /// `maxFooterLines` (smallest y == furthest down the page) are kept.
    public var maxFooterLines: Int

    /// Items with text length greater than this are excluded — they are
    /// almost certainly body prose, not a footer line.
    public var maxCharsPerLine: Int

    public init(
        minPages: Int = 8,
        bottomBandPct: Double = 0.25,
        yBinPct: Double = 0.02,
        repetitionThreshold: Double = 0.30,
        maxFooterLines: Int = 5,
        maxCharsPerLine: Int = 250
    ) {
        self.minPages = minPages
        self.bottomBandPct = bottomBandPct
        self.yBinPct = yBinPct
        self.repetitionThreshold = repetitionThreshold
        self.maxFooterLines = maxFooterLines
        self.maxCharsPerLine = maxCharsPerLine
    }
}

/// Layout-aware repetition footer detector.
///
/// Stateless namespace — `detect` is a pure function over `[PageText]` with
/// no I/O and no shared mutable state.
public enum RepetitionFooterStrategy {

    /// One bottom-band candidate item identified during the scan.
    /// Kept private to the strategy — callers receive only the final mask.
    private struct Candidate {
        let pageIndex: Int
        let itemIndex: Int
        let y: CGFloat
        let key: String
    }

    /// Detect repeating bottom-band footer items across the supplied pages.
    ///
    /// - Parameters:
    ///   - pages: All pages of the document, in any order (the algorithm
    ///     is order-independent — items are addressed by `pageIndex`).
    ///   - options: Tuning knobs; defaults mirror electron.
    /// - Returns: A `LayoutFooterMask` mapping `pageIndex` to the set of
    ///   `TextItem` stream indices on that page that should be dropped as
    ///   footer. Pages with no detected footer are absent from the map.
    public static func detect(
        pages: [PageText],
        options: RepetitionFooterOptions = RepetitionFooterOptions()
    ) -> LayoutFooterMask {
        // 1. Below the minimum-pages floor we have insufficient signal —
        //    bail before doing any work. Mirrors repetitionStrategy.ts:20.
        if pages.count < options.minPages {
            return [:]
        }

        // 2. Sentinel guard: if fewer than 5% of items have finite y-coords
        //    we cannot trust layout-based binning, so bail. Mirrors
        //    repetitionStrategy.ts:24-39.
        var totalItems = 0
        var withFiniteY = 0
        for p in pages {
            for item in p.items {
                totalItems += 1
                if item.frame.minY.isFinite {
                    withFiniteY += 1
                }
            }
        }
        if totalItems == 0 {
            return [:]
        }
        if Double(withFiniteY) / Double(totalItems) < 0.05 {
            return [:]
        }

        // 3. Scan: for each page, collect bottom-band candidates and tally
        //    page-sets per (y-bin, normalised-text) key. Mirrors
        //    repetitionStrategy.ts:50-76.
        var candidatesByPage: [Int: [Candidate]] = [:]
        var pagesByKey: [String: Set<Int>] = [:]

        for p in pages {
            let pageHeight = p.frame.height
            let band = pageHeight * CGFloat(options.bottomBandPct)
            let binUnit = pageHeight * CGFloat(options.yBinPct)
            var pageCandidates: [Candidate] = []

            for (i, item) in p.items.enumerated() {
                let y = item.frame.minY
                if !y.isFinite { continue }
                // "Bottom band" in PDF coords: low y == near the page
                // origin (bottom-left) == bottom of the page.
                if y >= band { continue }
                if item.text.count > options.maxCharsPerLine { continue }

                let yBin: Int
                if binUnit > 0 {
                    // Use `.rounded()` (banker's-neutral nearest) to match
                    // JavaScript `Math.round`.
                    yBin = Int((y / binUnit).rounded())
                } else {
                    yBin = 0
                }

                let key = "\(yBin) \(FooterTokens.normalize(item.text))"
                pageCandidates.append(Candidate(
                    pageIndex: p.pageIndex,
                    itemIndex: i,
                    y: y,
                    key: key
                ))
                pagesByKey[key, default: Set<Int>()].insert(p.pageIndex)
            }

            if !pageCandidates.isEmpty {
                candidatesByPage[p.pageIndex] = pageCandidates
            }
        }

        // 4. Filter to keys passing the repetition threshold and emit the
        //    per-page index set. Mirrors repetitionStrategy.ts:78-98.
        let threshold = options.repetitionThreshold * Double(pages.count)
        var mask: LayoutFooterMask = [:]

        for p in pages {
            guard let pageCandidates = candidatesByPage[p.pageIndex] else { continue }
            let passing = pageCandidates.filter { c in
                guard let pageSet = pagesByKey[c.key] else { return false }
                return Double(pageSet.count) >= threshold
            }
            if passing.isEmpty { continue }

            let chosen: [Candidate]
            if passing.count > options.maxFooterLines {
                // Sort by y ascending and keep the lowest `maxFooterLines`
                // — smallest y == furthest down the page == "most footery".
                chosen = Array(
                    passing.sorted(by: { $0.y < $1.y })
                        .prefix(options.maxFooterLines)
                )
            } else {
                chosen = passing
            }

            mask[p.pageIndex] = Set(chosen.map { $0.itemIndex })
        }

        return mask
    }
}
