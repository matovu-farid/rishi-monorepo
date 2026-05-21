/**
 * Resolve a paragraph index to its DOM element. Ported from
 * `apps/rishi-electron/src/renderer/src/services/tts/index.ts`
 * (resolveParagraphElement helper).
 *
 * Unlike the electron version, this function does NOT reach into a global
 * EPUB-frame registry. Callers pass the body (or any container) directly,
 * keeping the function pure and platform-agnostic.
 */

/**
 * Returns the Nth paragraph-like element in `body`, or `null` when no
 * such element exists. The element predicate matches the same set of
 * tags as electron: `p, h1, h2, h3, h4, h5, h6, blockquote, li`.
 */
export function resolveParagraphElement(
  body: Element | null | undefined,
  paragraphIndexInPage: number
): Element | null {
  if (!body) return null
  const candidates = body.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li')
  return candidates[paragraphIndexInPage] ?? null
}
