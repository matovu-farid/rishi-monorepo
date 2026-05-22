import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { usePlayerStore } from '@/stores/playerStore'

// Mock the IPC layer BEFORE importing the hook so the spy is in place
// when the module initializes its subscription wrapper.
const updateBookLastParagraph = vi.fn().mockResolvedValue(undefined)
vi.mock('@/lib/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/api')>()
  return {
    ...actual,
    updateBookLastParagraph: (...args: Parameters<typeof actual.updateBookLastParagraph>) =>
      updateBookLastParagraph(...args)
  }
})

import { startResumeWriteSubscription } from '@/hooks/usePlayerMachine'

describe('startResumeWriteSubscription', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    updateBookLastParagraph.mockClear()
    usePlayerStore.setState({
      activeParagraph: null,
      lastPlayedParagraphIndex: null
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('mirrors activeParagraph.index to lastPlayedParagraphIndex synchronously', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-3', text: 't' } })
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBe('p-3')
    dispose()
  })

  it('debounces IPC writes to a single trailing call at 500ms', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-1', text: 't' } })
    usePlayerStore.setState({ activeParagraph: { index: 'p-2', text: 't' } })
    usePlayerStore.setState({ activeParagraph: { index: 'p-3', text: 't' } })

    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    vi.advanceTimersByTime(499)
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-3'
    })
    dispose()
  })

  it('does not write when activeParagraph transitions to null', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-1', text: 't' } })
    usePlayerStore.setState({ activeParagraph: null })
    vi.advanceTimersByTime(1000)
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-1'
    })
    dispose()
  })

  it('flush() writes a pending debounced value synchronously', () => {
    const { dispose, flush } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-9', text: 't' } })
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    flush()
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-9'
    })
    dispose()
  })

  it('flush() is a no-op when no debounced write is pending', () => {
    const { dispose, flush } = startResumeWriteSubscription({ bookId: 42 })
    flush()
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    dispose()
  })
})
