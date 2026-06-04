/**
 * T-P2.5 — CONTEXT-001: EPUB pageText extractor.
 *
 * Source: `.parity-v2/SPEC.md` §3.8.
 *
 * Electron authority: `apps/rishi-electron/src/renderer/src/stores/
 * chatStore.ts:71` joins `playerState.currentParagraphs.map(p => p.text)` —
 * i.e. real rendered prose. Mobile must do the same; today it ships the
 * chapter label, which defeats the agent.
 *
 * On mobile the EPUB renders inside `@epubjs-react-native/core`'s
 * WebView. The renderer screen captures `contents.document.body.innerText`
 * from the EPUB iframe on each location change and stashes it as
 * `latestInnerText`. This helper just picks the right value with a
 * soft cap; the WebView wiring is the reader's problem.
 *
 * Contract (see __tests__/voice-chat/activation-context-pagetext.test.ts):
 *   - returns rendered prose when `latestInnerText` is non-null
 *   - returns '' (empty string) when `latestInnerText` is null — NEVER
 *     falls back to the chapter label (that was the bug we're fixing)
 *   - applies `softCapPageText` so a giant chapter doesn't blow up the
 *     realtime prompt
 */
import { softCapPageText } from '@rishi/shared/voice-chat/pageTextCap'

const PAGE_TEXT_CAP = 8000

export interface GetEpubPageTextInput {
  /**
   * Latest `document.body.innerText` captured from the EPUB WebView via
   * the rendition's `contents` event. May be null if the WebView has not
   * yet posted a value (early in the render lifecycle).
   */
  latestInnerText: string | null
  /**
   * Current chapter label — passed for symmetry with the call sites but
   * intentionally NOT used as a fallback. Mobile previously returned this
   * as `pageText`, which is the bug T-P2.5 fixes (see SPEC §3.8).
   */
  chapterLabel: string | null
}

export function getEpubPageText(input: GetEpubPageTextInput): string {
  try {
    const { latestInnerText } = input
    if (!latestInnerText) return ''
    const normalised = latestInnerText.trim()
    if (normalised.length === 0) return ''
    return softCapPageText(normalised, PAGE_TEXT_CAP)
  } catch {
    // Graceful degradation: a single extraction failure shouldn't
    // disable voice-chat — outline + activeParagraphText still carry
    // useful context.
    return ''
  }
}
