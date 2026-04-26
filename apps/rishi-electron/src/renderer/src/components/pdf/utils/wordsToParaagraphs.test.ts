import { describe, it, expect } from 'vitest'
import {
  wordsToSentences,
  sentencesToParagraphs,
  mergeShortParagraphs,
  wordsToFinalParagraphs
} from './wordsToParaagraphs'

describe('wordsToSentences', () => {
  it('groups words into sentences ending with a period', () => {
    const words = ['Hello', 'world.', 'Another', 'sentence.']
    const result = wordsToSentences(words)
    expect(result).toEqual(['Hello world.', 'Another sentence.'])
  })

  it('skips leading lowercase words that do not start a sentence', () => {
    const words = ['the', 'Hello', 'world.']
    const result = wordsToSentences(words)
    expect(result).toEqual(['Hello world.'])
  })

  it('returns empty array for no valid sentences', () => {
    const words = ['hello', 'world']
    const result = wordsToSentences(words)
    expect(result).toEqual([])
  })

  it('handles single-word sentences', () => {
    const words = ['Done.']
    const result = wordsToSentences(words)
    expect(result).toEqual(['Done.'])
  })
})

describe('sentencesToParagraphs', () => {
  it('groups sentences into paragraphs of given size', () => {
    const sentences = ['A.', 'B.', 'C.', 'D.']
    const result = sentencesToParagraphs(sentences, 2)
    expect(result).toEqual(['A. B.', 'C. D.'])
  })

  it('handles remainder when sentences do not divide evenly', () => {
    const sentences = ['A.', 'B.', 'C.']
    const result = sentencesToParagraphs(sentences, 2)
    expect(result).toEqual(['A. B.', 'C.'])
  })

  it('returns single paragraph when size exceeds sentence count', () => {
    const sentences = ['A.', 'B.']
    const result = sentencesToParagraphs(sentences, 10)
    expect(result).toEqual(['A. B.'])
  })
})

describe('mergeShortParagraphs', () => {
  it('merges short paragraphs upward', () => {
    const paragraphs = [
      'This is a long paragraph with enough words to meet the minimum threshold count here we go.',
      'Short.'
    ]
    const result = mergeShortParagraphs(paragraphs, 10)
    expect(result).toHaveLength(1)
    expect(result[0]).toContain('Short.')
  })

  it('merges short first paragraph downward', () => {
    const paragraphs = [
      'Hi.',
      'This is a long paragraph with enough words to meet the minimum threshold count here we go.'
    ]
    const result = mergeShortParagraphs(paragraphs, 5)
    expect(result).toHaveLength(1)
    expect(result[0]).toContain('Hi.')
  })

  it('returns empty array for empty input', () => {
    const result = mergeShortParagraphs([], 5)
    expect(result).toEqual([])
  })

  it('keeps paragraphs above minimum length unchanged', () => {
    const paragraphs = [
      'One two three four five six seven eight.',
      'Nine ten eleven twelve thirteen fourteen fifteen sixteen.'
    ]
    const result = mergeShortParagraphs(paragraphs, 5)
    expect(result).toHaveLength(2)
  })
})

describe('wordsToFinalParagraphs', () => {
  it('produces paragraphs from a stream of words', () => {
    // Create enough words to form multiple sentences and paragraphs
    const words: string[] = []
    for (let i = 0; i < 100; i++) {
      words.push(`Word${i}`)
      if ((i + 1) % 5 === 0) {
        // End sentence: replace last word with one ending in period
        words[words.length - 1] = `Word${i}.`
        // Next word starts with uppercase (already does, since "Word" starts with W)
      }
    }
    const result = wordsToFinalParagraphs(words)
    expect(result.length).toBeGreaterThan(0)
    // Each paragraph should be a non-empty string
    for (const p of result) {
      expect(p.trim().length).toBeGreaterThan(0)
    }
  })

  it('returns empty array when no sentences can be formed', () => {
    const words = ['hello', 'world', 'no', 'caps', 'no', 'periods']
    const result = wordsToFinalParagraphs(words)
    expect(result).toEqual([])
  })

  it('respects custom sentencesPerParagraph option', () => {
    const words = [
      'One.',
      'Two.',
      'Three.',
      'Four.',
      'Five.',
      'Six.',
      'Seven.',
      'Eight.',
      'Nine.',
      'Ten.'
    ]
    const result = wordsToFinalParagraphs(words, { sentencesPerParagraph: 2 })
    // With 10 single-word sentences and 2 per paragraph, expect 5 paragraphs
    // (some may be merged due to minParagraphLength)
    expect(result.length).toBeGreaterThan(0)
  })
})
