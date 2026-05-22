/**
 * P1-K — "Read from selection" resolver for plain-text reader formats
 * (MOBI / AZW3 / DJVU).
 *
 * Symmetric with `resolveEpubReadFromSelection` (EPUB) and
 * `resolvePlayFromSelection` (PDF), but without the CFI fallback —
 * these formats don't expose CFI. The WebView reports a `selection`
 * message carrying the selected text; we find the paragraph (from the
 * seeded chunk list) whose text contains the selection's prefix and
 * call the shared `buildPartialFirst` to produce a sentence-aligned
 * PLAY_FROM payload.
 *
 * Pure function; no IPC, no DOM. The reader screens dispatch the
 * returned payload into the shared playerMachine via
 * `usePlayerStore.getState().send`.
 */

import { buildPartialFirst } from '@rishi/shared/modules/read-aloud-from'

export interface PlainTextPlayFromResult {
  paragraphIndex: number
  partialFirstText: string
  partialFirstKey: string
}

/**
 * Locate `selectionText` within `paragraphs` and return a PLAY_FROM
 * payload. Returns null when:
 *   - the selection is empty / whitespace,
 *   - the paragraph list is empty, or
 *   - the selection text isn't contained in any paragraph (the WebView
 *     normalized it differently from the extractor's output).
 */
export function resolvePlainTextReadFromSelection(
  selectionText: string,
  paragraphs: ReadonlyArray<{ index: string; text: string }>,
): PlainTextPlayFromResult | null {
  const trimmed = selectionText.trim()
  if (!trimmed) return null
  if (paragraphs.length === 0) return null

  // Use a short prefix as the search probe — robust against ligature
  // normalization / extra whitespace differences between the WebView's
  // DOM text and the extractor's plain text.
  const probe = trimmed.length > 50 ? trimmed.slice(0, 50) : trimmed

  const matchedIdx = paragraphs.findIndex((p) => p.text.includes(probe))
  if (matchedIdx === -1) return null

  const para = paragraphs[matchedIdx]
  const charOffset = Math.max(0, para.text.indexOf(probe))

  const { partialFirstText, partialFirstKey } = buildPartialFirst(
    para.index,
    para.text,
    charOffset,
  )

  return { paragraphIndex: matchedIdx, partialFirstText, partialFirstKey }
}
