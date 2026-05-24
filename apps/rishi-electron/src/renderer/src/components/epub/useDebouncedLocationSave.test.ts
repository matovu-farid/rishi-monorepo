/**
 * Unit tests for useDebouncedLocationSave — the EPUB reader's per-page-turn
 * IPC-write coalescer. The reader's `relocated` event can fire several times
 * within ~100ms during a page-curl animation + rendition.next() resolve + TTS
 * paragraph advance; without debounce, each event triggers a SQLite write.
 *
 * Contract (RDR-003):
 *   - Rapid calls within the 300ms window → exactly 1 IPC write (trailing).
 *   - Each `save()` resets the timer.
 *   - `flush()` writes the latest pending value immediately and clears the
 *     timer (used on unmount so the last position isn't lost).
 *   - `cancel()` drops the pending value with no write.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useDebouncedLocationSave, DEBOUNCE_LOCATION_SAVE_MS } from './useDebouncedLocationSave'

describe('useDebouncedLocationSave', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.runOnlyPendingTimers()
    vi.useRealTimers()
  })

  it('exposes a 300ms coalesce window', () => {
    expect(DEBOUNCE_LOCATION_SAVE_MS).toBe(300)
  })

  it('coalesces 10 rapid saves within the debounce window into 1 IPC write', () => {
    const persist = vi.fn()
    const { result } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      for (let i = 0; i < 10; i++) {
        result.current.save(`cfi-${i}`)
      }
    })

    // Within the window: nothing fired yet.
    expect(persist).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(DEBOUNCE_LOCATION_SAVE_MS)
    })

    // After the trailing edge: exactly one call, with the LAST value.
    expect(persist).toHaveBeenCalledTimes(1)
    expect(persist).toHaveBeenLastCalledWith('cfi-9')
  })

  it('each save() resets the timer (true debounce, not throttle)', () => {
    const persist = vi.fn()
    const { result } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      result.current.save('a')
    })
    act(() => {
      vi.advanceTimersByTime(200)
    })
    act(() => {
      result.current.save('b') // resets — timer starts over from here
    })
    act(() => {
      vi.advanceTimersByTime(200)
    })
    expect(persist).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(100) // 300ms after 'b' — should fire now
    })
    expect(persist).toHaveBeenCalledTimes(1)
    expect(persist).toHaveBeenLastCalledWith('b')
  })

  it('flush() writes the latest pending value immediately', () => {
    const persist = vi.fn()
    const { result } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      result.current.save('pending-cfi')
      result.current.flush()
    })

    expect(persist).toHaveBeenCalledTimes(1)
    expect(persist).toHaveBeenCalledWith('pending-cfi')

    // After flush, the original timer should not also fire.
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(persist).toHaveBeenCalledTimes(1)
  })

  it('flush() with no pending value is a no-op', () => {
    const persist = vi.fn()
    const { result } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      result.current.flush()
    })

    expect(persist).not.toHaveBeenCalled()
  })

  it('cancel() drops the pending value with no IPC write', () => {
    const persist = vi.fn()
    const { result } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      result.current.save('drop-me')
      result.current.cancel()
      vi.advanceTimersByTime(1000)
    })

    expect(persist).not.toHaveBeenCalled()
  })

  it('flushes the latest pending value on unmount (so the last position is preserved)', () => {
    const persist = vi.fn()
    const { result, unmount } = renderHook(() => useDebouncedLocationSave(persist))

    act(() => {
      result.current.save('last-known-cfi')
    })
    expect(persist).not.toHaveBeenCalled()

    unmount()

    expect(persist).toHaveBeenCalledTimes(1)
    expect(persist).toHaveBeenCalledWith('last-known-cfi')
  })

  it('reads the latest persist fn on every fire (so closure-staleness does not strand the IPC)', () => {
    const persistA = vi.fn()
    const persistB = vi.fn()
    const { result, rerender } = renderHook(({ fn }) => useDebouncedLocationSave(fn), {
      initialProps: { fn: persistA }
    })

    act(() => {
      result.current.save('x')
    })
    // Re-render with a new fn before the timer trips.
    rerender({ fn: persistB })

    act(() => {
      vi.advanceTimersByTime(DEBOUNCE_LOCATION_SAVE_MS)
    })

    expect(persistA).not.toHaveBeenCalled()
    expect(persistB).toHaveBeenCalledTimes(1)
    expect(persistB).toHaveBeenCalledWith('x')
  })
})
