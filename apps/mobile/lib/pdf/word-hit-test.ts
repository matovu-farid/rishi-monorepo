export interface WordRow {
  idx: number
  text: string
  x: number; y: number; w: number; h: number
}

export function findWordAtPdfPoint(
  words: WordRow[],
  point: { x: number; y: number },
): WordRow | null {
  for (const w of words) {
    if (
      point.x >= w.x &&
      point.x <= w.x + w.w &&
      point.y >= w.y &&
      point.y <= w.y + w.h
    ) {
      return w
    }
  }
  return null
}

export function wordsBetween(
  words: WordRow[],
  a: WordRow,
  b: WordRow,
): WordRow[] {
  const lo = Math.min(a.idx, b.idx)
  const hi = Math.max(a.idx, b.idx)
  return words.filter((w) => w.idx >= lo && w.idx <= hi)
}
