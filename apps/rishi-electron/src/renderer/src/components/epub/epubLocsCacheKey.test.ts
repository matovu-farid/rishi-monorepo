import { describe, it, expect } from 'vitest'
import { epubLocsCacheKey } from './epubLocsCacheKey'

describe('epubLocsCacheKey', () => {
  it('includes the book id and charsPerPage in the key', () => {
    const key = epubLocsCacheKey(42, 1600)
    expect(key).toContain('42')
    expect(key).toContain('1600')
  })

  it('produces a different key when charsPerPage changes (so stale caches are evicted)', () => {
    // The whole point of the change: if anyone tunes CHARS_PER_PAGE
    // without bumping the v5 schema tag, the persisted localStorage
    // entries must no longer match — otherwise they silently misrender
    // against an index generated for a different page size.
    const at1600 = epubLocsCacheKey(42, 1600)
    const at1200 = epubLocsCacheKey(42, 1200)
    expect(at1600).not.toBe(at1200)
  })
})
