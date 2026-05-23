import type { FooterMask, PageScanInput } from './buildFooterMask'
import { normalizeFooterToken } from './buildFooterMask'
import { pageDataToParagraphsWithItemIndices } from './getPageParagraphs'

export interface SuffixMatchOptions {
  /** Don't engage below this page count. Default 8. */
  minPages: number
  /** How many paragraphs from the bottom of each page to consider. Default 6. */
  suffixDepth: number
  /** Pages-share threshold. Default 0.30. */
  threshold: number
}

export const DEFAULT_SUFFIX_MATCH_OPTIONS: SuffixMatchOptions = {
  minPages: 8,
  suffixDepth: 6,
  threshold: 0.3
}

/**
 * Detect footers that span multiple of our internal paragraph divisions by
 * pattern-matching the bottom-most paragraphs across pages. Complements the
 * spatial item-level `buildFooterMask`: an entire copyright block can be
 * grouped logically (not spatially) into one or more paragraphs, and we want
 * to mask each one independently when it repeats verbatim near the foot of
 * many pages.
 */
export function findRepeatingPageSuffix(
  pages: PageScanInput[],
  opts: Partial<SuffixMatchOptions> = {}
): FooterMask {
  const o: SuffixMatchOptions = { ...DEFAULT_SUFFIX_MATCH_OPTIONS, ...opts }
  const mask: FooterMask = new Map()

  if (pages.length < o.minPages) return mask

  // Per-page bottom-most slice in spatial order (smallest `bottom` first, i.e.
  // the LOWEST paragraph on the page since PDF Y grows up from the bottom).
  interface SuffixEntry {
    text: string
    itemIndices: number[]
  }
  const suffixesByPage = new Map<number, SuffixEntry[]>()

  for (const p of pages) {
    const assembled = pageDataToParagraphsWithItemIndices(p.pageNumber, p.content)
    if (assembled.length === 0) continue
    const sorted = [...assembled].sort(
      (a, b) => a.paragraph.dimensions.bottom - b.paragraph.dimensions.bottom
    )
    const slice = sorted.slice(0, o.suffixDepth).map((entry) => ({
      text: normalizeFooterToken(entry.paragraph.text),
      itemIndices: entry.itemIndices
    }))
    suffixesByPage.set(p.pageNumber, slice)
  }

  const threshold = o.threshold * pages.length

  for (let d = 0; d < o.suffixDepth; d++) {
    // text -> pages where this depth-d paragraph appears
    const pagesByText = new Map<string, Set<number>>()
    for (const p of pages) {
      const slice = suffixesByPage.get(p.pageNumber)
      if (!slice || slice.length <= d) continue
      const entry = slice[d]
      if (entry.itemIndices.length === 0) continue
      if (entry.text.length === 0) continue
      let set = pagesByText.get(entry.text)
      if (!set) {
        set = new Set()
        pagesByText.set(entry.text, set)
      }
      set.add(p.pageNumber)
    }

    for (const [text, pageSet] of pagesByText) {
      if (pageSet.size < threshold) continue
      for (const pageNumber of pageSet) {
        const slice = suffixesByPage.get(pageNumber)
        if (!slice || slice.length <= d) continue
        const entry = slice[d]
        if (entry.text !== text) continue
        let target = mask.get(pageNumber)
        if (!target) {
          target = new Set<number>()
          mask.set(pageNumber, target)
        }
        for (const ix of entry.itemIndices) target.add(ix)
      }
    }
  }

  return mask
}
