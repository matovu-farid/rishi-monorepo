import { findWordAtPdfPoint, wordsBetween } from '@/lib/pdf/word-hit-test'

const words = [
  { idx: 0, text: 'Hello',  x:  72, y: 720, w: 40, h: 12 },
  { idx: 1, text: 'world',  x: 120, y: 720, w: 40, h: 12 },
  { idx: 2, text: 'second', x:  72, y: 700, w: 50, h: 12 },
  { idx: 3, text: 'line',   x: 130, y: 700, w: 30, h: 12 },
]

describe('findWordAtPdfPoint', () => {
  it('returns the word whose rect contains the point', () => {
    expect(findWordAtPdfPoint(words, { x: 90, y: 725 })?.text).toBe('Hello')
    expect(findWordAtPdfPoint(words, { x: 140, y: 725 })?.text).toBe('world')
  })

  it('returns null when no word contains the point', () => {
    expect(findWordAtPdfPoint(words, { x: 10, y: 10 })).toBeNull()
  })
})

describe('wordsBetween', () => {
  it('returns inclusive range by idx', () => {
    const range = wordsBetween(words, words[0], words[2])
    expect(range.map((w) => w.text)).toEqual(['Hello', 'world', 'second'])
  })

  it('swaps order when start is after end', () => {
    const range = wordsBetween(words, words[3], words[1])
    expect(range.map((w) => w.text)).toEqual(['world', 'second', 'line'])
  })
})
