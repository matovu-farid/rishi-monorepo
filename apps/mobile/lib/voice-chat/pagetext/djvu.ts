/**
 * T-P2.5 — CONTEXT-001: DJVU pageText extractor.
 *
 * Source: `.parity-v2/SPEC.md` §3.8.
 *
 * Electron authority: `apps/rishi-electron/src/renderer/src/stores/
 * chatStore.ts:71`. Mobile previously sent `"Page N of M"`.
 *
 * DJVU pages are canvas-only on mobile — there is no DOM text layer to
 * scrape. The per-book chunker-indexer however already pre-extracts an
 * OCR text layer (the same one driving RAG search), so we plumb its
 * chunk texts for the current page into the activation context.
 *
 * Contract (see __tests__/voice-chat/activation-context-pagetext.test.ts):
 *   - join `indexerChunkTexts` (chunks for the current page) when non-empty
 *   - return '' when the indexer has nothing for the page — NEVER fall
 *     back to the "Page N of M" placeholder
 *   - apply `softCapPageText`
 */
import { softCapPageText } from '@rishi/shared/voice-chat/pageTextCap'

const PAGE_TEXT_CAP = 8000

export interface GetDjvuPageTextInput {
  /** Indexer chunk texts for the current page. */
  indexerChunkTexts: string[]
  /** Current page — kept for symmetry, NOT used as a fallback. */
  pageNumber: number
  /** Total page count — same. */
  pageCount: number
}

export function getDjvuPageText(input: GetDjvuPageTextInput): string {
  try {
    const { indexerChunkTexts } = input
    if (!Array.isArray(indexerChunkTexts) || indexerChunkTexts.length === 0) {
      return ''
    }
    const joined = indexerChunkTexts
      .map((c) => (typeof c === 'string' ? c.trim() : ''))
      .filter((c) => c.length > 0)
      .join('\n\n')
    if (joined.length === 0) return ''
    return softCapPageText(joined, PAGE_TEXT_CAP)
  } catch {
    return ''
  }
}
