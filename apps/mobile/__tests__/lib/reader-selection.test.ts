/**
 * P1-K — Shared "read from selection" resolver for plain-text reader
 * formats (MOBI / AZW3 / DJVU).
 *
 * Symmetric with `resolveEpubReadFromSelection` and the PDF resolver,
 * but without the CFI fallback — these formats don't expose CFI. The
 * helper takes the WebView's reported selection text plus the
 * already-seeded paragraph list and returns the PLAY_FROM payload
 * (paragraphIndex + sentence-aligned partialFirstText/Key) the shared
 * playerMachine consumes.
 */

import { resolvePlainTextReadFromSelection } from '@/lib/reader-selection'

describe('resolvePlainTextReadFromSelection', () => {
  const paragraphs = [
    { index: 'm-0', text: 'The cat sat on the mat. It was big.' },
    { index: 'm-1', text: 'Eventually, the dog ran past.' },
  ]

  it('returns null when paragraphs list is empty', () => {
    expect(resolvePlainTextReadFromSelection('any', [])).toBeNull()
  })

  it('returns null when the selection text is whitespace', () => {
    expect(resolvePlainTextReadFromSelection('   ', paragraphs)).toBeNull()
  })

  it('matches a selection inside paragraph 0', () => {
    const result = resolvePlainTextReadFromSelection('cat sat', paragraphs)
    expect(result?.paragraphIndex).toBe(0)
    expect(result?.partialFirstText).toBe(paragraphs[0].text)
    expect(result?.partialFirstKey).toBe(paragraphs[0].index)
  })

  it('matches a selection inside paragraph 1', () => {
    const result = resolvePlainTextReadFromSelection('dog ran past', paragraphs)
    expect(result?.paragraphIndex).toBe(1)
    expect(result?.partialFirstKey).toBe(paragraphs[1].index)
  })

  it('returns null when the selection text is not found in any paragraph', () => {
    expect(
      resolvePlainTextReadFromSelection('never appears anywhere', paragraphs),
    ).toBeNull()
  })

  it('emits a #s= suffix when the selection lands mid-paragraph (sentence boundary)', () => {
    // "It was big" begins after the first sentence boundary in paragraph 0.
    const result = resolvePlainTextReadFromSelection('It was big', paragraphs)
    expect(result).not.toBeNull()
    expect(result!.paragraphIndex).toBe(0)
    expect(result!.partialFirstText).toBe('It was big.')
    expect(result!.partialFirstKey).toMatch(/#s=\d+$/)
  })
})
