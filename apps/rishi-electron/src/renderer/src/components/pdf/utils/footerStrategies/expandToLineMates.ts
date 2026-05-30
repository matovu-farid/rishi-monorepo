import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import type { FooterMask } from '../buildFooterMask'
import type { FooterPostProcessor } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * For each item already flagged on a page, also flag its baseline-mates
 * (items at the same y-bin on the same page). Pulls in mixed-content
 * footer chrome like "2 | Chapter 1: Introduction" where only "2" got
 * caught by an earlier strategy.
 *
 * Pure post-processor — operates on the already-merged mask, never mutates
 * its inputs, and produces a fresh FooterMask.
 */
export const expandToLineMates: FooterPostProcessor = (mask, pages, opts) => {
  if (mask.size === 0) return new Map()

  const pageByNumber = new Map<number, (typeof pages)[number]>()
  for (const p of pages) pageByNumber.set(p.pageNumber, p)

  const out: FooterMask = new Map()
  for (const [pageNumber, flaggedItems] of mask) {
    const page = pageByNumber.get(pageNumber)
    if (!page) {
      out.set(pageNumber, new Set(flaggedItems))
      continue
    }
    const binUnit = page.viewportHeight * opts.yBinPct
    if (binUnit <= 0) {
      out.set(pageNumber, new Set(flaggedItems))
      continue
    }

    // Resolve the y-bins that already have flagged items on this page.
    const flaggedBins = new Set<number>()
    for (const ix of flaggedItems) {
      const it = page.content.items[ix]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      flaggedBins.add(Math.round(y / binUnit))
    }

    // Walk every item on the page and flag any whose y-bin is in the set.
    const expanded = new Set<number>(flaggedItems)
    for (let i = 0; i < page.content.items.length; i++) {
      const it = page.content.items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      const bin = Math.round(y / binUnit)
      if (flaggedBins.has(bin)) expanded.add(i)
    }
    out.set(pageNumber, expanded)
  }
  return out
}
