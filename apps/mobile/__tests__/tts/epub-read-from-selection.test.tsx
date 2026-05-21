/**
 * G17 — EPUB "Read from selection".
 *
 * The EPUB reader had no parity for the PDF reader's "Read from here"
 * affordance. This test exercises the new resolver
 * (`resolveEpubReadFromSelection`) that translates an EPUB selection
 * (cfiRange + text + paragraph list from the rendition) into a
 * PLAY_FROM payload — the same shape the PDF reader already
 * dispatches.
 */

import { resolveEpubReadFromSelection } from '@/lib/epub/read-aloud-from-selection'

describe('resolveEpubReadFromSelection', () => {
  // Paragraphs as the EPUB reader bridge would emit them: each
  // `index` is a CFI range string; `text` is the rendered text.
  const paragraphs = [
    {
      index: 'epubcfi(/6/4!/4/2,/1:0,/1:34)',
      text: 'The cat sat on the mat. It was big.',
    },
    {
      index: 'epubcfi(/6/4!/4/4,/1:0,/1:30)',
      text: 'Eventually, the dog ran past.',
    },
  ]

  it('returns null when paragraphs list is empty', () => {
    expect(
      resolveEpubReadFromSelection('any', 'epubcfi(/6/4!/4/2,/1:7,/1:12)', []),
    ).toBeNull()
  })

  it('returns null when the selection text is whitespace', () => {
    expect(
      resolveEpubReadFromSelection('   ', 'epubcfi(/6/4!/4/2,/1:7,/1:12)', paragraphs),
    ).toBeNull()
  })

  it('matches a selection inside paragraph 0', () => {
    const result = resolveEpubReadFromSelection(
      'cat sat',
      'epubcfi(/6/4!/4/2,/1:4,/1:11)',
      paragraphs,
    )
    expect(result?.paragraphIndex).toBe(0)
    // partialFirstText starts at the sentence boundary preceding the
    // selection. The selection is in the first sentence, so the partial
    // is the entire first paragraph.
    expect(result?.partialFirstText).toBe(paragraphs[0].text)
    // First-sentence selection → key is the bare paragraph id (no #s=
    // suffix) so prefetched audio is reused.
    expect(result?.partialFirstKey).toBe(paragraphs[0].index)
  })

  it('matches a selection in paragraph 1 even when the cfi is in paragraph 0', () => {
    // The resolver is text-first (electron's behaviour) — if the
    // selection text matches a later paragraph, that wins.
    const result = resolveEpubReadFromSelection(
      'dog ran past',
      'epubcfi(/6/4!/4/4,/1:15,/1:27)',
      paragraphs,
    )
    expect(result?.paragraphIndex).toBe(1)
  })

  it('returns null when neither cfi nor text resolves to a paragraph', () => {
    const result = resolveEpubReadFromSelection(
      'never appears anywhere',
      'epubcfi(/6/999!/4/2,/1:0,/1:1)',
      paragraphs,
    )
    expect(result).toBeNull()
  })
})
