import { vi } from 'vitest'
import type { RagIpcChannels } from './index'

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
