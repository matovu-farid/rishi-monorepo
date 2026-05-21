/**
 * G10 — Mobile re-exports NOTE_COLOR_NONE + isNoteOnly from
 * `@rishi/shared/types/highlight` so mobile call sites can detect
 * note-only highlights once the schema migration lands.
 */
import { NOTE_COLOR_NONE, isNoteOnly } from '@/types/highlight'

describe('mobile NOTE_COLOR_NONE re-export', () => {
  it('exports the sentinel "none"', () => {
    expect(NOTE_COLOR_NONE).toBe('none')
  })

  it('isNoteOnly returns true for the sentinel', () => {
    expect(isNoteOnly({ color: NOTE_COLOR_NONE })).toBe(true)
  })

  it('isNoteOnly returns false for a real palette color', () => {
    expect(isNoteOnly({ color: 'yellow' })).toBe(false)
    expect(isNoteOnly({ color: 'pink' })).toBe(false)
  })
})
