import { parseParagraphIndex } from './highlight'
import type { ReadingPosition } from './pagination'

/**
 * Derive a ReadingPosition (chapter + page-within-chapter) from an AZW3/MOBI
 * paragraph id. Always lands on page 0 of the chapter — the column-paginated
 * reader will rerun viewport math after the chapter loads. Returns null when
 * the input isn't an `azw3-{chap}-{idx}` string.
 */
export function azw3ParagraphToLocation(idx: string): ReadingPosition | null {
  const parsed = parseParagraphIndex(idx)
  if (!parsed) return null
  return { chapter: parsed.chapter, page: 0 }
}
