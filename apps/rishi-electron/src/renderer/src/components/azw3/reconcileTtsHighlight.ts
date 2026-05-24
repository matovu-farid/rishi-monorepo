import { findParagraphElement, parseParagraphIndex, TTS_ACTIVE_CLASS } from './highlight'

/**
 * Idempotently converge the AZW3 iframe document to show exactly the TTS
 * highlight implied by `desiredIndex`. Removes any stale `.rishi-tts-active`
 * class found in the document; applies the class to the desired paragraph
 * if it belongs to the currently-loaded chapter and the element resolves.
 *
 * Silent recovery: if the desired paragraph is in a different chapter or
 * the element is not present, the reconciler still clears stale markup
 * but adds nothing. The next reconcile (on iframe load, focus return, or
 * the next activeParagraph change) will reapply.
 */
export function reconcileAzw3TtsHighlight(
  iframeDoc: Document | null,
  currentChapterIndex: number,
  desiredIndex: string | null
): void {
  if (!iframeDoc) return

  let desiredEl: Element | null = null
  if (desiredIndex) {
    const parsed = parseParagraphIndex(desiredIndex)
    if (parsed?.chapter === currentChapterIndex) {
      desiredEl = findParagraphElement(iframeDoc, parsed.paragraph)
    }
  }

  const existing = iframeDoc.querySelectorAll(`.${TTS_ACTIVE_CLASS}`)
  for (const el of Array.from(existing)) {
    if (el !== desiredEl) el.classList.remove(TTS_ACTIVE_CLASS)
  }
  if (desiredEl && !desiredEl.classList.contains(TTS_ACTIVE_CLASS)) {
    desiredEl.classList.add(TTS_ACTIVE_CLASS)
  }
}
