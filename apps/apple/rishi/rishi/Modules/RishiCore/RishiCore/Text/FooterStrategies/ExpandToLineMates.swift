//
//  ExpandToLineMates.swift
//  RishiCore (Phase 27 plan 27-05 — supplemental)
//
//  Port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/footerStrategies/expandToLineMates.ts`. Pure post-processor
//  that, given a set of flagged item indices and the full item array of a
//  single page, widens the flagged set to include every item sharing a
//  baseline (y-coordinate within `baselineTolerance`) with any already-
//  flagged item.
//
//  Catches: mixed-content footer lines like "2 | Chapter 1: Introduction"
//  where only one fragment ("2") was flagged by an earlier strategy.
//
//  ── On per-line granularity ────────────────────────────────────────────
//  PDFLayoutExtractor (Phase 27-01) emits ONE TextItem per LINE via PDFKit
//  `selectionsByLine`. The electron analogue runs on pdf.js, which emits
//  one item per GLYPH RUN — many items per visible line. Consequently:
//
//  - In electron, this post-processor is load-bearing (it expands a single
//    flagged fragment to the whole footer line).
//  - In Apple, the line-level granularity means baseline-mates have
//    already been merged into a single item by the producer; this function
//    is effectively a NO-OP for the production pipeline but still correct
//    when called against synthetic finer-grained data (e.g. tests).
//
//  Kept in the API for parity and so callers in Phase 27-06 (FooterMask
//  builder) can plug it in unchanged when/if a finer-grained extractor
//  ships.
//
//  Pure function with no global state. Sendable input + Sendable output.
//

import Foundation
import CoreGraphics

/// Per-page baseline expander.
///
/// Stateless namespace — `expand` is a pure function over a single page's
/// items with no I/O and no shared mutable state.
public enum ExpandToLineMates {

    /// For each flagged item, also flag every item on the same baseline
    /// (y-coordinate within `baselineTolerance`).
    ///
    /// - Parameters:
    ///   - flagged: Indices into `items` that have already been flagged by
    ///     an earlier strategy.
    ///   - items: The full `TextItem` array of a single page, in PDF
    ///     stream order. The array index is the addressable identity.
    ///   - baselineTolerance: Maximum y-delta for two items to count as
    ///     baseline-mates. Defaults to `1.0` (PDF user-space units).
    /// - Returns: A new set containing every original flagged index plus
    ///   every baseline-mate found. Input is not mutated.
    public static func expand(
        flagged: Set<Int>,
        in items: [TextItem],
        baselineTolerance: CGFloat = 1.0
    ) -> Set<Int> {
        if flagged.isEmpty { return [] }

        // 1. Resolve the y-baselines occupied by flagged items. Out-of-
        //    bounds or non-finite-y entries are silently skipped.
        var flaggedYs: [CGFloat] = []
        flaggedYs.reserveCapacity(flagged.count)
        for ix in flagged {
            guard ix >= 0, ix < items.count else { continue }
            let y = items[ix].frame.minY
            guard y.isFinite else { continue }
            flaggedYs.append(y)
        }

        // 2. Walk every item and include any whose y is within tolerance
        //    of any flagged baseline. Pass-through ghost indices (out-of-
        //    bounds entries that survived step 1) by starting from the
        //    original flagged set.
        var expanded = flagged
        if flaggedYs.isEmpty { return expanded }

        for (i, item) in items.enumerated() {
            if expanded.contains(i) { continue }
            let y = item.frame.minY
            guard y.isFinite else { continue }
            for fy in flaggedYs {
                if abs(y - fy) <= baselineTolerance {
                    expanded.insert(i)
                    break
                }
            }
        }
        return expanded
    }

    /// Whole-document overload that takes a `LayoutFooterMask` + the full page
    /// stream and widens each page's flagged items to their y-bin siblings.
    ///
    /// Used by `FooterMaskBuilder` (Phase 27-06) so the orchestrator can plug
    /// expansion into the layout-mask pipeline without rewriting the per-page
    /// loop. Baseline tolerance is derived from `yBinPct * pageHeight` —
    /// mirrors the electron orchestrator's call site where `yBinPct` comes
    /// from `RepetitionFooterOptions`.
    ///
    /// - Parameters:
    ///   - mask: per-page item-index sets to widen.
    ///   - pages: the full page stream (item-index-addressed).
    ///   - yBinPct: fraction of page height used as the baseline tolerance
    ///     (matches `RepetitionFooterOptions.yBinPct`).
    /// - Returns: a new `LayoutFooterMask` with each page's flagged set
    ///   widened. Pages absent from the input mask remain absent.
    public static func expand(
        mask: LayoutFooterMask,
        pages: [PageText],
        yBinPct: Double
    ) -> LayoutFooterMask {
        // yBinPct == 0 short-circuits to the input verbatim (mirrors the
        // electron orchestrator's "no binning => no expansion" semantics).
        if yBinPct <= 0 { return mask }
        if mask.isEmpty { return mask }

        var result: LayoutFooterMask = [:]
        result.reserveCapacity(mask.count)

        // Index pages by pageIndex for an O(1) lookup; pages may arrive in
        // any order per RepetitionFooterStrategy's "order-independent" contract.
        var pageByIndex: [Int: PageText] = [:]
        pageByIndex.reserveCapacity(pages.count)
        for p in pages { pageByIndex[p.pageIndex] = p }

        for (pageIndex, flagged) in mask {
            guard let page = pageByIndex[pageIndex] else {
                // Defensive: keep the original flagged set if the page is
                // missing rather than silently dropping it.
                result[pageIndex] = flagged
                continue
            }
            let tolerance = page.frame.height * CGFloat(yBinPct)
            let expanded = expand(
                flagged: flagged,
                in: page.items,
                baselineTolerance: tolerance
            )
            result[pageIndex] = expanded
        }
        return result
    }
}
