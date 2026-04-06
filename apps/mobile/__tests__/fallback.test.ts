import { embedTextsOnServer } from '@/lib/rag/server-fallback'

// Mock the apiClient module
jest.mock('@/lib/api', () => ({
  apiClient: jest.fn(),
}))

import { apiClient } from '@/lib/api'

const mockApiClient = apiClient as jest.MockedFunction<typeof apiClient>

describe('embedTextsOnServer', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  it('calls apiClient with POST /api/embed and JSON body containing texts array', async () => {
    const mockEmbeddings = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
    mockApiClient.mockResolvedValue({
      ok: true,
      json: async () => ({ embeddings: mockEmbeddings }),
    } as unknown as Response)

    const texts = ['hello world', 'test text']
    await embedTextsOnServer(texts)

    expect(mockApiClient).toHaveBeenCalledWith('/api/embed', {
      method: 'POST',
      body: JSON.stringify({ texts }),
    })
  })

  it('returns the embeddings array from the response', async () => {
    const mockEmbeddings = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
    mockApiClient.mockResolvedValue({
      ok: true,
      json: async () => ({ embeddings: mockEmbeddings }),
    } as unknown as Response)

    const result = await embedTextsOnServer(['hello', 'world'])
    expect(result).toEqual(mockEmbeddings)
  })

  it('throws error if response is not ok', async () => {
    mockApiClient.mockResolvedValue({
      ok: false,
      status: 500,
      text: async () => 'Internal Server Error',
    } as unknown as Response)

    await expect(embedTextsOnServer(['hello'])).rejects.toThrow(
      'Server embedding failed (500): Internal Server Error'
    )
  })
})
