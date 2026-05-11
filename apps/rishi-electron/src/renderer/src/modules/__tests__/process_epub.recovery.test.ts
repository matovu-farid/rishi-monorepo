import { describe, it, expect, vi, beforeEach } from 'vitest'

const {
  mockSavePageDataMany,
  mockHasSavedEpubData,
  mockSaveVectors,
  mockHasVectorsForBook,
  mockEmbedWithFallback
} = vi.hoisted(() => ({
  mockSavePageDataMany: vi.fn().mockResolvedValue(undefined),
  mockHasSavedEpubData: vi.fn(),
  mockSaveVectors: vi.fn().mockResolvedValue(undefined),
  mockHasVectorsForBook: vi.fn(),
  mockEmbedWithFallback: vi.fn()
}))

vi.mock('@/lib/api', () => ({
  savePageDataMany: mockSavePageDataMany,
  hasSavedEpubData: mockHasSavedEpubData,
  saveVectors: mockSaveVectors,
  hasVectorsForBook: mockHasVectorsForBook
}))

vi.mock('@/modules/embed-fallback', () => ({
  embedWithFallback: mockEmbedWithFallback
}))

import { processEpubJob } from '../process_epub'

const samplePageData = [
  { id: 1, pageNumber: 1, bookId: 42, data: 'Chapter 1 text' },
  { id: 2, pageNumber: 2, bookId: 42, data: 'Chapter 2 text' }
]

const sampleEmbedResults = [
  {
    metadata: { id: 1, pageNumber: 1, bookId: 42 },
    text: 'Chapter 1 text',
    embedding: [0.1, 0.2, 0.3]
  },
  {
    metadata: { id: 2, pageNumber: 2, bookId: 42 },
    text: 'Chapter 2 text',
    embedding: [0.4, 0.5, 0.6]
  }
]

describe('processEpubJob', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockEmbedWithFallback.mockResolvedValue(sampleEmbedResults)
  })

  it('runs full pipeline when neither chunks nor vectors exist', async () => {
    mockHasSavedEpubData.mockResolvedValue(false)
    mockHasVectorsForBook.mockResolvedValue(false)

    await processEpubJob(42, samplePageData)

    expect(mockSavePageDataMany).toHaveBeenCalledTimes(1)
    expect(mockEmbedWithFallback).toHaveBeenCalled()
    expect(mockSaveVectors).toHaveBeenCalled()
    expect(mockSaveVectors.mock.calls[0][0].name).toBe('42-vectordb')
  })

  it('skips entirely when both chunks and vectors exist', async () => {
    mockHasSavedEpubData.mockResolvedValue(true)
    mockHasVectorsForBook.mockResolvedValue(true)

    await processEpubJob(42, samplePageData)

    expect(mockSavePageDataMany).not.toHaveBeenCalled()
    expect(mockEmbedWithFallback).not.toHaveBeenCalled()
    expect(mockSaveVectors).not.toHaveBeenCalled()
  })

  it('REGRESSION: re-embeds when chunks exist but vectors are missing', async () => {
    // This is the user's actual broken state.
    mockHasSavedEpubData.mockResolvedValue(true)
    mockHasVectorsForBook.mockResolvedValue(false)

    await processEpubJob(42, samplePageData)

    expect(mockSavePageDataMany).not.toHaveBeenCalled() // don't re-save chunks
    expect(mockEmbedWithFallback).toHaveBeenCalled() // but DO re-embed
    expect(mockSaveVectors).toHaveBeenCalled()
    expect(mockSaveVectors.mock.calls[0][0].name).toBe('42-vectordb')
  })

  it('does nothing when pageData is empty', async () => {
    await processEpubJob(42, [])

    expect(mockHasSavedEpubData).not.toHaveBeenCalled()
    expect(mockHasVectorsForBook).not.toHaveBeenCalled()
    expect(mockSavePageDataMany).not.toHaveBeenCalled()
  })

  it('continues without crashing when embedding fails after chunks saved', async () => {
    mockHasSavedEpubData.mockResolvedValue(false)
    mockHasVectorsForBook.mockResolvedValue(false)
    mockEmbedWithFallback.mockRejectedValueOnce(new Error('sharp broke'))

    await expect(processEpubJob(42, samplePageData)).resolves.toBeUndefined()

    expect(mockSavePageDataMany).toHaveBeenCalledTimes(1)
    expect(mockSaveVectors).not.toHaveBeenCalled()
  })
})
