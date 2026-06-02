import type { FooterMask, PageScanInput, BuildFooterMaskOptions } from '../buildFooterMask'

/**
 * Pluggable footer-detection strategy. Each strategy independently inspects
 * the per-page TextContent and returns a partial FooterMask. The orchestrator
 * unions the partial masks — an item flagged by ANY strategy is treated as
 * footer chrome.
 */
export type FooterStrategy = (pages: PageScanInput[], opts: BuildFooterMaskOptions) => FooterMask

/**
 * Runs AFTER all strategies have unioned. Used to refine the merged mask
 * (e.g., expand each flagged item to its baseline-mates on the same page).
 */
export type FooterPostProcessor = (
  mask: FooterMask,
  pages: PageScanInput[],
  opts: BuildFooterMaskOptions
) => FooterMask

/** Merge any number of FooterMask values into one (set-union per page). */
export function unionMasks(masks: FooterMask[]): FooterMask {
  const out: FooterMask = new Map()
  for (const m of masks) {
    for (const [page, items] of m) {
      let target = out.get(page)
      if (!target) {
        target = new Set<number>()
        out.set(page, target)
      }
      for (const ix of items) target.add(ix)
    }
  }
  return out
}
