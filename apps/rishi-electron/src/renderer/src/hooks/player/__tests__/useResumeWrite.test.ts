// Pins the debounce semantics of the resume-paragraph writer. The hook
// persists the live paragraph id so reopen can highlight + resume, but
// the actual `updateBookLastParagraph` call is debounced so a fast burst
// of paragraph changes coalesces into a single write. A regression here
// either floods the SQLite writer (no debounce) or loses the user's
// resume position on close (no flush).
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const updateBookLastParagraph = vi.fn(async () => undefined)
vi.mock('@/lib/api', () => ({
  updateBookLastParagraph: (...args: unknown[]) => updateBookLastParagraph(...args)
}))

import { usePlayerStore } from '@/stores/playerStore'
import { startResumeWriteSubscription } from '../useResumeWrite'

function setActive(idx: string): void {
  usePlayerStore.setState({
    activeParagraph: { index: idx, text: `text-${idx}` }
  })
}

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

describe('startResumeWriteSubscription', () => {
  it('coalesces a burst of paragraph changes into a single debounced write', () => {
    const sub = startResumeWriteSubscription({ bookId: 42 })

    setActive('p1')
    setActive('p2')
    setActive('p3')

    // Before the debounce fires, no DB write should have happened.
    expect(updateBookLastParagraph).not.toHaveBeenCalled()

    // After the debounce window (500ms), exactly one write with the LAST
    // paragraph from the burst is persisted.
    vi.advanceTimersByTime(600)

    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p3'
    })

    sub.dispose()
  })

  it('flush() persists the pending id immediately (no further timer fires)', () => {
    const sub = startResumeWriteSubscription({ bookId: 7 })

    setActive('p9')
    expect(updateBookLastParagraph).not.toHaveBeenCalled()

    sub.flush()
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 7,
      lastParagraph: 'p9'
    })

    // The timer must have been cancelled — advancing time should not
    // produce a duplicate write.
    vi.advanceTimersByTime(2000)
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)

    sub.dispose()
  })
})
