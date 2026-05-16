import { describe, it, expect } from 'vitest'
import { parseWindowIdentity } from './windowIdentity'

describe('parseWindowIdentity', () => {
  it('returns library when no flag present', () => {
    expect(parseWindowIdentity([])).toEqual({ kind: 'library' })
    expect(parseWindowIdentity(['--user-data-dir=/tmp'])).toEqual({ kind: 'library' })
  })

  it('returns library when --window-identity=library', () => {
    expect(parseWindowIdentity(['--window-identity=library'])).toEqual({ kind: 'library' })
  })

  it('returns book with bookId from --window-identity=book:42', () => {
    expect(parseWindowIdentity(['--window-identity=book:42'])).toEqual({ kind: 'book', bookId: 42 })
  })

  it('parses --window-identity=settings as { kind: "settings" }', () => {
    expect(parseWindowIdentity(['--window-identity=settings'])).toEqual({ kind: 'settings' })
  })

  it('falls back to library on malformed flag', () => {
    expect(parseWindowIdentity(['--window-identity=book:abc'])).toEqual({ kind: 'library' })
    expect(parseWindowIdentity(['--window-identity=garbage'])).toEqual({ kind: 'library' })
  })
})
