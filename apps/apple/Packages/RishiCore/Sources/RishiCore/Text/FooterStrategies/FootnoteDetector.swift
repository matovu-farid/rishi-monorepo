//
//  FootnoteDetector.swift
//  RishiCore (Phase 27 plan 27-05)
//
//  Direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/detectFootnoteItems.ts` (lines 7-114). Per-page positional
//  heuristic that flags items below the body block whose font size is
//  notably smaller than the page's median body font AND are separated from
//  the body by an oversized vertical gap.
//
//  Catches: book-style footnotes set in smaller font at the bottom of a
//  page. Footnotes never repeat across pages, so repetition-based footer
//  detection (Phase 27-04) misses them — this strategy complements it.
//
//  Coordinate convention: PDFKit user-space coordinates put the origin at
//  the page's BOTTOM-LEFT corner with Y growing upwards. "Below the body"
//  therefore means SMALLER y. Mirrors pdf.js `transform[5]` semantics.
//
//  ── On `fontSize` approximation ────────────────────────────────────────
//  As flagged in 27-01 R1, the Apple producer (`PDFLayoutExtractor`) uses
//  PDFKit `selectionsByLine` which yields ONE TextItem per LINE with
//  `fontSize` derived from the line bounding-box height. That's an
//  approximation — descenders inflate it, small caps confuse it. The
//  comparison stays valid because the threshold is RELATIVE to the
//  per-page median: both body and footnote heights use the same
//  approximation, so the ratio `noteHeight / bodyHeight` remains a useful
//  signal even when the absolute values are off.
//
//  Pure function with no global state. Sendable input + Sendable output.
//

import Foundation
import CoreGraphics

/// Tunables for `FootnoteDetector.detect`. Defaults mirror electron's
/// `SMALL_FONT_RATIO = 0.85` and `MIN_GAP_MULT = 1.5`.
public struct FootnoteDetectorOptions: Sendable, Equatable {
    /// `smallThreshold = bodyHeight * smallFontRatio`. Items with height
    /// below this threshold are candidates for "footnote font".
    public var smallFontRatio: CGFloat

    /// `minGap = bodyHeight * minGapMultiplier`. The vertical distance
    /// between the body bottom and the footnote top must be at least this
    /// multiple of the body height for the block to be flagged.
    public var minGapMultiplier: CGFloat

    /// `clusterGap = bodyHeight * clusterGapMultiplier`. Body-sized items
    /// whose successive y-deltas exceed this gap belong to different
    /// clusters; the largest cluster's bottom defines the body bottom.
    public var clusterGapMultiplier: CGFloat

    public init(
        smallFontRatio: CGFloat = 0.85,
        minGapMultiplier: CGFloat = 1.5,
        clusterGapMultiplier: CGFloat = 2.0
    ) {
        self.smallFontRatio = smallFontRatio
        self.minGapMultiplier = minGapMultiplier
        self.clusterGapMultiplier = clusterGapMultiplier
    }
}

/// Per-page footnote detector.
///
/// Stateless namespace — `detect` is a pure function over a single
/// `PageText` with no I/O and no shared mutable state.
public enum FootnoteDetector {

    /// Internal scan entry. Mirrors `Entry` in detectFootnoteItems.ts:29-34.
    private struct Entry {
        let index: Int
        let y: CGFloat
        let height: CGFloat
        let hasText: Bool
    }

    /// Returns the set of `TextItem` stream indices on the page that look
    /// like footnotes. Operates on a single page; whole-book callers loop.
    ///
    /// Output identity matches the input `PageText.items` array index so
    /// callers (Phase 27-06 mask consumer) can drop items in stream-order
    /// without re-resolving by text content.
    public static func detect(
        page: PageText,
        options: FootnoteDetectorOptions = FootnoteDetectorOptions()
    ) -> Set<Int> {
        var result: Set<Int> = []

        // 1. Build entries, skipping items with non-finite y. Mirrors
        //    detectFootnoteItems.ts:50-60.
        var entries: [Entry] = []
        entries.reserveCapacity(page.items.count)
        for (i, item) in page.items.enumerated() {
            guard item.frame.minY.isFinite else { continue }
            let height: CGFloat = item.fontSize.isFinite ? item.fontSize : 0
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(
                index: i,
                y: item.frame.minY,
                height: height,
                hasText: !trimmed.isEmpty
            ))
        }
        guard !entries.isEmpty else { return result }

        // 2. Body height = median of text-bearing items with positive
        //    height. Mirrors detectFootnoteItems.ts:63.
        let bodyHeights = entries
            .filter { $0.hasText && $0.height > 0 }
            .map(\.height)
        guard !bodyHeights.isEmpty else { return result }
        let bodyHeight = median(bodyHeights)
        guard bodyHeight > 0 else { return result }

        let smallThreshold = bodyHeight * options.smallFontRatio
        let minGap = bodyHeight * options.minGapMultiplier
        let clusterGap = bodyHeight * options.clusterGapMultiplier

        // 3. Cluster body-sized items by y (descending) and find the
        //    LARGEST cluster's bottom y. Mirrors detectFootnoteItems.ts:73-100.
        let bodySized = entries
            .filter { $0.hasText && $0.height >= smallThreshold }
            .sorted { $0.y > $1.y }
        guard !bodySized.isEmpty else { return result }

        var bestBottom = bodySized[0].y
        var bestCount = 0
        var curBottom = bodySized[0].y
        var curCount = 1
        if bodySized.count > 1 {
            for i in 1..<bodySized.count {
                if bodySized[i - 1].y - bodySized[i].y <= clusterGap {
                    curCount += 1
                    curBottom = bodySized[i].y
                } else {
                    if curCount > bestCount {
                        bestCount = curCount
                        bestBottom = curBottom
                    }
                    curCount = 1
                    curBottom = bodySized[i].y
                }
            }
        }
        if curCount > bestCount {
            bestCount = curCount
            bestBottom = curBottom
        }
        let bodyBottomY = bestBottom

        // 4. Smaller-font items strictly below the body. Mirrors
        //    detectFootnoteItems.ts:103-105.
        let belowSmall = entries.filter {
            $0.height > 0 && $0.height < smallThreshold && $0.y < bodyBottomY
        }
        guard !belowSmall.isEmpty else { return result }

        // 5. The block must be separated from the body by an oversized
        //    gap. Mirrors detectFootnoteItems.ts:108-110.
        let footnoteTopY = belowSmall.map(\.y).max() ?? bodyBottomY
        guard bodyBottomY - footnoteTopY >= minGap else { return result }

        for e in belowSmall { result.insert(e.index) }
        return result
    }

    /// Mirrors `median()` in detectFootnoteItems.ts:22-27.
    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }
}
