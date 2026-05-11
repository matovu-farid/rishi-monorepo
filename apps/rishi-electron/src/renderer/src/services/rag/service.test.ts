import { describe, it, expect, vi } from 'vitest'
import type { RagIpcChannels } from './index'
import { createRagService } from './index'

/**
 * Build a fake RagIpcChannels. All methods are vi.fn() spies returning
 * sensible defaults; override any individual method via the argument.
 */
export function makeIpc(overrides: Partial<RagIpcChannels> = {}): RagIpcChannels {
  return {
    searchVectors: vi.fn().mockResolvedValue([]),
    getTextFromVectorId: vi.fn().mockResolvedValue(undefined),
    searchBookText: vi.fn().mockResolvedValue([]),
    hasVectorsForBook: vi.fn().mockResolvedValue(false),
    ...overrides,
  }
}

/**
 * Build a deterministic fake embed function. Returns a fixed 384-dim vector
 * regardless of input. Real assertions in tests use spy methods, not vector content.
 */
export function makeEmbed(): ReturnType<typeof vi.fn> {
  return vi.fn().mockResolvedValue(new Array(384).fill(0.5))
}

describe('RagService.searchSemantic', () => {
  it('embeds the query, searches vectors, resolves chunks, and assembles results', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      searchVectors: vi.fn().mockResolvedValue([
        { id: 10, distance: 0.1 },
        { id: 20, distance: 0.3 },
      ]),
      getTextFromVectorId: vi.fn(async (id: number) => {
        if (id === 10) return { id: 10, pageNumber: 3, bookId: 5, data: 'chunk 10 text' }
        if (id === 20) return { id: 20, pageNumber: 7, bookId: 5, data: 'chunk 20 text' }
        return undefined
      }),
    })
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('hello world', 5, 3)

    expect(result).toEqual([
      { chunkId: 10, bookId: 5, pageNumber: 3, text: 'chunk 10 text', distance: 0.1 },
      { chunkId: 20, bookId: 5, pageNumber: 7, text: 'chunk 20 text', distance: 0.3 },
    ])
    expect(embed).toHaveBeenCalledTimes(1)
    expect(embed).toHaveBeenCalledWith('hello world')
    expect(ipc.searchVectors).toHaveBeenCalledTimes(1)
    expect(ipc.searchVectors).toHaveBeenCalledWith(
      '5-vectordb',
      expect.any(Array),
      384,
      3
    )
  })
})
