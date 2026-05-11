import { describe, it, expect } from 'vitest'
import { tocToChapters } from '../tocToChapters'

describe('tocToChapters', () => {
  it('flattens a flat TOC', () => {
    const toc = [
      { label: 'Chapter 1', href: 'ch1.html', subitems: [] },
      { label: 'Chapter 2', href: 'ch2.html', subitems: [] }
    ]
    expect(tocToChapters(toc as never)).toEqual(['Chapter 1', 'Chapter 2'])
  })

  it('includes nested subchapters', () => {
    const toc = [
      {
        label: 'Part I',
        href: '#',
        subitems: [
          { label: 'Chapter 1', href: 'ch1.html', subitems: [] },
          { label: 'Chapter 2', href: 'ch2.html', subitems: [] }
        ]
      }
    ]
    expect(tocToChapters(toc as never)).toEqual(['Part I', 'Chapter 1', 'Chapter 2'])
  })

  it('filters empty labels', () => {
    const toc = [
      { label: '', href: '#', subitems: [] },
      { label: '  ', href: '#', subitems: [] },
      { label: 'Real Chapter', href: '#', subitems: [] }
    ]
    expect(tocToChapters(toc as never)).toEqual(['Real Chapter'])
  })

  it('trims whitespace', () => {
    const toc = [{ label: '  Chapter 1  ', href: '#', subitems: [] }]
    expect(tocToChapters(toc as never)).toEqual(['Chapter 1'])
  })
})
