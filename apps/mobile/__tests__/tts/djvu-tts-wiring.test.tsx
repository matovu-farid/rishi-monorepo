/**
 * DJVU reader TTS wiring tests.
 *
 * DJVU extraction is gated on `setDjvuExtractor(...)` being called at
 * app start (the DJVU WebView extractor lives in
 * `components/RagExtractorHost.tsx`). When the extractor is missing,
 * `getChunks('djvu')` returns []. The reader should detect that and not
 * dispatch PLAY. When the extractor is registered, paragraphs flow into
 * the player store like every other format.
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
import { getChunks } from '@/lib/rag/chunker'

const mockGetChunks = getChunks as jest.MockedFunction<typeof getChunks>

describe('DJVU reader TTS wiring', () => {
  beforeEach(() => {
    mockGetChunks.mockReset()
    usePlayerStore.setState({
      currentParagraphs: [],
      activeParagraph: null,
      playingState: 'idle',
      send: null,
    })
  })

  it('seedPlayerParagraphsFromChunks returns seeded=false when DJVU extractor unregistered', async () => {
    mockGetChunks.mockResolvedValueOnce([])
    const result = await seedPlayerParagraphsFromChunks('book-1', '/tmp/x.djvu', 'djvu')
    expect(result.seeded).toBe(false)
    expect(usePlayerStore.getState().currentParagraphs).toHaveLength(0)
  })

  it('seedPlayerParagraphsFromChunks populates store when extractor yields paragraphs', async () => {
    mockGetChunks.mockResolvedValueOnce([
      {
        id: 'dj-0',
        bookId: 'book-1',
        chunkIndex: 0,
        text: 'DJVU page text',
        chapter: null,
        createdAt: 1,
      },
    ])
    const result = await seedPlayerParagraphsFromChunks('book-1', '/tmp/x.djvu', 'djvu')
    expect(result.seeded).toBe(true)
    expect(usePlayerStore.getState().currentParagraphs).toEqual([
      { index: 'dj-0', text: 'DJVU page text' },
    ])
    expect(mockGetChunks).toHaveBeenCalledWith('/tmp/x.djvu', 'djvu', 'book-1')
  })

  it('PLAY then STOP cycles dispatch into the player', () => {
    const events: unknown[] = []
    usePlayerStore.getState().setSend((event) => events.push(event))
    const send = usePlayerStore.getState().send!
    send({ type: 'PLAY' })
    send({ type: 'STOP' })
    expect(events).toEqual([{ type: 'PLAY' }, { type: 'STOP' }])
  })
})
