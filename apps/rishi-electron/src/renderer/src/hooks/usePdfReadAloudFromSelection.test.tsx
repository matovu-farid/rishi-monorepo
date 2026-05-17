import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { usePdfReadAloudFromSelection } from './usePdfReadAloudFromSelection'
import { usePlayerStore } from '@/stores/playerStore'

/**
 * The bug this test catches: prior implementation rendered a toast saying
 * "not yet supported in PDFs" instead of actually starting TTS from the
 * selected paragraph. EPUB starts TTS by dispatching PLAY_FROM via the
 * player store; PDF should mirror that.
 */
describe('usePdfReadAloudFromSelection', () => {
  let onSpy: ReturnType<typeof vi.fn>
  let unsubscribeSpy: ReturnType<typeof vi.fn>

  beforeEach(() => {
    unsubscribeSpy = vi.fn()
    // The hook subscribes via window.electron.on; capture the listener so the
    // test can fire it deterministically without going through the IPC layer.
    onSpy = vi.fn().mockReturnValue(unsubscribeSpy)
    Object.defineProperty(window.electron, 'on', { value: onSpy, configurable: true })
    usePlayerStore.setState({
      currentParagraphs: [],
      playingState: 'stopped',
      send: vi.fn()
    })
  })

  afterEach(() => {
    window.getSelection()?.removeAllRanges()
  })

  function fireIpc(): void {
    const handler = onSpy.mock.calls.find(([ch]) => ch === 'reader:readAloudFromSelection')?.[1]
    expect(handler).toBeTypeOf('function')
    handler!()
  }

  function seedSelection(text: string): void {
    const root = document.createElement('div')
    const node = document.createTextNode(text)
    root.appendChild(node)
    document.body.appendChild(root)
    const range = document.createRange()
    range.setStart(node, 0)
    range.setEnd(node, text.length)
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
  }

  it('registers the IPC listener on mount and unsubscribes on unmount', () => {
    const { unmount } = renderHook(() => usePdfReadAloudFromSelection({ requireAuth: (_f, run) => run() }))
    expect(onSpy).toHaveBeenCalledWith('reader:readAloudFromSelection', expect.any(Function))
    unmount()
    expect(unsubscribeSpy).toHaveBeenCalledTimes(1)
  })

  it('no-ops when there is no live selection', () => {
    const send = vi.fn()
    usePlayerStore.setState({ send })
    renderHook(() => usePdfReadAloudFromSelection({ requireAuth: (_f, run) => run() }))
    fireIpc()
    expect(send).not.toHaveBeenCalled()
  })

  it('dispatches PLAY_FROM with the paragraph whose text contains the selection', () => {
    const send = vi.fn()
    usePlayerStore.setState({
      send,
      playingState: 'stopped',
      currentParagraphs: [
        { index: '10000', text: 'The quick brown fox jumps over the lazy dog.' },
        { index: '10001', text: 'A second paragraph about something else.' }
      ]
    })

    seedSelection('brown fox')
    renderHook(() => usePdfReadAloudFromSelection({ requireAuth: (_f, run) => run() }))
    fireIpc()

    expect(send).toHaveBeenCalledTimes(1)
    const event = send.mock.calls[0][0]
    expect(event.type).toBe('PLAY_FROM')
    expect(event.paragraphIndex).toBe(0)
    // partialFirstText should start at or before the matched offset; with sentence
    // boundary at position 0 of paragraph 0, the whole paragraph is returned.
    expect(typeof event.partialFirstText).toBe('string')
    expect(event.partialFirstText.length).toBeGreaterThan(0)
    expect(event.partialFirstKey).toMatch(/^10000#s=/)
  })

  it('bails when player is idle or pageNavigating (mirrors EpubView guard)', () => {
    const send = vi.fn()
    usePlayerStore.setState({
      send,
      playingState: 'idle',
      currentParagraphs: [{ index: '10000', text: 'hello world' }]
    })
    seedSelection('hello')
    renderHook(() => usePdfReadAloudFromSelection({ requireAuth: (_f, run) => run() }))
    fireIpc()
    expect(send).not.toHaveBeenCalled()
  })

  it('bails when currentParagraphs is empty', () => {
    const send = vi.fn()
    usePlayerStore.setState({ send, playingState: 'stopped', currentParagraphs: [] })
    seedSelection('hello')
    renderHook(() => usePdfReadAloudFromSelection({ requireAuth: (_f, run) => run() }))
    fireIpc()
    expect(send).not.toHaveBeenCalled()
  })

  it('routes through requireAuth (TTS is a premium feature)', () => {
    const send = vi.fn()
    usePlayerStore.setState({
      send,
      playingState: 'stopped',
      currentParagraphs: [{ index: '10000', text: 'hello world this is fine.' }]
    })
    seedSelection('hello')
    const requireAuth = vi.fn((_feature: string, run: () => void) => run())
    renderHook(() => usePdfReadAloudFromSelection({ requireAuth }))
    fireIpc()
    expect(requireAuth).toHaveBeenCalledWith('tts', expect.any(Function))
    expect(send).toHaveBeenCalledTimes(1)
  })
})
