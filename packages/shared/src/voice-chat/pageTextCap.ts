/**
 * T-P2.5 — CONTEXT-001: shared `softCapPageText` helper.
 *
 * Source: `.parity-v2/SPEC.md` §3.8.
 *
 * Soft-caps the rendered page prose that mobile readers pass into the
 * voice-chat `getActivationContext().pageText` field, so a 200-page novel
 * chapter doesn't blow up the realtime prompt.
 *
 * Electron's contract (see `apps/rishi-electron/src/renderer/src/stores/
 * chatStore.ts:71`) is simply `currentParagraphs.map(p => p.text).join('\n')`
 * — there is no explicit cap because the electron player already chunks
 * paragraphs into the visible viewport. Mobile, by contrast, has to fall
 * back to whole-chapter or whole-page extractions where a single payload
 * can run into the tens of thousands of characters, so a soft cap is
 * required here even though electron does not apply one.
 *
 * Behaviour (see softCapPageText.test.ts):
 *   - Length ≤ cap → input unchanged, no suffix.
 *   - Length > cap → trim to a clean boundary, preferring (in order):
 *       1. last `\n\n` before the cap (paragraph break)
 *       2. last `. ` before the cap (sentence boundary)
 *       3. last whitespace before the cap (word boundary)
 *       4. hard cut at the cap
 *     …then append `suffix` (default `\n[text truncated]`).
 *   - Empty input → '' (no throw, no suffix).
 *
 * The helper is pure and dependency-free so it can be unit-tested in
 * both the shared package (vitest) and the mobile app (jest).
 */

const DEFAULT_SUFFIX = '\n[text truncated]'

export function softCapPageText(
  input: string,
  cap: number,
  suffix: string = DEFAULT_SUFFIX,
): string {
  if (input.length === 0) return ''
  if (cap <= 0) return ''
  if (input.length <= cap) return input

  // Find best cut boundary within [0, cap].
  const window = input.slice(0, cap)

  // 1. Last paragraph break.
  const lastParaBreak = window.lastIndexOf('\n\n')
  if (lastParaBreak > 0) {
    const body = input.slice(0, lastParaBreak)
    return body + suffix
  }

  // 2. Last sentence boundary (". "). We search for ". " and keep the period.
  const lastSentenceBoundary = window.lastIndexOf('. ')
  if (lastSentenceBoundary > 0) {
    // Include the period itself in the body.
    const body = input.slice(0, lastSentenceBoundary + 1)
    return body + suffix
  }

  // 3. Last whitespace — keeps us from cutting mid-word.
  const lastWhitespaceMatch = window.match(/\s(?=\S*$)/)
  // Find the last whitespace index by walking backwards.
  let lastWhitespace = -1
  for (let i = window.length - 1; i >= 0; i--) {
    if (/\s/.test(window[i] ?? '')) {
      lastWhitespace = i
      break
    }
  }
  if (lastWhitespace > 0) {
    const body = input.slice(0, lastWhitespace)
    return body + suffix
  }
  // Silence the unused-var lint on the match path we kept for clarity.
  void lastWhitespaceMatch

  // 4. Hard cut at the cap (no whitespace found — single mega-word).
  return window + suffix
}
