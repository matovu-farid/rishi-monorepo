/**
 * Pure label / hint formatting helpers for the chat citation chip.
 * Mirrors electron's `SourceChip` (apps/rishi-electron/.../components/
 * chat/SourceChip.tsx) but lives in `lib/` so the unit tests can
 * import it under the jest node env without paying the React Native
 * runtime cost.
 *
 * The chip component (`SourceReference.tsx`) re-exports these.
 */

import type { SourceChunk } from '@/types/conversation'

const MAX_CHAPTER_CHARS = 17

/**
 * Match electron's `SourceChip` label formula:
 *   - Chapter present: `Ch. {chapter[..17]}` (with `...` ellipsis when
 *     truncated).
 *   - No chapter: fall back to `Source` so the chip is still readable.
 *
 * Electron also falls back to `p. {pageNumber}` for PDF citations. The
 * mobile `SourceChunk` shape doesn't carry `pageNumber` today, so the
 * branch is held until that field is added in a future RAG-pipeline
 * polish pass.
 */
const PAGE_PREFIX_RE = /^Page\s+(\d+)/i

export function formatSourceLabel(source: Pick<SourceChunk, 'chapter'>): string {
  const chapter = source.chapter?.trim()
  if (chapter && chapter.length > 0) {
    // Mobile encodes PDF / DJVU citations as `chapter = "Page N"` (see
    // lib/rag/chunker.ts pagesToSections). Render those as electron's
    // `p. N` to match the citation-chip parity goal.
    const pageMatch = chapter.match(PAGE_PREFIX_RE)
    if (pageMatch) {
      return `p. ${pageMatch[1]}`
    }
    return chapter.length > MAX_CHAPTER_CHARS
      ? `Ch. ${chapter.substring(0, MAX_CHAPTER_CHARS)}...`
      : `Ch. ${chapter}`
  }
  return 'Source'
}

/**
 * Match electron's tooltip: chapter (when present) on the first line,
 * then up to 100 characters of the chunk text. Newline-joined so screen
 * readers read it as two segments.
 */
export function formatSourceHint(
  source: Pick<SourceChunk, 'chapter' | 'text'>,
): string {
  const parts: string[] = []
  if (source.chapter && source.chapter.trim().length > 0) {
    parts.push(`Chapter: ${source.chapter}`)
  }
  const t = source.text ?? ''
  const snippet = t.length > 100 ? `${t.substring(0, 100)}...` : t
  if (snippet.length > 0) parts.push(snippet)
  return parts.join('\n')
}
