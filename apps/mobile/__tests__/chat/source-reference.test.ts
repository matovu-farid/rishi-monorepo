/**
 * SourceReference label / hint formatting tests (G23 polish).
 *
 * Verifies the pure label + accessibility-hint formulas mirror
 * electron's `SourceChip` (apps/rishi-electron/.../components/chat/
 * SourceChip.tsx).
 */
import {
  formatSourceLabel,
  formatSourceHint,
} from '@/lib/chat/source-label'

describe('formatSourceLabel', () => {
  it('returns `Source` placeholder when chapter is null', () => {
    expect(formatSourceLabel({ chapter: null })).toBe('Source')
  })

  it('returns `Source` when chapter is empty string', () => {
    expect(formatSourceLabel({ chapter: '' })).toBe('Source')
  })

  it('returns `Source` when chapter is only whitespace', () => {
    expect(formatSourceLabel({ chapter: '   ' })).toBe('Source')
  })

  it('returns `Ch. {full chapter}` when chapter is short (<=17 chars)', () => {
    expect(formatSourceLabel({ chapter: 'Intro' })).toBe('Ch. Intro')
    // 17-char chapter — no ellipsis
    expect(formatSourceLabel({ chapter: 'A'.repeat(17) })).toBe(
      `Ch. ${'A'.repeat(17)}`,
    )
  })

  it('truncates to 17 chars and adds ellipsis when chapter is longer', () => {
    const chapter = 'A very long chapter title that does not fit'
    expect(formatSourceLabel({ chapter })).toBe('Ch. A very long chapt...')
  })

  it('renders PDF/DJVU "Page N" chapters as `p. N`', () => {
    expect(formatSourceLabel({ chapter: 'Page 12' })).toBe('p. 12')
    expect(formatSourceLabel({ chapter: 'Page 1' })).toBe('p. 1')
    expect(formatSourceLabel({ chapter: 'page 99' })).toBe('p. 99')
  })

  it('only treats "Page N" exactly (no false positives)', () => {
    // "Page Two" doesn't match — falls through to chapter rendering.
    expect(formatSourceLabel({ chapter: 'Page Two' })).toBe('Ch. Page Two')
    // Chapter starting with "Pages" doesn't match either.
    expect(formatSourceLabel({ chapter: 'Pages of glory' })).toBe('Ch. Pages of glory')
  })
})

describe('formatSourceHint', () => {
  it('includes chapter line when chapter is present', () => {
    const hint = formatSourceHint({ chapter: 'Intro', text: 'Hello world.' })
    expect(hint).toContain('Chapter: Intro')
    expect(hint).toContain('Hello world.')
  })

  it('omits chapter line when chapter is null', () => {
    const hint = formatSourceHint({ chapter: null, text: 'Hi.' })
    expect(hint).toBe('Hi.')
  })

  it('truncates snippet to 100 chars + ellipsis', () => {
    const longText = 'a'.repeat(200)
    const hint = formatSourceHint({ chapter: null, text: longText })
    expect(hint.endsWith('...')).toBe(true)
    // 100 a's + `...` = 103
    expect(hint.length).toBe(103)
  })

  it('returns empty string when both chapter and text are absent', () => {
    expect(formatSourceHint({ chapter: null, text: '' })).toBe('')
  })

  it('joins chapter and snippet on newline', () => {
    const hint = formatSourceHint({ chapter: 'Ch 1', text: 'hi' })
    expect(hint).toBe('Chapter: Ch 1\nhi')
  })
})
