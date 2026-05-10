import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// Use vi.hoisted so these mocks are available when the vi.mock factories run
// (vi.mock calls are hoisted to the top of the file by Vitest).
// ---------------------------------------------------------------------------

const { mockEmbedText, mockSearchVectors } = vi.hoisted(() => ({
  mockEmbedText: vi.fn().mockResolvedValue(new Float32Array([0.1, 0.2, 0.3])),
  mockSearchVectors: vi.fn().mockResolvedValue([])
}))

vi.mock('../../vectordb/index.js', () => ({
  embedText: mockEmbedText,
  searchVectors: mockSearchVectors
}))

vi.mock('../../database/queries.js', () => ({
  searchBookText: vi.fn(),
  getTextFromVectorId: vi.fn()
}))

// Capture the contextForQuery handler when it's registered
let handler: ((event: unknown, q: string, b: number, k: number) => Promise<string[]>) | null = null

vi.mock('electron', () => ({
  ipcMain: {
    handle: vi.fn((channel: string, fn: never) => {
      if (channel === 'search:contextForQuery') {
        handler = fn as never
      }
    })
  }
}))

import { registerSearchHandlers } from '../search.js'

describe('search:contextForQuery index name', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    handler = null
    registerSearchHandlers()
  })

  it('searches the index named `{bookId}-vectordb` (matches process_epub.ts:76)', async () => {
    expect(handler).not.toBeNull()
    await handler!({}, 'what is this book about?', 42, 3)
    expect(mockSearchVectors).toHaveBeenCalledTimes(1)
    expect(mockSearchVectors.mock.calls[0][0]).toBe('42-vectordb')
  })
})
