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
})
