/**
 * T-P2.5 — CONTEXT-001: page text in activation context (4 readers).
 *
 * Source: `.parity-v2/SPEC.md` §3.8 (CONTEXT-001).
 *
 * Each of the 4 mobile readers must populate `pageText` in
 * `getActivationContext()` with the actual rendered prose of the current view,
 * matching electron's contract (chatStore.ts:71):
 *
 *     const pageText = playerState.currentParagraphs.map(p => p.text).join('\n')
 *
 * Today the readers populate this field with a chapter label or "Page N of M"
 * placeholder, which defeats the voice-chat agent (it asks "what's on this
 * page?" and gets back "Page 4 of 100"). See SPEC §3.8 "Mobile bug sites".
 *
 * The implementer will lift the per-reader text-extraction logic into small
 * pure helper modules so they can be unit-tested without rendering the full
 * Expo reader screens. The helpers expected by this suite:
 *
 *   - apps/mobile/lib/voice-chat/pagetext/epub.ts
 *       export getEpubPageText(input: { latestInnerText: string | null,
 *                                       chapterLabel: string | null }): string
 *
 *   - apps/mobile/lib/voice-chat/pagetext/pdf.ts
 *       export getPdfPageText(input: { extractedPageText: string | null,
 *                                      indexerChunkTexts: string[],
 *                                      pageNumber: number, pageCount: number }): string
 *
 *   - apps/mobile/lib/voice-chat/pagetext/mobi.ts
 *       export getMobiPageText(input: { latestInnerText: string | null,
 *                                       currentChapter: number }): string
 *
 *   - apps/mobile/lib/voice-chat/pagetext/djvu.ts
 *       export getDjvuPageText(input: { indexerChunkTexts: string[],
 *                                       pageNumber: number, pageCount: number }): string
 *
 * Each helper MUST:
 *   1. Return the real prose when the extraction port provides it.
 *   2. Apply `softCapPageText` (8000 char cap) so untrusted long pages don't
 *      blow up the realtime prompt.
 *   3. Return '' (empty string) when nothing is available — never throw.
 *   4. NEVER fall back to a "Page N of M" / chapter-label string when real
 *      text is available — that defeats the parity goal.
 *
 * Until the helpers exist, this file fails at import time (RED). Once the
 * helpers ship, the assertions exercise the contract.
 */
import { getEpubPageText } from '@/lib/voice-chat/pagetext/epub'
import { getPdfPageText } from '@/lib/voice-chat/pagetext/pdf'
import { getMobiPageText } from '@/lib/voice-chat/pagetext/mobi'
import { getDjvuPageText } from '@/lib/voice-chat/pagetext/djvu'

const FAKE_PARAGRAPH =
  'The rain in Spain falls mainly on the plain. The plain in Spain is the home of the rain. The rain that falls on the plain in Spain is mainly the same rain.'

describe('CONTEXT-001 — getActivationContext().pageText per reader', () => {
  describe('EPUB', () => {
    it('returns the WebView-extracted prose when present', () => {
      const out = getEpubPageText({
        latestInnerText: FAKE_PARAGRAPH,
        chapterLabel: 'Chapter 3',
      })
      expect(out).toContain('rain in Spain')
      expect(out.length).toBeGreaterThan(50)
      // Critically: the chapter label is NOT what we return when real text
      // is available — that is the current bug per SPEC §3.8.
      expect(out).not.toBe('Chapter 3')
    })

    it('returns empty string when WebView text is not yet captured', () => {
      const out = getEpubPageText({
        latestInnerText: null,
        chapterLabel: 'Chapter 3',
      })
      expect(out).toBe('')
    })

    it('applies the soft cap to long pages (≤ 8000 + suffix)', () => {
      const huge = 'word '.repeat(3000)
      const out = getEpubPageText({
        latestInnerText: huge,
        chapterLabel: 'Chapter 3',
      })
      expect(out.length).toBeLessThanOrEqual(8000 + '\n[text truncated]'.length)
      expect(out.endsWith('[text truncated]')).toBe(true)
    })
  })

  describe('PDF', () => {
    it('returns the pdf.getPageText() result when present', () => {
      const out = getPdfPageText({
        extractedPageText: FAKE_PARAGRAPH,
        indexerChunkTexts: [],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out).toContain('rain in Spain')
      expect(out).not.toBe('Page 4 of 100')
    })

    it('falls back to indexer chunk text when pdf.getPageText() is unavailable', () => {
      const out = getPdfPageText({
        extractedPageText: null,
        indexerChunkTexts: ['Chunk one prose.', 'Chunk two prose.'],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out).toContain('Chunk one prose.')
      expect(out).toContain('Chunk two prose.')
      expect(out).not.toBe('Page 4 of 100')
    })

    it('returns empty string when neither extraction nor indexer text is available', () => {
      const out = getPdfPageText({
        extractedPageText: null,
        indexerChunkTexts: [],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out).toBe('')
    })

    it('applies the soft cap to long pages', () => {
      const huge = 'word '.repeat(3000)
      const out = getPdfPageText({
        extractedPageText: huge,
        indexerChunkTexts: [],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out.length).toBeLessThanOrEqual(8000 + '\n[text truncated]'.length)
      expect(out.endsWith('[text truncated]')).toBe(true)
    })
  })

  describe('MOBI', () => {
    it('returns the WebView onMessage-delivered prose when present', () => {
      const out = getMobiPageText({
        latestInnerText: FAKE_PARAGRAPH,
        currentChapter: 2,
      })
      expect(out).toContain('rain in Spain')
      expect(out).not.toBe('Chapter 3')
    })

    it('returns empty string when WebView text is not yet captured', () => {
      const out = getMobiPageText({ latestInnerText: null, currentChapter: 2 })
      expect(out).toBe('')
    })

    it('applies the soft cap to long pages', () => {
      const huge = 'word '.repeat(3000)
      const out = getMobiPageText({ latestInnerText: huge, currentChapter: 2 })
      expect(out.length).toBeLessThanOrEqual(8000 + '\n[text truncated]'.length)
      expect(out.endsWith('[text truncated]')).toBe(true)
    })
  })

  describe('DJVU', () => {
    it('returns the indexer chunk text for the current page', () => {
      const out = getDjvuPageText({
        indexerChunkTexts: [FAKE_PARAGRAPH],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out).toContain('rain in Spain')
      expect(out).not.toBe('Page 4 of 100')
    })

    it('returns empty string when indexer has nothing for the page', () => {
      const out = getDjvuPageText({
        indexerChunkTexts: [],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out).toBe('')
    })

    it('applies the soft cap to long pages', () => {
      const huge = 'word '.repeat(3000)
      const out = getDjvuPageText({
        indexerChunkTexts: [huge],
        pageNumber: 4,
        pageCount: 100,
      })
      expect(out.length).toBeLessThanOrEqual(8000 + '\n[text truncated]'.length)
      expect(out.endsWith('[text truncated]')).toBe(true)
    })
  })
})
