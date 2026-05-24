/**
 * Map a chat-source citation onto the navigation params the reader for
 * the book's format honors at mount (#68).
 *
 * `handleSourcePress` previously discarded `source.chunkId` /
 * `source.chapter`, so tapping a citation chip just opened the reader at
 * the user's last position — the citation was non-actionable. This
 * helper centralises the per-format parse so the chat screen stays free
 * of chunker-internal naming.
 *
 * What the chunker actually puts in `chapter`:
 *   - PDF / DJVU  → `"Page N"`            (see lib/rag/chunker.ts
 *                                          pagesToSections)
 *   - MOBI / AZW3 → `"Chapter N"`         (1-indexed label, 0-indexed
 *                                          internally — see chunker.ts
 *                                          mobi branch)
 *   - EPUB        → free-form heading text or null (no CFI is captured
 *                                          today; `cfiRange` is reserved
 *                                          on SourceChunk for a future
 *                                          enrichment pass)
 *
 * The returned params are merged into `router.push({ pathname, params })`
 * by the chat screen. The reader screens read them via
 * `useLocalSearchParams`.
 */

import type { Book } from '@/types/book'
import type { SourceChunk } from '@/types/conversation'

const PAGE_PREFIX_RE = /^Page\s+(\d+)/i
const CHAPTER_PREFIX_RE = /^Chapter\s+(\d+)/i

export type SourceLocationParams = Record<string, string>

/**
 * Resolve the per-format query params for a citation tap. Always
 * includes the bookId (the dynamic route segment) and `chunkId` (a
 * stable handle the reader can use later to scroll to the exact passage
 * once highlight-on-jump lands).
 *
 * Returns `{ id, chunkId }` only when nothing positional can be parsed —
 * the reader still navigates, just to the saved position. That's
 * strictly better than the pre-fix behaviour because the chunkId still
 * travels for downstream consumers.
 */
export function resolveSourceLocationParams(
  book: Pick<Book, 'id' | 'format'>,
  source: Pick<SourceChunk, 'chunkId' | 'chapter' | 'cfiRange'>,
): SourceLocationParams {
  const params: SourceLocationParams = { id: book.id }
  if (source.chunkId) params.chunkId = source.chunkId

  switch (book.format) {
    case 'pdf':
    case 'djvu': {
      const m = source.chapter?.match(PAGE_PREFIX_RE)
      if (m) params.page = m[1]
      return params
    }
    case 'mobi':
    case 'azw3': {
      const m = source.chapter?.match(CHAPTER_PREFIX_RE)
      if (m) {
        // Chunker's MOBI label is 1-indexed ("Chapter 1"); the reader
        // store is 0-indexed. Normalise here so the reader can do a
        // straight `setCurrentChapter(Number(params.chapter))`.
        const oneIndexed = Number.parseInt(m[1], 10)
        if (Number.isFinite(oneIndexed) && oneIndexed >= 1) {
          params.chapter = String(oneIndexed - 1)
        }
      }
      return params
    }
    case 'epub':
    default: {
      // EPUB chunks don't carry a CFI today, but `cfiRange` is reserved
      // on SourceChunk for the next enrichment pass — forward it so the
      // reader can honor `?cfi=...` once the pipeline starts populating
      // it. Fall back to the chapter heading label so the reader can do
      // a best-effort TOC-label match (`toc[].label === chapter` →
      // `goToLocation(href)`).
      if (source.cfiRange) params.cfi = source.cfiRange
      else if (source.chapter && source.chapter.trim().length > 0) {
        params.chapter = source.chapter.trim()
      }
      return params
    }
  }
}

/**
 * The `pathname` template for a per-format reader route. Mirrors
 * `resolveReaderRouteForBook` (which returns a concrete string with the
 * id substituted) but keeps the bracket form so it can be passed to
 * `router.push({ pathname, params })` — expo-router substitutes the
 * `[id]` segment from `params.id`.
 */
export function resolveReaderPathnameForBook(
  format: Book['format'],
): `/reader/[id]` | `/reader/pdf/[id]` | `/reader/mobi/[id]` | `/reader/djvu/[id]` {
  switch (format) {
    case 'pdf':
      return '/reader/pdf/[id]'
    case 'mobi':
    case 'azw3':
      return '/reader/mobi/[id]'
    case 'djvu':
      return '/reader/djvu/[id]'
    case 'epub':
    default:
      return '/reader/[id]'
  }
}
