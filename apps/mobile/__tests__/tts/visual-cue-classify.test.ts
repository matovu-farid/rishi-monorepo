/**
 * visual-cue-classify tests. The classifier is a text-based heuristic
 * the reader screens use to drive setVisualCue from the active
 * paragraph (G15).
 */
import { classifyParagraphForVisualCue } from '@/lib/tts/visual-cue-classify'

describe('classifyParagraphForVisualCue', () => {
  it('returns null for empty text', () => {
    expect(classifyParagraphForVisualCue('')).toBeNull()
  })

  it('returns null for ordinary prose', () => {
    expect(
      classifyParagraphForVisualCue('The cat sat on the mat. It was a good cat.'),
    ).toBeNull()
  })

  it('detects $$ ... $$ block math as equation', () => {
    const result = classifyParagraphForVisualCue('We have $$x^2 + y^2 = z^2$$ as the identity.')
    expect(result?.kind).toBe('equation')
    expect(result?.label).toBe('Equation on page')
  })

  it('detects inline $...$ math as equation', () => {
    const result = classifyParagraphForVisualCue('Let $f(x) = 2x + 1$ be a function.')
    expect(result?.kind).toBe('equation')
  })

  it('detects \\( ... \\) inline math as equation', () => {
    const result = classifyParagraphForVisualCue('We define \\(a = b + c\\) here.')
    expect(result?.kind).toBe('equation')
  })

  it('detects LaTeX command tokens (\\frac) without delimiters', () => {
    const result = classifyParagraphForVisualCue('We use \\frac{1}{2} as a coefficient.')
    expect(result?.kind).toBe('equation')
  })

  it('detects "Equation 1.2" label references as equation', () => {
    const result = classifyParagraphForVisualCue('See Equation 1.2 above.')
    expect(result?.kind).toBe('equation')
  })

  it('detects "Figure 3" mentions as figure', () => {
    const result = classifyParagraphForVisualCue('As shown in Figure 3, the trend continues.')
    expect(result?.kind).toBe('figure')
    expect(result?.label).toBe('Figure on page')
  })

  it('detects "Table 4.1" mentions as figure', () => {
    const result = classifyParagraphForVisualCue('Table 4.1 lists the values.')
    expect(result?.kind).toBe('figure')
  })

  it('does not classify a paragraph that just mentions the word "figure"', () => {
    expect(
      classifyParagraphForVisualCue('A circular figure was lying on the ground.'),
    ).toBeNull()
  })

  // ── CG36 — inline LaTeX surrounded by prose ─────────────────────────────────
  //
  // Per audit CG36 (Phase A quick-win): a paragraph whose math is a
  // single `$x$` inline token in the middle of a longer sentence MUST
  // still classify as equation. The regex must not require the math
  // expression to anchor at start/end of paragraph.
  it('classifies inline LaTeX `$x$` surrounded by prose as equation', () => {
    // Prose before, math token in the middle, prose after.
    const result = classifyParagraphForVisualCue(
      'We consider the case where $x$ continued to grow without bound.',
    )
    expect(result?.kind).toBe('equation')
    expect(result?.label).toBe('Equation on page')
  })

  it('classifies $...$ math even when it appears at the very end of the paragraph', () => {
    const result = classifyParagraphForVisualCue(
      'The integral evaluates to $\\pi/2$',
    )
    expect(result?.kind).toBe('equation')
  })

  it('classifies multiple inline math tokens in one paragraph', () => {
    const result = classifyParagraphForVisualCue(
      'For $x>0$ and $y<1$ we have a contradiction in the bound.',
    )
    expect(result?.kind).toBe('equation')
  })

  it('does NOT classify a single bare `$` (price-like) as math', () => {
    // `$5` is currency, not LaTeX — the inline regex requires a closing
    // `$` on the same line. This pins the contract so a future
    // greedier regex doesn't silently flag prose with currency.
    expect(classifyParagraphForVisualCue('It cost $5 to enter the park.')).toBeNull()
  })
})
