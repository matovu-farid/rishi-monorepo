/**
 * Active-paragraph highlight wiring for the AZW3 iframe reader.
 *
 * Paragraph indices flowing through playerStore look like
 * `azw3-{chapterIndex}-{i}`. `i` is the offset into the same list that
 * `extractSectionParagraphs` builds: text-bearing nodes matching
 * PARA_SELECTOR. We mirror that filter here so the i-th element we touch in
 * the iframe matches the i-th text item the TTS pipeline sees.
 */
export const PARA_SELECTOR = 'p, h1, h2, h3, h4, h5, h6, li, blockquote'
export const TTS_ACTIVE_CLASS = 'rishi-tts-active'

/** Parse `azw3-{chap}-{idx}` → `{ chapter, paragraph }`. Returns null on a
 *  malformed input so callers can no-op safely. */
export function parseParagraphIndex(
  raw: string
): { chapter: number; paragraph: number } | null {
  const m = /^azw3-(\d+)-(\d+)$/.exec(raw)
  if (!m) return null
  const chapter = Number(m[1])
  const paragraph = Number(m[2])
  if (!Number.isFinite(chapter) || !Number.isFinite(paragraph)) return null
  return { chapter, paragraph }
}

/**
 * Locate the i-th text-bearing paragraph element in the iframe document,
 * matching the same selector + empty-trim filter as
 * `extractSectionParagraphs`. Returns null when the doc is unavailable or
 * the index is out of range.
 */
export function findParagraphElement(
  doc: Document | null | undefined,
  paragraphIndex: number
): Element | null {
  if (!doc) return null
  const nodes = doc.querySelectorAll(PARA_SELECTOR)
  let visible = -1
  for (const node of Array.from(nodes)) {
    const text = (node.textContent ?? '').trim()
    if (text.length === 0) continue
    visible += 1
    if (visible === paragraphIndex) return node
  }
  return null
}

/** Toggle the TTS active-paragraph class on a single element. */
export function setActiveClass(el: Element | null, on: boolean): void {
  if (!el) return
  el.classList.toggle(TTS_ACTIVE_CLASS, on)
}
