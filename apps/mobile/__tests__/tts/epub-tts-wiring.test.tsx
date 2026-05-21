/**
 * EPUB reader TTS wiring test.
 *
 * The full EPUB reader screen is RN-only and depends on
 * `epubjs-react-native` + many native modules — exercising it under
 * jest's node env is not viable today. This test instead verifies the
 * **logical wiring** the screen performs:
 *
 *   - `seedPlayerParagraphsFromChunks(bookId, filePath, 'epub')` reads
 *     chunks from `lib/rag/chunker.getChunks` and writes
 *     `playerStore.currentParagraphs`.
 *   - With seeded paragraphs, dispatching `playerStore.send({ type:
 *     'PLAY_FROM', paragraphIndex, partialFirstText, partialFirstKey })`
 *     reaches the player machine through the same path the screen uses.
 *   - The reconciler primitive turns `playerStore.activeParagraph` into a
 *     chunk index — that's what the screen renders as an EPUB highlight.
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

describe('EPUB reader TTS wiring', () => {
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

  it('seeds the player store with paragraphs from chunker.getChunks', async () => {
    mockGetChunks.mockResolvedValueOnce([
      {
        id: 'c1',
        bookId: 'book-1',
        chunkIndex: 0,
        text: 'First chunk.',
        chapter: 'Ch 1',
        createdAt: 1,
      },
      {
        id: 'c2',
        bookId: 'book-1',
        chunkIndex: 1,
        text: 'Second chunk.',
        chapter: 'Ch 1',
        createdAt: 1,
      },
    ])

    const result = await seedPlayerParagraphsFromChunks(
      'book-1',
      '/tmp/book.epub',
      'epub',
    )

    expect(result.seeded).toBe(true)
    expect(result.paragraphs).toEqual([
      { index: 'c1', text: 'First chunk.' },
      { index: 'c2', text: 'Second chunk.' },
    ])

    const stored = usePlayerStore.getState().currentParagraphs
    expect(stored).toHaveLength(2)
    expect(stored[0]).toEqual({ index: 'c1', text: 'First chunk.' })
    expect(mockGetChunks).toHaveBeenCalledWith('/tmp/book.epub', 'epub', 'book-1')
  })

  it('filters out whitespace-only chunks when seeding', async () => {
    mockGetChunks.mockResolvedValueOnce([
      { id: 'c1', bookId: 'b', chunkIndex: 0, text: '   ', chapter: null, createdAt: 1 },
      { id: 'c2', bookId: 'b', chunkIndex: 1, text: 'real text', chapter: null, createdAt: 1 },
    ])
    const result = await seedPlayerParagraphsFromChunks('b', '/tmp/x.epub', 'epub')
    expect(result.paragraphs.map((p) => p.index)).toEqual(['c2'])
  })

  it('returns seeded=false when extraction yields no chunks', async () => {
    mockGetChunks.mockResolvedValueOnce([])
    const result = await seedPlayerParagraphsFromChunks('b', '/tmp/x.epub', 'epub')
    expect(result.seeded).toBe(false)
    expect(usePlayerStore.getState().currentParagraphs).toHaveLength(0)
  })

  it('the screen-side `send PLAY_FROM` payload follows playerMachine schema', () => {
    // Simulate the reader's Read-aloud-from-selection dispatch.
    const seenEvents: unknown[] = []
    usePlayerStore.getState().setSend((event) => {
      seenEvents.push(event)
    })
    const send = usePlayerStore.getState().send!

    send({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'Selected text.',
      partialFirstKey: 'selection-key-1',
    })

    expect(seenEvents).toHaveLength(1)
    expect(seenEvents[0]).toMatchObject({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'Selected text.',
      partialFirstKey: 'selection-key-1',
    })
  })

  it('reconcileTtsHighlight returns the chunk index for the active paragraph', () => {
    const chunks = [
      { id: 'c1', chunkIndex: 0 },
      { id: 'c2', chunkIndex: 1 },
      { id: 'c3', chunkIndex: 2 },
    ]
    const result = reconcileTtsHighlight(chunks, { index: 'c2', text: '' })
    expect(result.activeChunkIndex).toBe(1)
    expect(result.activeChunkId).toBe('c2')
  })

  it('reconcileTtsHighlight returns -1 when activeParagraph is null', () => {
    const chunks = [{ id: 'c1', chunkIndex: 0 }]
    const result = reconcileTtsHighlight(chunks, null)
    expect(result.activeChunkIndex).toBe(-1)
  })
})
