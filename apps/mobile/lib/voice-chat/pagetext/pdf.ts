/**
 * T-P2.5 — CONTEXT-001: PDF pageText extractor.
 *
 * Source: `.parity-v2/SPEC.md` §3.8.
 *
 * Electron authority: `apps/rishi-electron/src/renderer/src/stores/
 * chatStore.ts:71` ships real rendered prose. Mobile previously sent the
 * literal string `"Page 4 of 100"` — a placeholder that defeats voice chat.
 *
 * On mobile the PDF reader can hydrate prose two ways:
 *   1. `readerRef.current.getPageText(pageNumber)` — the WebView's
 *      pdf.js bridge returns the rendered text for the visible page.
 *      Called eagerly per page-change in the reader and stashed as
 *      `extractedPageText`.
 *   2. Failing that, the per-book chunker-indexer has chunk texts
 *      keyed by page (the same texts the RAG search uses), which is
 *      a reasonable second-best.
 *
 * Contract (see __tests__/voice-chat/activation-context-pagetext.test.ts):
 *   - prefer `extractedPageText` when present
 *   - fall back to joining `indexerChunkTexts` (the chunks belonging to
 *     the current page) when extraction is unavailable
 *   - return '' (empty string) when neither source has anything — NEVER
 *     return the "Page N of M" placeholder
 *   - apply `softCapPageText` so dense pages don't blow up the prompt
 */
import { softCapPageText } from '@rishi/shared/voice-chat/pageTextCap'

const PAGE_TEXT_CAP = 8000

export interface GetPdfPageTextInput {
  /**
   * Output of `readerRef.current.getPageText(pageNumber)` once flattened
   * to a plain string (paragraphs joined with `\n`). Null when the
   * WebView hasn't responded yet, or when the bridge errored.
   */
  extractedPageText: string | null
  /**
   * Chunk texts from the per-book indexer that map to the current page.
   * Used as a second-best when pdf.js hasn't returned anything yet.
   */
  indexerChunkTexts: string[]
  /**
   * Current page number — passed for symmetry with call sites but NOT
   * used to synthesise a fallback string (that was the bug).
   */
  pageNumber: number
  /** Total page count, same reason. */
  pageCount: number
}

export function getPdfPageText(input: GetPdfPageTextInput): string {
  try {
    const { extractedPageText, indexerChunkTexts } = input

    const direct = extractedPageText?.trim()
    if (direct && direct.length > 0) {
      return softCapPageText(direct, PAGE_TEXT_CAP)
    }

    if (Array.isArray(indexerChunkTexts) && indexerChunkTexts.length > 0) {
      const joined = indexerChunkTexts
        .map((c) => (typeof c === 'string' ? c.trim() : ''))
        .filter((c) => c.length > 0)
        .join('\n\n')
      if (joined.length > 0) {
        return softCapPageText(joined, PAGE_TEXT_CAP)
      }
    }

    return ''
  } catch {
    return ''
  }
}
