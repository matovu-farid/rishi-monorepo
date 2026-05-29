import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'

// A footnote is flagged only when BOTH signals agree, to keep false positives
// (eating real body text) low:
//   1. Font notably smaller than the page's dominant body font.
//   2. Separated from the bottom of the body by an oversized vertical gap.
const SMALL_FONT_RATIO = 0.85
const MIN_GAP_MULT = 1.5

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

function hasFiniteY(item: TextItem): boolean {
  return (
    Array.isArray(item.transform) && item.transform.length >= 6 && Number.isFinite(item.transform[5])
  )
}

function median(values: number[]): number {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

interface Entry {
  index: number
  y: number
  height: number
  hasText: boolean
}

/**
 * Detect bottom-of-page footnote items and return their indices into the
 * ORIGINAL `items[]` array (so callers can exclude them by stream index, the
 * same addressing the footer masks use).
 *
 * Footnotes never repeat across pages, so the repetition-based footer mask
 * cannot catch them. This positional heuristic complements it: it looks for a
 * contiguous run of smaller-font items sitting below the body, separated by a
 * gap larger than normal line spacing. A mid-page superscript reference is
 * small-font too but lives above the body bottom, so it is never flagged.
 */
export function detectFootnoteItems(items: (TextItem | TextMarkedContent)[]): Set<number> {
  const result = new Set<number>()

  const entries: Entry[] = []
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    if (!isTextItem(item) || !hasFiniteY(item)) continue
    entries.push({
      index: i,
      y: item.transform[5],
      height: Number.isFinite(item.height) ? item.height : 0,
      hasText: item.str.trim().length > 0
    })
  }
  if (entries.length === 0) return result

  const bodyHeight = median(entries.filter((e) => e.hasText && e.height > 0).map((e) => e.height))
  if (!(bodyHeight > 0)) return result

  const smallThreshold = bodyHeight * SMALL_FONT_RATIO
  const minGap = bodyHeight * MIN_GAP_MULT

  // Bottom of the real body = bottom of the LARGEST cluster of body-sized
  // lines. Clustering by line-spacing isolates the main text block from
  // body-sized chrome like a lone page number or a heading, which would
  // otherwise drag the "body bottom" past the footnote and hide it.
  const bodySized = entries
    .filter((e) => e.hasText && e.height >= smallThreshold)
    .sort((a, b) => b.y - a.y)
  if (bodySized.length === 0) return result

  const clusterGap = bodyHeight * 2
  let bestBottom = bodySized[0].y
  let bestCount = 0
  let curBottom = bodySized[0].y
  let curCount = 1
  for (let i = 1; i < bodySized.length; i++) {
    if (bodySized[i - 1].y - bodySized[i].y <= clusterGap) {
      curCount++
      curBottom = bodySized[i].y
    } else {
      if (curCount > bestCount) {
        bestCount = curCount
        bestBottom = curBottom
      }
      curCount = 1
      curBottom = bodySized[i].y
    }
  }
  if (curCount > bestCount) {
    bestCount = curCount
    bestBottom = curBottom
  }
  const bodyBottomY = bestBottom

  // Smaller-font items strictly below the body.
  const belowSmall = entries.filter((e) => e.height > 0 && e.height < smallThreshold && e.y < bodyBottomY)
  if (belowSmall.length === 0) return result

  // The block must be separated from the body by an oversized gap.
  const footnoteTopY = Math.max(...belowSmall.map((e) => e.y))
  if (bodyBottomY - footnoteTopY < minGap) return result

  for (const e of belowSmall) result.add(e.index)
  return result
}
