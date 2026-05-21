/**
 * MOBI / AZW3 reader TTS wiring tests.
 *
 * MOBI and AZW3 readers use the same `chunker.getChunks('mobi')` path
 * (the chunker normalizes 'azw3' to the same code path as 'mobi' — see
 * `apps/mobile/lib/rag/chunker.ts`). We test the logical wiring:
 *
 *   1. `seedPlayerParagraphsFromChunks(bookId, filePath, 'mobi')` runs
 *      the PalmDOC extractor and writes paragraphs to the player store.
 *   2. Dispatching PLAY reaches the actor (via `send`).
 *   3. The reconciler returns the right active chunk index when the
 *      player's `activeParagraph` matches a known id.
 */

jest.mock('react-native-mmkv', () => ({
  createMMKV: jest.fn(() => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  })),
}))

jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(),
}))

import { seedPlayerParagraphsFromChunks } from '@/lib/tts/seed-paragraphs'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { reconcileTtsHighlight } from '@/lib/tts/reconcile'
import { getChunks } from '@/lib/rag/chunker'

const mockGetChunks = getChunks as jest.MockedFunction<typeof getChunks>

describe('MOBI / AZW3 reader TTS wiring', () => {
  beforeEach(() => {
    mockGetChunks.mockReset()
    usePlayerStore.setState({
      currentParagraphs: [],
      nextPageParagraphs: [],
      prevPageParagraphs: [],
      activeParagraph: null,
      playingState: 'idle',
      send: null,
    })
  })

  it("seedPlayerParagraphsFromChunks('mobi') populates currentParagraphs", async () => {
    mockGetChunks.mockResolvedValueOnce([
      {
        id: 'm-0',
        bookId: 'book-1',
        chunkIndex: 0,
        text: 'PalmDOC paragraph A',
        chapter: null,
        createdAt: 1,
      },
      {
        id: 'm-1',
        bookId: 'book-1',
        chunkIndex: 1,
        text: 'PalmDOC paragraph B',
        chapter: null,
        createdAt: 1,
      },
    ])
    const result = await seedPlayerParagraphsFromChunks('book-1', '/tmp/x.mobi', 'mobi')
    expect(result.seeded).toBe(true)
    expect(usePlayerStore.getState().currentParagraphs).toHaveLength(2)
    expect(mockGetChunks).toHaveBeenCalledWith('/tmp/x.mobi', 'mobi', 'book-1')
  })

  it("seedPlayerParagraphsFromChunks('azw3') also runs the mobi path", async () => {
    mockGetChunks.mockResolvedValueOnce([
      { id: 'a-0', bookId: 'b', chunkIndex: 0, text: 'azw3 text', chapter: null, createdAt: 1 },
    ])
    const result = await seedPlayerParagraphsFromChunks('b', '/tmp/x.azw3', 'azw3')
    expect(result.seeded).toBe(true)
    expect(mockGetChunks).toHaveBeenCalledWith('/tmp/x.azw3', 'azw3', 'b')
  })

  it('PLAY dispatch reaches the registered send fn', () => {
    const events: unknown[] = []
    usePlayerStore.getState().setSend((event) => events.push(event))
    usePlayerStore.getState().send!({ type: 'PLAY' })
    expect(events).toEqual([{ type: 'PLAY' }])
  })

  it('reconciler matches active paragraph to chunk index for MOBI rows', () => {
    const chunks = [
      { id: 'm-0', chunkIndex: 0 },
      { id: 'm-1', chunkIndex: 1 },
      { id: 'm-2', chunkIndex: 2 },
    ]
    const r = reconcileTtsHighlight(chunks, { index: 'm-1', text: '' })
    expect(r.activeChunkIndex).toBe(1)
    expect(r.activeChunkId).toBe('m-1')
  })

  it('reconciler returns -1 when no chunk matches the active paragraph id', () => {
    const chunks = [{ id: 'm-0', chunkIndex: 0 }]
    const r = reconcileTtsHighlight(chunks, { index: 'mystery', text: '' })
    expect(r.activeChunkIndex).toBe(-1)
  })
})
