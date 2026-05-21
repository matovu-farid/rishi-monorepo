/**
 * Mobile "read aloud from selection" coordinator. The PDF WebView
 * reports a `selection` message with the selected text and a
 * `PdfLocator`. To translate that into a PLAY_FROM event for the shared
 * playerMachine we:
 *
 *   1. Find the paragraph (from the WebView's getPageText result) whose
 *      text contains the selected substring.
 *   2. Compute the char offset of the selection within that paragraph.
 *   3. Run `buildPartialFirst` from the shared module to produce a
 *      sentence-aligned partial-first text + cache key.
 *
 * Pure function; no IPC, no DOM. Symmetric with electron's
 * `apps/rishi-electron/src/renderer/src/hooks/usePdfReadAloudFromSelection.ts`
 * but takes the paragraph list as an argument so test code doesn't have
 * to mount a player store.
 */

import { buildPartialFirst } from '@rishi/shared/modules/read-aloud-from'

export interface PlayFromResult {
  paragraphIndex: number
  partialFirstText: string
  partialFirstKey: string
}

/**
 * Returns the PLAY_FROM event payload, or null if the selection text
 * couldn't be located within the supplied paragraphs (which means TTS
 * shouldn't start because we can't sync the highlight).
 */
export function resolvePlayFromSelection(
  selectionText: string,
  paragraphs: ReadonlyArray<{ index: string; text: string }>
): PlayFromResult | null {
  const trimmed = selectionText.trim()
  if (!trimmed) return null
  if (paragraphs.length === 0) return null

  // Selections that span a paragraph boundary should start playback at
  // the paragraph that holds the beginning of the selection. Use a
  // short prefix as the search probe to make this resilient against
  // text-extraction quirks (extra whitespace, ligature normalization).
  const probe = trimmed.length > 50 ? trimmed.slice(0, 50) : trimmed

  const matchedIdx = paragraphs.findIndex((p) => p.text.includes(probe))
  if (matchedIdx === -1) return null

  const para = paragraphs[matchedIdx]
  const charOffset = Math.max(0, para.text.indexOf(probe))

  const { partialFirstText, partialFirstKey } = buildPartialFirst(
    para.index,
    para.text,
    charOffset
  )

  return { paragraphIndex: matchedIdx, partialFirstText, partialFirstKey }
}
