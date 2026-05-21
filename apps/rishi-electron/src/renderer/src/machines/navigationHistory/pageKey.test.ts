import { describe, it, expect } from 'vitest'
import { pageKey } from './pageKey'

describe('pageKey', () => {
  it('PDF key ignores scroll offset', () => {
    expect(pageKey({ kind: 'pdf', page: 42, offset: 0 })).toBe('pdf:42')
    expect(pageKey({ kind: 'pdf', page: 42, offset: 350 })).toBe('pdf:42')
  })

  it('EPUB key reflects spine index only', () => {
    // CFI format: epubcfi(/6/<spinePos*2+2>!/...)
    const cfiA = 'epubcfi(/6/14!/4/2/2,/1:0,/1:100)'  // spinePos 6
    const cfiB = 'epubcfi(/6/14!/4/4/2,/1:0,/1:100)'  // same spinePos 6, different intra-spine
    expect(pageKey({ kind: 'epub', cfi: cfiA })).toBe(pageKey({ kind: 'epub', cfi: cfiB }))
  })

  it('different spine indices yield different keys', () => {
    const cfi1 = 'epubcfi(/6/4!/4/2/2,/1:0,/1:100)'   // spinePos 1
    const cfi2 = 'epubcfi(/6/14!/4/2/2,/1:0,/1:100)'  // spinePos 6
    expect(pageKey({ kind: 'epub', cfi: cfi1 })).not.toBe(pageKey({ kind: 'epub', cfi: cfi2 }))
  })

  it('AZW3 uses its own keyspace with the cfi string', () => {
    expect(pageKey({ kind: 'azw3', cfi: '3:1' })).toBe('azw3:3:1')
    expect(pageKey({ kind: 'azw3', cfi: '7' })).toBe('azw3:7')
  })

  it('MOBI uses its own keyspace with the cfi string', () => {
    expect(pageKey({ kind: 'mobi', cfi: '5' })).toBe('mobi:5')
    expect(pageKey({ kind: 'mobi', cfi: '0' })).toBe('mobi:0')
  })

  it('AZW3 and MOBI keys do not collide with each other for the same value', () => {
    expect(pageKey({ kind: 'azw3', cfi: '3' })).not.toBe(pageKey({ kind: 'mobi', cfi: '3' }))
  })

  it('AZW3 and MOBI never throw on non-CFI strings', () => {
    // Regression test: previously pageKey threw because new EpubCFI('3:1') is invalid
    expect(() => pageKey({ kind: 'azw3', cfi: '3:1' })).not.toThrow()
    expect(() => pageKey({ kind: 'mobi', cfi: '5' })).not.toThrow()
  })
})
