/**
 * "Read aloud from here" helpers. Ported verbatim from
 * `apps/rishi-electron/src/renderer/src/modules/read-aloud-from/index.ts`.
 *
 * Pure functions — no DOM, no IPC. Both electron and mobile consume this
 * to derive the partial-first paragraph (sentence-aligned slice starting
 * at the user's selection) and its stable cache key.
 */
/**
 * Returns the character offset of the start of the sentence containing
 * `charOffset`. Uses Intl.Segmenter when available; falls back to a regex
 * scan otherwise.
 */
export function findSentenceStart(text, charOffset) {
    if (text.length === 0)
        return 0;
    const clamped = Math.min(Math.max(charOffset, 0), text.length);
    const Segmenter = Intl.Segmenter;
    if (Segmenter) {
        const seg = new Segmenter('en', { granularity: 'sentence' });
        let lastStart = 0;
        for (const piece of seg.segment(text)) {
            if (piece.index > clamped)
                break;
            lastStart = piece.index;
        }
        return lastStart;
    }
    // Fallback via matchAll iteration (no .exec calls).
    let lastStart = 0;
    for (const m of text.matchAll(/[.!?]+\s+/g)) {
        const candidate = (m.index ?? 0) + m[0].length;
        if (candidate > clamped)
            break;
        lastStart = candidate;
    }
    return lastStart;
}
export function buildPartialFirst(paragraphIndex, paragraphText, selectionStartChar) {
    const sentenceStartChar = findSentenceStart(paragraphText, selectionStartChar);
    const partialFirstText = paragraphText.slice(sentenceStartChar);
    const partialFirstKey = sentenceStartChar === 0 ? paragraphIndex : `${paragraphIndex}#s=${sentenceStartChar}`;
    return { partialFirstText, partialFirstKey, sentenceStartChar };
}
