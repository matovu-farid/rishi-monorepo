import { describe, it, expect } from 'vitest'
import {
  HIGHLIGHT_COLORS,
  NOTE_COLOR_NONE,
  type HighlightColor,
  getHighlightHex,
  getHighlightHexForTheme,
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

describe('getHighlightHexForTheme (#198 dark-mode palette)', () => {
  it("returns 'transparent' for the note-only sentinel in either mode", () => {
    expect(getHighlightHexForTheme(NOTE_COLOR_NONE, 'light')).toBe('transparent')
    expect(getHighlightHexForTheme(NOTE_COLOR_NONE, 'dark')).toBe('transparent')
  })

  it('returns the canonical hex in light mode', () => {
    for (const c of HIGHLIGHT_COLORS) {
      expect(getHighlightHexForTheme(c.name, 'light')).toBe(c.hex)
    }
  })

  it('returns the dark-mode hex in dark mode (≥ 3:1 against #232326)', () => {
    for (const c of HIGHLIGHT_COLORS) {
      expect(getHighlightHexForTheme(c.name, 'dark')).toBe(c.darkHex)
    }
  })

  it('dark variants differ from light variants for every palette color', () => {
    // Regression guard against accidentally re-using the light hex as the
    // dark hex (which is what would re-introduce the 1.2:1 contrast bug).
    for (const c of HIGHLIGHT_COLORS) {
      expect(c.darkHex).not.toBe(c.hex)
    }
  })
})
