/**
 * T-P2.5 — CONTEXT-001: MOBI pageText extractor.
 *
 * Source: `.parity-v2/SPEC.md` §3.8.
 *
 * Electron authority: `apps/rishi-electron/src/renderer/src/stores/
 * chatStore.ts:71`. Mobile previously sent `"Chapter N"`.
 *
 * The mobile MOBI reader renders the parsed HTML inside a WebView; the
 * WebView can post the rendered `document.body.innerText` back via
 * `postMessage` after each layout. This helper picks the captured value
 * and caps it.
 *
 * Contract (see __tests__/voice-chat/activation-context-pagetext.test.ts):
 *   - return rendered prose when `latestInnerText` is non-null
 *   - return '' when not yet captured — NEVER fall back to "Chapter N"
 *   - apply `softCapPageText` so long chapters don't blow up the prompt
 */
import { softCapPageText } from '@rishi/shared/voice-chat/pageTextCap'

const PAGE_TEXT_CAP = 8000

export interface GetMobiPageTextInput {
  /**
   * Latest `document.body.innerText` posted back from the MOBI WebView.
   * Null when the WebView has not yet posted a value or the bridge
   * failed.
   */
  latestInnerText: string | null
  /**
   * Current chapter index — kept for symmetry with the call site, NOT
   * used as a fallback.
   */
  currentChapter: number
}

export function getMobiPageText(input: GetMobiPageTextInput): string {
  try {
    const { latestInnerText } = input
    if (!latestInnerText) return ''
    const normalised = latestInnerText.trim()
    if (normalised.length === 0) return ''
    return softCapPageText(normalised, PAGE_TEXT_CAP)
  } catch {
    return ''
  }
}
