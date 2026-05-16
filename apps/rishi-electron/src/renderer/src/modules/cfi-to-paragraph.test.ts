import { describe, it, expect } from 'vitest'
import { findParagraphForCfi } from './cfi-to-paragraph'

// CFI anatomy (epub.js):
//   epubcfi( BASE ! PATH , START , END )
// where BASE = /6/N  (spine), PATH = /4/N  (element steps before the range),
// START/END are the range offsets relative to PATH.
//
// Real paragraph CFIs from epubwrapper look like:
//   epubcfi(/6/4!/4/2,/1:0,/1:16)   ← range spanning text "First paragraph."
//
// For the containment check the implementation collapses each paragraph's
// range to a start/end point and uses EpubCFI.compare() to bracket the
// selection's start position.

describe('findParagraphForCfi', () => {
  // Three adjacent paragraphs in spine item /6/4 (spinePos index 2 → step 4)
  const paragraphs = [
    { index: 'epubcfi(/6/4!/4/2,/1:0,/1:16)', text: 'First paragraph.' },
    { index: 'epubcfi(/6/4!/4/4,/1:0,/1:17)', text: 'Second paragraph.' },
    { index: 'epubcfi(/6/4!/4/6,/1:0,/1:15)', text: 'Third paragraph.' }
  ]

  it('returns null when no paragraph contains the selection (different spine item)', () => {
    // Spine item /6/8 — no paragraph matches /6/4
    const result = findParagraphForCfi(paragraphs, 'epubcfi(/6/8!/4/2,/1:0,/1:5)')
    expect(result).toBeNull()
  })

  it('returns the matching paragraph index when the selection start is inside it', () => {
    // Selection inside second paragraph (/4/4), chars 3-10
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/4,/1:3,/1:10)'
    )
    expect(result).not.toBeNull()
    expect(result!.paragraphIndex).toBe(1)
  })

  it('uses the first paragraph when selection is in it', () => {
    // Selection inside first paragraph (/4/2), chars 0-5
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/2,/1:0,/1:5)'
    )
    expect(result).not.toBeNull()
    expect(result!.paragraphIndex).toBe(0)
  })

  it('returns the char offset of the selection start within the paragraph text', () => {
    // Selection inside second paragraph starting at char 7
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/4,/1:7,/1:12)'
    )
    expect(result).not.toBeNull()
    expect(result!.charOffsetInParagraph).toBe(7)
  })

  it('returns the third paragraph when selection is in it', () => {
    const result = findParagraphForCfi(
      paragraphs,
      'epubcfi(/6/4!/4/6,/1:2,/1:8)'
    )
    expect(result).not.toBeNull()
    expect(result!.paragraphIndex).toBe(2)
    expect(result!.charOffsetInParagraph).toBe(2)
  })

  it('returns null for an invalid CFI string', () => {
    const result = findParagraphForCfi(paragraphs, 'not-a-cfi')
    expect(result).toBeNull()
  })
})
