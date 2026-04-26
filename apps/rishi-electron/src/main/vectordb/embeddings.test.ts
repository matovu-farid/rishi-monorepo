import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// Mock @xenova/transformers
// ---------------------------------------------------------------------------

const mockPipeline = vi.fn()

vi.mock('@xenova/transformers', () => ({
  pipeline: mockPipeline
}))

// Import after mocking so the mock takes effect
import { generateEmbeddings, _resetForTesting } from './embeddings.js'
import type { EmbeddingInput } from './embeddings.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build a fake pipeline function that returns a tensor-like object.
 *
 * @param dim   - The embedding dimension.
 * @param value - A constant value to fill all embedding dimensions with
 *                (makes assertions deterministic).
 */
function createMockPipe(dim = 384, value = 0.1) {
  return vi.fn().mockImplementation((sentences: string[]) => {
    const batchSize = sentences.length
    const data = new Float32Array(batchSize * dim).fill(value)
    return Promise.resolve({
      data,
      dims: [batchSize, dim]
    })
  })
}

function makeInput(overrides: Partial<EmbeddingInput> = {}): EmbeddingInput {
  return {
    text: overrides.text ?? 'hello world',
    metadata: overrides.metadata ?? { id: 1, pageNumber: 1, bookId: 1 }
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('generateEmbeddings', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    _resetForTesting()
  })

  it('returns an empty array when given an empty input', async () => {
    const results = await generateEmbeddings([])
    expect(results).toEqual([])
    // Pipeline should never be created for empty input
    expect(mockPipeline).not.toHaveBeenCalled()
  })

  it('returns the correct structure for a single input', async () => {
    const mockPipe = createMockPipe(384, 0.5)
    mockPipeline.mockResolvedValueOnce(mockPipe)

    const input: EmbeddingInput = {
      text: 'The quick brown fox',
      metadata: { id: 42, pageNumber: 7, bookId: 3 }
    }

    const results = await generateEmbeddings([input])

    expect(results).toHaveLength(1)
    expect(results[0]).toMatchObject({
      dim: 384,
      text: 'The quick brown fox',
      metadata: { id: 42, pageNumber: 7, bookId: 3 }
    })
    expect(results[0].embedding).toHaveLength(384)
    // All values should be finite numbers
    expect(results[0].embedding.every((v) => Number.isFinite(v))).toBe(true)
  })

  it('processes multiple inputs and preserves order', async () => {
    const mockPipe = createMockPipe()
    mockPipeline.mockResolvedValueOnce(mockPipe)

    const inputs: EmbeddingInput[] = [
      makeInput({ text: 'first', metadata: { id: 1, pageNumber: 1, bookId: 1 } }),
      makeInput({ text: 'second', metadata: { id: 2, pageNumber: 2, bookId: 1 } }),
      makeInput({ text: 'third', metadata: { id: 3, pageNumber: 3, bookId: 1 } })
    ]

    const results = await generateEmbeddings(inputs)

    expect(results).toHaveLength(3)
    expect(results[0].text).toBe('first')
    expect(results[1].text).toBe('second')
    expect(results[2].text).toBe('third')
    expect(results[0].metadata.id).toBe(1)
    expect(results[1].metadata.id).toBe(2)
    expect(results[2].metadata.id).toBe(3)
  })

  it('splits large inputs into batches of 32', async () => {
    const mockPipe = createMockPipe()
    mockPipeline.mockResolvedValueOnce(mockPipe)

    // Create 50 inputs -> should result in 2 batches (32 + 18)
    const inputs: EmbeddingInput[] = Array.from({ length: 50 }, (_, i) =>
      makeInput({
        text: `sentence ${i}`,
        metadata: { id: i, pageNumber: i, bookId: 1 }
      })
    )

    const results = await generateEmbeddings(inputs)

    expect(results).toHaveLength(50)
    // The mock pipe should have been called twice (batch of 32 + batch of 18)
    expect(mockPipe).toHaveBeenCalledTimes(2)
    expect(mockPipe.mock.calls[0][0]).toHaveLength(32)
    expect(mockPipe.mock.calls[1][0]).toHaveLength(18)
  })

  it('caches the pipeline instance across multiple calls', async () => {
    const mockPipe = createMockPipe()
    mockPipeline.mockResolvedValueOnce(mockPipe)

    // We need a fresh module to test caching. Since vi.resetModules() was
    // called in beforeEach, the import at the top is stale. For this test
    // we use the already-imported `generateEmbeddings` and call it twice.
    await generateEmbeddings([makeInput()])
    await generateEmbeddings([makeInput({ text: 'another' })])

    // pipeline() factory should only have been called once
    expect(mockPipeline).toHaveBeenCalledTimes(1)
    // But the pipe function itself should have been called twice
    expect(mockPipe).toHaveBeenCalledTimes(2)
  })

  it('throws a descriptive error when the model fails to load', async () => {
    mockPipeline.mockRejectedValueOnce(new Error('Network timeout'))

    await expect(generateEmbeddings([makeInput()])).rejects.toThrow(
      /Failed to load the embedding model.*Network timeout/
    )
  })

  it('allows retry after model load failure', async () => {
    // First call fails
    mockPipeline.mockRejectedValueOnce(new Error('Network timeout'))
    await expect(generateEmbeddings([makeInput()])).rejects.toThrow(
      /Failed to load the embedding model/
    )

    // Second call succeeds after retry
    const mockPipe = createMockPipe()
    mockPipeline.mockResolvedValueOnce(mockPipe)
    const results = await generateEmbeddings([makeInput()])
    expect(results).toHaveLength(1)
    expect(mockPipeline).toHaveBeenCalledTimes(2)
  })

  it('returns embeddings with the correct dimension from the model output', async () => {
    // Simulate a model that returns 512-dim embeddings
    const mockPipe = createMockPipe(512, 0.3)
    mockPipeline.mockResolvedValueOnce(mockPipe)

    const results = await generateEmbeddings([makeInput()])

    expect(results[0].dim).toBe(512)
    expect(results[0].embedding).toHaveLength(512)
  })

  it('passes metadata through unmodified', async () => {
    const mockPipe = createMockPipe()
    mockPipeline.mockResolvedValueOnce(mockPipe)

    const metadata = { id: 99, pageNumber: 42, bookId: 7 }
    const results = await generateEmbeddings([makeInput({ text: 'test', metadata })])

    expect(results[0].metadata).toEqual(metadata)
  })
})
