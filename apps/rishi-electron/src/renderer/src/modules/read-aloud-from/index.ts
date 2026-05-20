export interface PartialFirst {
  /** Text from the sentence-start offset to end of paragraph. */
  partialFirstText: string
  /**
   * Stable TTS cache key. When `sentenceStartChar === 0` (selection lands in
   * the first sentence, so the partial equals the full paragraph) this is the
   * bare `paragraphIndex` — matching the key used by normal play/prefetch so
   * previously-cached audio is reused. Otherwise it is suffixed with
   * `#s=${sentenceStartChar}` because the audio is a strict subset and needs
   * its own cache entry.
   */
  partialFirstKey: string
  /** Char offset of the sentence start. 0 if selection is already at one. */
  sentenceStartChar: number
}

/**
 * Returns the character offset of the start of the sentence containing
 * `charOffset`. Uses Intl.Segmenter when available; falls back to a regex
 * scan otherwise.
 */
export function findSentenceStart(text: string, charOffset: number): number {
  if (text.length === 0) return 0
  const clamped = Math.min(Math.max(charOffset, 0), text.length)

  const Segmenter = (
    Intl as unknown as {
      Segmenter?: new (locale: string, opts: { granularity: string }) => unknown
    }
  ).Segmenter
  if (Segmenter) {
    const seg = new Segmenter('en', { granularity: 'sentence' }) as {
      segment(input: string): Iterable<{ index: number; segment: string }>
    }
    let lastStart = 0
    for (const piece of seg.segment(text)) {
      if (piece.index > clamped) break
      lastStart = piece.index
    }
    return lastStart
  }

  // Fallback via matchAll iteration (no .exec calls).
  let lastStart = 0
  for (const m of text.matchAll(/[.!?]+\s+/g)) {
    const candidate = (m.index ?? 0) + m[0].length
    if (candidate > clamped) break
    lastStart = candidate
  }
  return lastStart
}

export function buildPartialFirst(
  paragraphIndex: string,
  paragraphText: string,
  selectionStartChar: number
): PartialFirst {
  const sentenceStartChar = findSentenceStart(paragraphText, selectionStartChar)
  const partialFirstText = paragraphText.slice(sentenceStartChar)
  const partialFirstKey =
    sentenceStartChar === 0 ? paragraphIndex : `${paragraphIndex}#s=${sentenceStartChar}`
  return { partialFirstText, partialFirstKey, sentenceStartChar }
}
