import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import {
  normalizeFooterToken,
  type FooterMask,
  type PageScanInput,
  type BuildFooterMaskOptions
} from '../buildFooterMask'
import type { FooterStrategy } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * Flags items that share both a y-bin and a normalized text token across
 * a threshold proportion of pages. Catches page numbers, running titles,
 * and copyright lines — anything that repeats at the same baseline with
 * (after normalization) the same text.
 *
 * Extracted verbatim from the original `buildFooterMask` body so existing
 * behavior is preserved. The orchestrator unions this with other strategies.
 */
export const repetitionStrategy: FooterStrategy = (pages, opts) => {
  const mask: FooterMask = new Map()
  if (pages.length < opts.minPages) return mask

  // Sentinel: bail if pdf.js didn't give us recognizable y-coords.
  let totalItems = 0
  let withFiniteY = 0
  for (const p of pages) {
    for (const it of p.content.items) {
      if (!isTextItem(it)) continue
      totalItems++
      if (
        Array.isArray(it.transform) &&
        it.transform.length >= 6 &&
        Number.isFinite(it.transform[5])
      ) {
        withFiniteY++
      }
    }
  }
  if (totalItems === 0) return mask
  if (withFiniteY / totalItems < 0.05) return mask

  interface Candidate {
    pageNumber: number
    itemIndex: number
    y: number
    key: string
  }
  const candidatesByPage = new Map<number, Candidate[]>()
  const pagesByKey = new Map<string, Set<number>>()

  for (const p of pages) {
    const band = p.viewportHeight * opts.bottomBandPct
    const binUnit = p.viewportHeight * opts.yBinPct
    const items = p.content.items
    const pageCandidates: Candidate[] = []
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      if (y >= band) continue
      if (it.str.length > opts.maxCharsPerLine) continue

      const yBin = binUnit > 0 ? Math.round(y / binUnit) : 0
      const key = `${yBin} ${normalizeFooterToken(it.str)}`
      pageCandidates.push({ pageNumber: p.pageNumber, itemIndex: i, y, key })

      let set = pagesByKey.get(key)
      if (!set) {
        set = new Set()
        pagesByKey.set(key, set)
      }
      set.add(p.pageNumber)
    }
    if (pageCandidates.length > 0) candidatesByPage.set(p.pageNumber, pageCandidates)
  }

  const threshold = opts.repetitionThreshold * pages.length

  for (const p of pages) {
    const pageCandidates = candidatesByPage.get(p.pageNumber)
    if (!pageCandidates) continue
    const passing: Candidate[] = []
    for (const c of pageCandidates) {
      const pageSet = pagesByKey.get(c.key)
      if (pageSet && pageSet.size >= threshold) passing.push(c)
    }
    if (passing.length === 0) continue

    let chosen = passing
    if (passing.length > opts.maxFooterLines) {
      chosen = [...passing].sort((a, b) => a.y - b.y).slice(0, opts.maxFooterLines)
    }

    const indexSet = new Set<number>()
    for (const c of chosen) indexSet.add(c.itemIndex)
    mask.set(p.pageNumber, indexSet)
  }

  return mask
}
