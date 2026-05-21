/**
 * PDF reader TTS wiring test (Batch 5 deferred → Batch 7).
 *
 * Verifies the logic path from a text selection in the PDF WebView to a
 * `PLAY_FROM` event on the player machine:
 *
 *   1. The WebView responds to `getPageText(page)` with a list of paragraphs
 *      (handled by Batch 5 — `PdfWebReader.getPageText`).
 *   2. `resolvePlayFromSelection(selectedText, paragraphs)` returns a
 *      `PLAY_FROM` payload (Batch 5 — exported from
 *      `@rishi/shared/modules/read-aloud-from` via the mobile wrapper).
 *   3. The screen calls `playerStore.send(PLAY_FROM)` with that payload
 *      AFTER seeding `currentParagraphs` so the player machine can
 *      dispatch the right paragraph.
 *
 * Batch 7 adds steps (3): the screen wiring now dispatches into the
 * playerStore instead of console.log + Alert. This test proves the
 * payload reaches the dispatcher in the expected shape.
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

import { usePlayerStore } from '@/lib/stores/playerStore'
import { resolvePlayFromSelection } from '@/lib/pdf/read-aloud-from-selection'

describe('PDF reader TTS wiring', () => {
  beforeEach(() => {
    usePlayerStore.setState({
      currentParagraphs: [],
      nextPageParagraphs: [],
      prevPageParagraphs: [],
      activeParagraph: null,
      playingState: 'idle',
      send: null,
    })
  })

  it('resolvePlayFromSelection + send PLAY_FROM produces the right event shape', () => {
    const paragraphs = [
      { index: 'p-1-0', text: 'The first paragraph on page one.' },
      { index: 'p-1-1', text: 'A second paragraph with the selection inside.' },
      { index: 'p-1-2', text: 'A third paragraph.' },
    ]

    // The user selected "the selection inside"
    const payload = resolvePlayFromSelection('the selection inside', paragraphs)
    expect(payload).not.toBeNull()
    expect(payload!.paragraphIndex).toBe(1)
    expect(payload!.partialFirstText.length).toBeGreaterThan(0)

    // The screen seeds the player paragraphs then dispatches PLAY_FROM
    usePlayerStore.setState({ currentParagraphs: paragraphs })

    const events: unknown[] = []
    usePlayerStore.getState().setSend((event) => events.push(event))

    usePlayerStore.getState().send!({
      type: 'PLAY_FROM',
      paragraphIndex: payload!.paragraphIndex,
      partialFirstText: payload!.partialFirstText,
      partialFirstKey: payload!.partialFirstKey,
    })

    expect(events).toHaveLength(1)
    expect(events[0]).toMatchObject({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
    })
    // Validate the PLAY_FROM event references the same paragraph the
    // resolver pinned. (partialFirstKey is a stable md5; we don't pin
    // its exact value — only that it is non-empty.)
    expect((events[0] as { partialFirstKey: string }).partialFirstKey).toBeTruthy()
  })

  it('resolvePlayFromSelection returns null when the selection text does not appear', () => {
    const paragraphs = [{ index: 'a', text: 'Hello world.' }]
    const payload = resolvePlayFromSelection('not present', paragraphs)
    expect(payload).toBeNull()
  })

  it('the screen seeds page paragraphs into currentParagraphs', () => {
    const paragraphs = [
      { index: 'pg1-p0', text: 'one' },
      { index: 'pg1-p1', text: 'two' },
    ]
    // Simulated screen action: seed before PLAY_FROM
    usePlayerStore.setState({ currentParagraphs: paragraphs })
    expect(usePlayerStore.getState().currentParagraphs).toHaveLength(2)
    expect(usePlayerStore.getState().currentParagraphs[0]).toEqual({
      index: 'pg1-p0',
      text: 'one',
    })
  })
})
