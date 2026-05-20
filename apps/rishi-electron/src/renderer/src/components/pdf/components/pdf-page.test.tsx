import { describe, it, expect, beforeEach } from 'vitest'

import { makeCustomTextRenderer } from './pdf-page'
import { usePdfStore } from '@/stores/pdfStore'

// Regression: the PDF reader was migrated to a declarative TTS-highlight
// implementation in which the text-layer renderer wraps matched text in
// <mark> based purely on pdfStore state. This test pins that property so a
// future refactor cannot accidentally restore imperative DOM-walking
// highlight code without the suite failing.
//
// The renderer is a pure function of the *resolved* `highlightedParagraph`,
// so we exercise it directly. We also include one end-to-end-ish case that
// reads from `usePdfStore` to verify the integration: when the store is in
// the "highlight active for this paragraph" state, the resolved paragraph
// passed to the factory produces `<mark>`-wrapped output; when the store is
// idle (or has no resolved paragraph), output is plain text.

const PARAGRAPH = {
  dimensions: { top: 200, bottom: 100 }
}

function snapshotStore() {
  return usePdfStore.getState()
}

describe('PDF declarative TTS highlight (regression)', () => {
  const initial = snapshotStore()

  beforeEach(() => {
    // Reset only the fields this test touches so we don't clobber unrelated
    // store setup. The pdfStore is a singleton across the test process.
    usePdfStore.setState({
      isHighlighting: initial.isHighlighting,
      highlightedParagraphIndex: initial.highlightedParagraphIndex,
      currentViewParagraphs: initial.currentViewParagraphs
    })
  })

  describe('makeCustomTextRenderer', () => {
    it('renders <mark>-wrapped output when a paragraph is highlighted and the text falls within its dimensions', () => {
      const renderer = makeCustomTextRenderer(PARAGRAPH)

      // y = 150 sits between bottom=100 and top=200 → inside the paragraph
      const transform = [1, 0, 0, 1, 0, 150]
      const out = renderer({ str: 'hello', transform })

      expect(out).toBe('<mark style="background-color: rgb(255,255,204);">hello</mark>')
    })

    it('renders plain text when no paragraph is highlighted (null)', () => {
      const renderer = makeCustomTextRenderer(null)

      const transform = [1, 0, 0, 1, 0, 150]
      const out = renderer({ str: 'hello', transform })

      expect(out).toBe('hello')
    })

    it('renders plain text when the item is outside the paragraph dimensions', () => {
      const renderer = makeCustomTextRenderer(PARAGRAPH)

      // y = 50 is below bottom=100 → outside the paragraph
      expect(renderer({ str: 'below', transform: [1, 0, 0, 1, 0, 50] })).toBe('below')
      // y = 300 is above top=200 → outside the paragraph
      expect(renderer({ str: 'above', transform: [1, 0, 0, 1, 0, 300] })).toBe('above')
    })

    it('renders plain text when transform is undefined regardless of highlight state', () => {
      const renderer = makeCustomTextRenderer(PARAGRAPH)
      expect(renderer({ str: 'no-transform', transform: undefined })).toBe('no-transform')
    })
  })

  describe('integration with pdfStore', () => {
    // Mirrors the selector inside pdf-page.tsx so we verify the *store →
    // resolved paragraph → renderer output* chain that drives the
    // declarative highlight contract.
    function resolveHighlightedParagraph(pageNumber: number) {
      const PARAGRAPH_INDEX_PER_PAGE = 10000
      const s = usePdfStore.getState()
      const isMyHighlightedPage =
        s.isHighlighting &&
        Math.floor(Number(s.highlightedParagraphIndex) / PARAGRAPH_INDEX_PER_PAGE) === pageNumber
      return isMyHighlightedPage
        ? (s.currentViewParagraphs.find((p) => p.index === s.highlightedParagraphIndex) ?? null)
        : null
    }

    it('produces <mark> output when the store has an active highlight for the page', () => {
      // Place a paragraph on page 1 (index 10000..19999 by the
      // PARAGRAPH_INDEX_PER_PAGE = 10000 convention).
      usePdfStore.setState({
        isHighlighting: true,
        highlightedParagraphIndex: '10005',
        currentViewParagraphs: [
          {
            index: '10005',
            text: 'hi',
            dimensions: { top: 200, bottom: 100 }
          }
        ]
      })

      const paragraph = resolveHighlightedParagraph(1)
      expect(paragraph).not.toBeNull()

      const renderer = makeCustomTextRenderer(paragraph)
      const out = renderer({ str: 'hi', transform: [1, 0, 0, 1, 0, 150] })

      expect(out).toContain('<mark')
      expect(out).toContain('hi')
    })

    it('produces plain text when isHighlighting is false', () => {
      usePdfStore.setState({
        isHighlighting: false,
        highlightedParagraphIndex: '10005',
        currentViewParagraphs: [
          {
            index: '10005',
            text: 'hi',
            dimensions: { top: 200, bottom: 100 }
          }
        ]
      })

      const paragraph = resolveHighlightedParagraph(1)
      expect(paragraph).toBeNull()

      const renderer = makeCustomTextRenderer(paragraph)
      expect(renderer({ str: 'hi', transform: [1, 0, 0, 1, 0, 150] })).toBe('hi')
    })

    it('produces plain text when highlightedParagraphIndex is empty', () => {
      usePdfStore.setState({
        isHighlighting: true,
        highlightedParagraphIndex: '',
        currentViewParagraphs: []
      })

      const paragraph = resolveHighlightedParagraph(1)
      expect(paragraph).toBeNull()

      const renderer = makeCustomTextRenderer(paragraph)
      expect(renderer({ str: 'hi', transform: [1, 0, 0, 1, 0, 150] })).toBe('hi')
    })

    it('returns null for pages that are not the highlighted page', () => {
      // Highlight is on page 1 (index 10005). Page 2 should be inert.
      usePdfStore.setState({
        isHighlighting: true,
        highlightedParagraphIndex: '10005',
        currentViewParagraphs: [
          {
            index: '10005',
            text: 'hi',
            dimensions: { top: 200, bottom: 100 }
          }
        ]
      })

      const paragraph = resolveHighlightedParagraph(2)
      expect(paragraph).toBeNull()

      const renderer = makeCustomTextRenderer(paragraph)
      expect(renderer({ str: 'hi', transform: [1, 0, 0, 1, 0, 150] })).toBe('hi')
    })
  })
})
