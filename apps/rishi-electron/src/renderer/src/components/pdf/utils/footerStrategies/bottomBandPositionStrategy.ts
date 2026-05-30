import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import type { FooterMask } from '../buildFooterMask'
import type { FooterStrategy } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * Position-only footer detector. For each y-bin within the bottom band,
 * counts how many pages have ANY text-bearing item at that y-bin
 * (text content does not have to match). If the count crosses the
 * repetition threshold, every item at that y-bin on those pages is
 * flagged.
 *
 * Catches footer lines where the text varies per chapter (chapter titles)
 * but the baseline is stable across the book — the case the existing
 * text-keyed repetitionStrategy misses.
 *
 * KNOWN TRADE-OFF: position-only with no font/text signal will false-positive
 * on documents where legitimate body text consistently lands at the same
 * bottom y-bin across pages (e.g. a novel where the last paragraph wraps
 * to the bottom on enough pages to cross the repetition threshold).
 * `expandToLineMates` then widens the silence to the rest of that baseline.
 * Acceptable for the target case (technical books with chapter-title
 * footers); if user reports surface for prose-heavy PDFs, tighten by:
 *   - raising the threshold above DEFAULT_FOOTER_MASK_OPTIONS.repetitionThreshold
 *   - adding a font-size delta vs the body-text cluster as a secondary gate
 *   - exposing a per-book pref to disable position-only flagging
 */
export const bottomBandPositionStrategy: FooterStrategy = (pages, opts) => {
  const mask: FooterMask = new Map()
  if (pages.length < opts.minPages) return mask

  interface BandItem {
    pageNumber: number
    itemIndex: number
    yBin: number
  }
  const itemsByPage = new Map<number, BandItem[]>()
  const pagesByBin = new Map<number, Set<number>>()

  for (const p of pages) {
    const band = p.viewportHeight * opts.bottomBandPct
    const binUnit = p.viewportHeight * opts.yBinPct
    if (binUnit <= 0) continue
    const pageBandItems: BandItem[] = []
    for (let i = 0; i < p.content.items.length; i++) {
      const it = p.content.items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      if (y >= band) continue
      const yBin = Math.round(y / binUnit)
      pageBandItems.push({ pageNumber: p.pageNumber, itemIndex: i, yBin })

      let set = pagesByBin.get(yBin)
      if (!set) {
        set = new Set()
        pagesByBin.set(yBin, set)
      }
      set.add(p.pageNumber)
    }
    if (pageBandItems.length > 0) itemsByPage.set(p.pageNumber, pageBandItems)
  }

  const threshold = opts.repetitionThreshold * pages.length

  for (const p of pages) {
    const bandItems = itemsByPage.get(p.pageNumber)
    if (!bandItems) continue
    const indexSet = new Set<number>()
    for (const bi of bandItems) {
      const pageSet = pagesByBin.get(bi.yBin)
      if (pageSet && pageSet.size >= threshold) {
        indexSet.add(bi.itemIndex)
      }
    }
    if (indexSet.size > 0) mask.set(p.pageNumber, indexSet)
  }

  return mask
}
