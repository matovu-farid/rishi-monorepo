/**
 * EPUB "read from selection" resolver (G17).
 *
 * Symmetric with `lib/pdf/read-aloud-from-selection.resolvePlayFromSelection`
 * — translates an EPUB selection (cfiRange + text) plus a paragraph list
 * (each paragraph carries a `cfi` `index` from epubjs) into a PLAY_FROM
 * payload for the shared playerMachine.
 *
 * Matching is text-first: we try to find the paragraph whose `text`
 * includes the trimmed selection (prefix). EPUB selection text is often
 * normalized (extra whitespace, ligatures) so the text match is robust.
 * If that fails we fall back to the shared cfi-to-paragraph helper,
 * which compares the selection's start CFI against each paragraph's
 * CFI range.
 *
 * Returns null when neither match resolves — caller should surface a
 * user-friendly "Couldn't start reading" message and abort.
 */

import { buildPartialFirst } from '@rishi/shared/modules/read-aloud-from'
import { findParagraphForCfi } from '@rishi/shared/modules/cfi-to-paragraph'

export interface EpubPlayFromResult {
  paragraphIndex: number
  partialFirstText: string
  partialFirstKey: string
}

export function resolveEpubReadFromSelection(
  selectionText: string,
  selectionCfiRange: string,
  paragraphs: ReadonlyArray<{ index: string; text: string }>,
): EpubPlayFromResult | null {
  const trimmed = selectionText.trim()
  if (!trimmed) return null
  if (paragraphs.length === 0) return null

  // --- Text-first match (matches the PDF resolver) -------------------------
  const probe = trimmed.length > 50 ? trimmed.slice(0, 50) : trimmed
  const textMatchIdx = paragraphs.findIndex((p) => p.text.includes(probe))

  if (textMatchIdx !== -1) {
    const para = paragraphs[textMatchIdx]
    const charOffset = Math.max(0, para.text.indexOf(probe))
    const { partialFirstText, partialFirstKey } = buildPartialFirst(
      para.index,
      para.text,
      charOffset,
    )
    return {
      paragraphIndex: textMatchIdx,
      partialFirstText,
      partialFirstKey,
    }
  }

  // --- Fallback: CFI-based match -------------------------------------------
  // The shared helper compares the selection's start CFI against each
  // paragraph's CFI range using epubjs's EpubCFI.compare.
  try {
    const match = findParagraphForCfi(
      paragraphs as Array<{ index: string; text: string }>,
      selectionCfiRange,
    )
    if (!match) return null
    const para = paragraphs[match.paragraphIndex]
    const { partialFirstText, partialFirstKey } = buildPartialFirst(
      para.index,
      para.text,
      match.charOffsetInParagraph,
    )
    return {
      paragraphIndex: match.paragraphIndex,
      partialFirstText,
      partialFirstKey,
    }
  } catch {
    return null
  }
}
