import { describe, it, expect } from 'vitest'
import {
  HIGHLIGHT_COLORS,
  NOTE_COLOR_NONE,
  type HighlightColor,
  getHighlightHex,
  isNoteOnly
} from './highlight'

describe('HighlightColor', () => {
  it("NOTE_COLOR_NONE equals the string literal 'none'", () => {
    // Round-trip from DB persists this exact string, so the constant must
    // match. A typo here would silently break note-only detection.
    expect(NOTE_COLOR_NONE).toBe('none')
  })

  it("'none' is assignable to HighlightColor (type widening)", () => {
    // Type-level check — runtime asserts nothing useful but compilation
    // verifies the union includes the sentinel.
    const c: HighlightColor = NOTE_COLOR_NONE
    expect(c).toBe('none')
  })
})

describe('isNoteOnly', () => {
  it("returns true only when color is 'none'", () => {
    expect(isNoteOnly({ color: NOTE_COLOR_NONE })).toBe(true)
  })

  it('returns false for every named highlight color', () => {
    for (const c of HIGHLIGHT_COLORS) {
      expect(isNoteOnly({ color: c.name })).toBe(false)
    }
  })

  it('returns false for arbitrary strings (defensive)', () => {
    expect(isNoteOnly({ color: '' })).toBe(false)
    expect(isNoteOnly({ color: 'red' })).toBe(false)
  })
})

describe('getHighlightHex', () => {
  it("returns 'transparent' for the note-only sentinel", () => {
    expect(getHighlightHex(NOTE_COLOR_NONE)).toBe('transparent')
  })

  it('returns the correct hex for each named color (regression guard)', () => {
    for (const c of HIGHLIGHT_COLORS) {
      expect(getHighlightHex(c.name)).toBe(c.hex)
    }
  })
})
