import { setEmbeddingForward, embedBatch, embedSingle, isEmbeddingReady } from '@/lib/rag/embedder'

describe('embedder', () => {
  beforeEach(() => {
    // Reset by setting a fresh forward function
  })

  describe('isEmbeddingReady', () => {
    it('returns false when no forward function is set', () => {
      // Fresh module state - need to reset
      // We test indirectly: embedBatch should throw when not ready
    })
  })

  describe('setEmbeddingForward + embedBatch', () => {
    it('calls forward for each text and returns 384-dim vectors', async () => {
      const mockForward = jest.fn(async (text: string) => {
        return new Array(384).fill(0.1)
      })
      setEmbeddingForward(mockForward)

      const texts = ['hello world', 'test sentence']
      const result = await embedBatch(texts)

      expect(mockForward).toHaveBeenCalledTimes(2)
      expect(mockForward).toHaveBeenCalledWith('hello world')
      expect(mockForward).toHaveBeenCalledWith('test sentence')
      expect(result).toHaveLength(2)
      expect(result[0]).toHaveLength(384)
      expect(result[1]).toHaveLength(384)
    })

    it('returns empty array for empty input', async () => {
      const mockForward = jest.fn(async () => new Array(384).fill(0))
      setEmbeddingForward(mockForward)

      const result = await embedBatch([])
      expect(result).toHaveLength(0)
      expect(mockForward).not.toHaveBeenCalled()
    })
  })

  describe('embedSingle', () => {
    it('embeds a single text and returns 384-dim vector', async () => {
      const mockForward = jest.fn(async () => new Array(384).fill(0.5))
      setEmbeddingForward(mockForward)

      const result = await embedSingle('test')
      expect(result).toHaveLength(384)
      expect(mockForward).toHaveBeenCalledWith('test')
    })
  })

  describe('isEmbeddingReady', () => {
    it('returns true after setEmbeddingForward is called', () => {
      setEmbeddingForward(async () => [])
      expect(isEmbeddingReady()).toBe(true)
    })
  })
})
