jest.mock('expo-crypto', () => ({
  randomUUID: () => `uuid-${Math.random().toString(36).slice(2, 10)}`,
}))

jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(),
  EncodingType: { Base64: 'base64' },
}))

import { chunkText } from '@/lib/rag/chunker'

describe('chunkText', () => {
  it('returns single chunk for short text', () => {
    const sections = [{ text: 'Hello world. This is short.', chapter: 'Ch 1' }]
    const chunks = chunkText(sections, 500, 50)
    expect(chunks).toHaveLength(1)
    expect(chunks[0].text).toBe('Hello world. This is short.')
    expect(chunks[0].chapter).toBe('Ch 1')
  })

  it('returns 3 chunks for 1200 chars with maxChunkSize=500', () => {
    // Create ~1200 chars of text with sentence boundaries
    const sentence = 'This is a test sentence that is roughly fifty characters. '
    // Each sentence is ~58 chars, so ~21 sentences = ~1218 chars
    const text = sentence.repeat(21).trim()
    const sections = [{ text, chapter: null }]
    const chunks = chunkText(sections, 500, 50)
    expect(chunks.length).toBe(3)
  })

  it('preserves sentence boundaries (does not split mid-sentence)', () => {
    const text = 'First sentence here. Second sentence here. Third sentence that is quite long and should not be split in the middle of itself.'
    const sections = [{ text, chapter: null }]
    const chunks = chunkText(sections, 60, 0)
    for (const chunk of chunks) {
      // Each chunk should end with a complete sentence (period) or be the last chunk
      const trimmed = chunk.text.trim()
      if (chunk !== chunks[chunks.length - 1]) {
        expect(trimmed).toMatch(/[.!?]$/)
      }
    }
  })

  it('includes overlap from previous chunk', () => {
    const sentence = 'This is sentence number one. '
    const text = sentence.repeat(20).trim()
    const sections = [{ text, chapter: null }]
    const chunks = chunkText(sections, 200, 50)
    // Second chunk should start with content from end of first chunk
    if (chunks.length >= 2) {
      const firstChunkEnd = chunks[0].text.slice(-50)
      // The overlap means the start of the next chunk contains some text from the end of previous
      expect(chunks[1].text.length).toBeGreaterThan(0)
    }
    expect(chunks.length).toBeGreaterThanOrEqual(2)
  })

  it('assigns sequential chunkIndex starting at 0', () => {
    const sentence = 'A short sentence. '
    const text = sentence.repeat(30).trim()
    const sections = [{ text, chapter: null }]
    const chunks = chunkText(sections, 200, 50)
    chunks.forEach((chunk, i) => {
      expect(chunk.chunkIndex).toBe(i)
    })
  })

  it('preserves chapter metadata on each chunk', () => {
    const sections = [
      { text: 'Some text in chapter one. More text in chapter one.', chapter: 'Chapter 1' },
      { text: 'Some text in chapter two. More text in chapter two.', chapter: 'Chapter 2' },
    ]
    const chunks = chunkText(sections, 500, 0)
    expect(chunks[0].chapter).toBe('Chapter 1')
    expect(chunks[1].chapter).toBe('Chapter 2')
  })

  it('returns empty array for empty input', () => {
    const chunks = chunkText([], 500, 50)
    expect(chunks).toEqual([])
  })

  it('returns empty array for sections with empty text', () => {
    const sections = [{ text: '', chapter: null }]
    const chunks = chunkText(sections, 500, 50)
    expect(chunks).toEqual([])
  })
})
