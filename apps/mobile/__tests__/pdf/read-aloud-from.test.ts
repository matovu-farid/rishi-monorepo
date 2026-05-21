/**
 * Verifies the selection → PLAY_FROM transformation that the PDF
 * reader will dispatch into the shared playerMachine. Same semantics
 * as electron's usePdfReadAloudFromSelection but pure.
 */

import { resolvePlayFromSelection } from '@/lib/pdf/read-aloud-from-selection'

const PARAS = [
  {
    index: '50001',
    text:
      'First paragraph text contains many words and sentences in order to exercise the long-selection probe path. It contains two sentences.',
  },
  { index: '50002', text: 'Second paragraph here. With more sentences. And a third.' },
  { index: '50003', text: 'Third and final paragraph for the page.' },
]

describe('resolvePlayFromSelection', () => {
  it('returns null for empty selection', () => {
    expect(resolvePlayFromSelection('', PARAS)).toBeNull()
    expect(resolvePlayFromSelection('   ', PARAS)).toBeNull()
  })

  it('returns null when no paragraphs are available', () => {
    expect(resolvePlayFromSelection('First paragraph', [])).toBeNull()
  })

  it('returns null when the selection text is not found', () => {
    expect(resolvePlayFromSelection('nonexistent text', PARAS)).toBeNull()
  })

  it('matches the first paragraph and starts playback from its sentence start (char 0)', () => {
    const result = resolvePlayFromSelection('First paragraph', PARAS)
    expect(result).not.toBeNull()
    if (!result) return
    expect(result.paragraphIndex).toBe(0)
    // Selection starts at char 0 → sentence start is 0 → bare cache key
    // for hit on a previously-cached full-paragraph audio.
    expect(result.partialFirstKey).toBe('50001')
    expect(result.partialFirstText).toBe(PARAS[0].text)
  })

  it('matches mid-paragraph selection, sentence-aligned partial', () => {
    const result = resolvePlayFromSelection('It contains', PARAS)
    expect(result).not.toBeNull()
    if (!result) return
    expect(result.paragraphIndex).toBe(0)
    // "It contains two sentences." is the second sentence; partial-first
    // begins there with a suffixed cache key.
    expect(result.partialFirstText).toBe('It contains two sentences.')
    expect(result.partialFirstKey).toMatch(/^50001#s=\d+$/)
  })

  it('matches a paragraph in the middle of the page', () => {
    const result = resolvePlayFromSelection('With more sentences', PARAS)
    expect(result).not.toBeNull()
    if (!result) return
    expect(result.paragraphIndex).toBe(1)
    expect(result.partialFirstText).toBe('With more sentences. And a third.')
  })

  it('uses a 50-char probe for long selections', () => {
    // The probe is `text.slice(0, 50)` — selections longer than 50 chars
    // search via their first 50 chars, which lets minor trailing text
    // mismatches (extra whitespace at the end, ligature differences) still
    // resolve to the right paragraph. The probe itself must still be a
    // substring of the paragraph.
    const longSelection = `${PARAS[0].text} and more text that does not exist`
    const result = resolvePlayFromSelection(longSelection, PARAS)
    expect(result).not.toBeNull()
    if (!result) return
    expect(result.paragraphIndex).toBe(0)
  })
})
