import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'

/**
 * A text item paired with its index into the ORIGINAL `items[]` array (the one
 * pdf.js returns, including non-text marked-content entries). Keeping the
 * original index is essential: the footer-mask builders address items by their
 * stream index, so reordering must not renumber them.
 */
export interface OrderedTextItem {
  item: TextItem
  index: number
}

interface Entry {
  item: TextItem
  index: number
  x: number
  right: number
  y: number
  height: number
}

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

function hasFiniteY(item: TextItem): boolean {
  return (
    Array.isArray(item.transform) &&
    item.transform.length >= 6 &&
    Number.isFinite(item.transform[4]) &&
    Number.isFinite(item.transform[5])
  )
}

function median(values: number[]): number {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/**
 * Find a vertical gutter that splits the page into two columns. Returns the
 * gutter x-position, or null when the page reads as a single column.
 *
 * A gutter is an x where almost no text item spans across (low "crossing"
 * count) AND there is a substantial, balanced amount of text on either side.
 * Single-column pages fail the balance test because their lines span the full
 * width, so every central x either crosses most lines or leaves one side empty.
 * A handful of full-width items (titles, figures) are tolerated via the
 * crossing budget so they don't suppress a real two-column layout.
 */
function detectGutter(entries: Entry[]): number | null {
  const N = entries.length
  if (N < 6) return null

  let contentLeft = Infinity
  let contentRight = -Infinity
  for (const e of entries) {
    if (e.x < contentLeft) contentLeft = e.x
    if (e.right > contentRight) contentRight = e.right
  }
  const width = contentRight - contentLeft
  if (!(width > 0)) return null

  const lo = contentLeft + width * 0.3
  const hi = contentLeft + width * 0.7
  const step = Math.max(1, width / 200)

  const crossingBudget = N * 0.1
  const minSide = Math.max(2, Math.floor(N * 0.15))

  let best: { gx: number; crossings: number; balance: number } | null = null
  for (let gx = lo; gx <= hi; gx += step) {
    let crossings = 0
    let leftCount = 0
    let rightCount = 0
    for (const e of entries) {
      if (e.x < gx && e.right > gx) crossings++
      const center = (e.x + e.right) / 2
      if (center < gx) leftCount++
      else rightCount++
    }
    if (crossings > crossingBudget) continue
    if (leftCount < minSide || rightCount < minSide) continue
    const balance = Math.abs(leftCount - rightCount)
    if (!best || crossings < best.crossings || (crossings === best.crossings && balance < best.balance)) {
      best = { gx, crossings, balance }
    }
  }

  return best ? best.gx : null
}

/**
 * Order text items into reading order: top-to-bottom, left-to-right, with
 * line-bucketing so a raised superscript stays attached to its line instead of
 * being hoisted above it, and column-awareness so a two-column page reads the
 * left column fully before the right.
 *
 * pdf.js returns items in content-stream order, which is NOT guaranteed to be
 * visual reading order — footnote blocks in particular are frequently emitted
 * before the body. This pass restores reading order while preserving each
 * item's original stream index for footer-mask compatibility.
 */
function orderGroup(entries: Entry[]): Entry[] {
  if (entries.length <= 1) return entries

  const lineTol = Math.max(2, median(entries.map((e) => e.height)) * 0.5)

  // Sort by y descending (top first), x ascending as a tiebreak.
  const sorted = [...entries].sort((a, b) => (b.y !== a.y ? b.y - a.y : a.x - b.x))

  // Bucket into lines: an item joins the current line when it is within lineTol
  // of the previous item's baseline.
  const lines: Entry[][] = []
  let current: Entry[] = []
  let prevY = Number.POSITIVE_INFINITY
  for (const e of sorted) {
    if (current.length === 0 || prevY - e.y <= lineTol) {
      current.push(e)
    } else {
      lines.push(current)
      current = [e]
    }
    prevY = e.y
  }
  if (current.length > 0) lines.push(current)

  const out: Entry[] = []
  for (const line of lines) {
    line.sort((a, b) => a.x - b.x)
    for (const e of line) out.push(e)
  }
  return out
}

export function orderTextItemsForReading(
  items: (TextItem | TextMarkedContent)[]
): OrderedTextItem[] {
  const entries: Entry[] = []
  let textItemCount = 0
  let finiteCount = 0
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    if (!isTextItem(item)) continue
    textItemCount++
    if (!hasFiniteY(item)) continue
    finiteCount++
    const x = item.transform[4]
    entries.push({
      item,
      index: i,
      x,
      right: x + (Number.isFinite(item.width) ? item.width : 0),
      y: item.transform[5],
      height: Number.isFinite(item.height) ? item.height : 0
    })
  }

  // If coordinates are unreliable (some text items lack finite positions),
  // fall back to stream order rather than risk scrambling the page.
  if (textItemCount === 0 || finiteCount < textItemCount) {
    const out: OrderedTextItem[] = []
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      if (isTextItem(item)) out.push({ item, index: i })
    }
    return out
  }

  const gutter = detectGutter(entries)
  let ordered: Entry[]
  if (gutter == null) {
    ordered = orderGroup(entries)
  } else {
    const left: Entry[] = []
    const right: Entry[] = []
    for (const e of entries) {
      if ((e.x + e.right) / 2 < gutter) left.push(e)
      else right.push(e)
    }
    ordered = [...orderGroup(left), ...orderGroup(right)]
  }

  return ordered.map((e) => ({ item: e.item, index: e.index }))
}
