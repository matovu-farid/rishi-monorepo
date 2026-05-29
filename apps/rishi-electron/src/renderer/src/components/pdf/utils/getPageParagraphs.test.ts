import { describe, it, expect } from 'vitest'
import { pageDataToParagraphs } from './getPageParagraphs'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const longText = (n: number, label: string): string => {
  // Build a paragraph whose trimmed length passes MIN_PARAGRAPH_LENGTH (50).
  // The merge logic in pageDataToParagraphs absorbs short paragraphs into the
  // previous one, so when we want N visible paragraphs we make each long.
  return (label + ' ').repeat(Math.ceil(80 / (label.length + 1))).slice(0, 80) + ` (#${n})`
}

const makeItem = (
  str: string,
  y: number,
  opts: { hasEOL?: boolean; height?: number } = {}
): any => ({
  str,
  dir: 'ltr',
  width: Math.max(10, str.length * 5),
  height: opts.height ?? 12,
  transform: [12, 0, 0, 12, 0, y],
  fontName: 'g_d0_f1',
  hasEOL: opts.hasEOL ?? true
})

/**
 * Build a TextContent-shaped fixture with N "fat" paragraphs each consisting
 * of a single EOL-terminated item, vertically separated by enough to trip
 * isVerticallySpaced. Item index i in the resulting items[] corresponds to
 * paragraph index i (0-based).
 */
const makeFiveParagraphPage = (): any => {
  const items: any[] = []
  // Each item is its own paragraph because the y-delta between consecutive
  // items is far larger than 1.5 * height (= 18).
  const ys = [560, 460, 360, 260, 160]
  for (let i = 0; i < 5; i++) {
    items.push(makeItem(longText(i, `Paragraph_${i}`), ys[i]))
  }
  return { items, styles: {} }
}

describe('pageDataToParagraphs (mask-aware)', () => {
  it('is byte-for-byte identical to today when no mask is provided', () => {
    const page = makeFiveParagraphPage()
    const withoutArg = pageDataToParagraphs(3, page)
    const withUndefined = (pageDataToParagraphs as any)(3, page, undefined)
    expect(withUndefined).toEqual(withoutArg)
    // Sanity: we actually produced multiple paragraphs.
    expect(withoutArg.length).toBeGreaterThanOrEqual(2)
  })

  it('drops paragraphs whose items are all masked', () => {
    const page = makeFiveParagraphPage()
    const baseline = pageDataToParagraphs(3, page)
    expect(baseline.length).toBeGreaterThanOrEqual(3)

    // Mask the items that compose the third paragraph in our fixture.
    // Our fixture is 1 item per paragraph, so masking item index 2 drops
    // paragraph index 2.
    const mask = new Set<number>([2])
    const masked = (pageDataToParagraphs as any)(3, page, mask)

    expect(masked.length).toBe(baseline.length - 1)
    // The dropped paragraph's text MUST be gone from the output.
    expect(masked.find((p: any) => p.text.includes('Paragraph_2'))).toBeUndefined()
  })

  it('reserves the slot for masked paragraphs (surviving indices keep gaps)', () => {
    // CRITICAL: resume bookmarks depend on stable indices. Page 3 paragraph 2
    // must keep its slot (30002) even after item index 2 is masked, so the
    // remaining paragraphs have indices 30000, 30001, 30003, 30004.
    const page = makeFiveParagraphPage()
    const mask = new Set<number>([2])
    const masked = (pageDataToParagraphs as any)(3, page, mask)

    const indices = masked.map((p: any) => p.index).sort()
    expect(indices).toContain('30000')
    expect(indices).toContain('30001')
    expect(indices).not.toContain('30002') // dropped
    expect(indices).toContain('30003')
    expect(indices).toContain('30004')

    // And critically NOT contiguous-renumbered:
    expect(indices).not.toEqual(['30000', '30001', '30002', '30003'])
  })

  it('mask referring to items beyond items.length is a no-op', () => {
    const page = makeFiveParagraphPage()
    const baseline = pageDataToParagraphs(3, page)
    const masked = (pageDataToParagraphs as any)(3, page, new Set<number>([99, 100]))
    expect(masked).toEqual(baseline)
  })

  it('emits body paragraphs before a footnote that pdf.js streamed first', () => {
    // Real-world layout: pdf.js returns the footnote block (low y) BEFORE the
    // body (high y) in items[]. The assembled paragraphs must still read the
    // body first, then the footnote.
    const items = [
      makeItem(longText(0, 'Footnote_Brendan_Burns_et_al'), 75),
      makeItem(longText(1, 'Body_Kubernetes_open_source_orchestrator'), 560),
      makeItem(longText(2, 'Body_Since_its_introduction_in_2014'), 360)
    ]
    const out = pageDataToParagraphs(3, { items, styles: {} } as any)
    const bodyIdx = out.findIndex((p: any) => p.text.includes('Body_Kubernetes'))
    const footIdx = out.findIndex((p: any) => p.text.includes('Footnote_Brendan'))
    expect(bodyIdx).toBeGreaterThanOrEqual(0)
    expect(footIdx).toBeGreaterThanOrEqual(0)
    expect(bodyIdx).toBeLessThan(footIdx)
  })

  it('excludes a smaller-font footnote at the page bottom from the paragraphs', () => {
    const items = [
      // footnote streamed FIRST (low y, smaller font)
      makeItem('1 Brendan Burns et al., footnote that is long enough to survive merges.', 80, {
        height: 8
      }),
      makeItem(longText(1, 'Body_Kubernetes_open_source_orchestrator'), 560),
      makeItem(longText(2, 'Body_Since_its_introduction_in_2014'), 360)
    ]
    const out = pageDataToParagraphs(3, { items, styles: {} } as any)
    expect(out.some((p: any) => p.text.includes('Body_Kubernetes'))).toBe(true)
    expect(out.some((p: any) => p.text.includes('Body_Since'))).toBe(true)
    expect(out.some((p: any) => p.text.includes('Brendan'))).toBe(false)
  })
})

describe('pageDataToParagraphs — sentence-aware 5-line break', () => {
  // Helper: build a "page" with N successive EOL'd lines at the same y-cluster
  // (no vertical gap, so isVerticallySpaced is false). Lines beyond MIN_PARA_LEN
  // collectively form ONE paragraph today; the 5-line cap is what splits it.
  const makeLongParagraphPage = (lines: string[]): any => {
    const items: any[] = []
    // Start near top, decrement y by exactly the line-height so vertical gap
    // detection does NOT fire (lines are tight, like wrapped body text).
    let y = 560
    const lineHeight = 14 // small enough that y-delta < getParagraphThreshold
    for (const text of lines) {
      items.push(makeItem(text, y, { hasEOL: true, height: 12 }))
      y -= lineHeight
    }
    return { items, styles: {} }
  }

  it('does NOT break a 6-line paragraph mid-sentence', () => {
    // 6 lines, no sentence terminator until the very end. Today this splits at
    // line 6. After the fix, it stays as a single paragraph because lines 1-5
    // do not end a sentence.
    const lines = [
      'Velocity is the key component in nearly all software development',
      'today, and the industry has evolved from shipping boxed CDs',
      'to delivering software via web-based services that update hourly',
      'which means the difference between you and your competitors is',
      'often the speed with which you can develop and deploy new features',
      'or respond to innovations developed by other organizations today.'
    ]
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs).toHaveLength(1)
    // The whole text should be present in the single emitted paragraph.
    expect(paragraphs[0].text).toContain('Velocity is the key component')
    expect(paragraphs[0].text).toContain('developed by other organizations today.')
  })

  it('breaks at sentence end when line-count threshold has been crossed', () => {
    // 7 lines: first 4 are mid-sentence, line 5 ends a sentence, lines 6-7 are
    // a new sentence. Today breaks at line 6 mid-sentence. After fix, breaks
    // after line 5 (the first sentence-ending EOL beyond the 5-line threshold).
    const lines = [
      'This first sentence wraps across several lines without ending',
      'and continues to wrap so that the line count keeps incrementing',
      'until we are quite a few lines deep into the paragraph here',
      'and still the sentence has not yet reached a terminator yet',
      'but it finally ends right here at the close of this fifth line.',
      'Now a second sentence begins. It is short and ends on line seven.',
      'Trailing matter beyond the break does not affect this test outcome.'
    ]
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs.length).toBeGreaterThanOrEqual(2)
    // First paragraph contains the first sentence ending with a period.
    expect(paragraphs[0].text).toMatch(/at the close of this fifth line\.\s*$/)
    // Second paragraph contains the start of the second sentence.
    expect(paragraphs[1].text).toContain('Now a second sentence begins')
  })

  it('forces a break at the safety cap when no sentence terminator appears', () => {
    // 13 lines, none ending a sentence. After the fix, the safety cap (12)
    // forces a break so paragraphs never grow unbounded.
    const lines = Array.from(
      { length: 13 },
      (_, i) => `line ${i} of a paragraph that just keeps going and never ends`
    )
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs.length).toBeGreaterThanOrEqual(2)
  })
})
