import { describe, it, expect, vi, type Mock } from 'vitest'
import type { RagIpcChannels } from './index'
import { createRagService } from './index'

type EmbedFn = (text: string) => Promise<number[]>

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
export function makeEmbed(): Mock<EmbedFn> {
  return vi.fn<EmbedFn>().mockResolvedValue(new Array(384).fill(0.5))
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

  it('returns [] immediately for empty query without calling embed or IPC', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('', 5, 3)

    expect(result).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })

  it('returns [] immediately for whitespace-only query', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('   \n\t  ', 5, 3)

    expect(result).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })

  it('silently drops vector hits whose chunk row is missing', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      searchVectors: vi.fn().mockResolvedValue([
        { id: 10, distance: 0.1 },
        { id: 20, distance: 0.2 },
        { id: 30, distance: 0.3 },
      ]),
      getTextFromVectorId: vi.fn(async (id: number) => {
        if (id === 10) return { id: 10, pageNumber: 1, bookId: 5, data: 'ten' }
        if (id === 20) return undefined // orphaned vector
        if (id === 30) return { id: 30, pageNumber: 3, bookId: 5, data: 'thirty' }
        return undefined
      }),
    })
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('q', 5, 3)

    expect(result).toHaveLength(2)
    expect(result.map((c) => c.chunkId)).toEqual([10, 30])
  })

  it('propagates embed failure and does not call searchVectors', async () => {
    const embed = vi.fn<EmbedFn>().mockRejectedValue(new Error('embedding provider unavailable'))
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    await expect(service.searchSemantic('hello', 5, 3)).rejects.toThrow(
      'embedding provider unavailable'
    )
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })
})
