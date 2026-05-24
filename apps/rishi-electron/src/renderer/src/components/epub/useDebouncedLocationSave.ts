/**
 * useDebouncedLocationSave — coalesces rapid `relocated` events from epub.js
 * into a single IPC write to the books DB.
 *
 * Background (RDR-003): The EPUB reader's `relocated` event can fire several
 * times within ~100ms during a page-curl animation (rendition.next() resolves
 * → relocated → TTS paragraph advance can also trigger another relocated).
 * Each event used to call `updateBookLocationMutation.mutate` directly, which
 * fires a SQLite write per event — a write storm on rapid page-turn.
 *
 * Contract:
 *   - `save(cfi)` schedules a write 300ms after the most recent call.
 *   - Calling `save(cfi)` again before the window elapses resets the timer
 *     and replaces the pending value (true debounce semantics, not throttle).
 *   - `flush()` writes the latest pending value immediately and clears the
 *     timer — call this on unmount so the last-known position is preserved.
 *   - `cancel()` drops the pending value with no write — kept for parity with
 *     standard debounce APIs even though EpubView itself only ever flushes.
 *
 * The hook stores the latest `persist` function in a ref and reads it at
 * fire time. This is intentional: callers will usually pass an inline
 * `mutation.mutate` whose identity churns on every render, but the debounce
 * timer itself is created once at the first `save()` and must not be reset
 * by re-renders.
 */
import { useCallback, useEffect, useRef } from 'react'

/** Coalesce window. Issue RDR-003 acceptance: 10 rapid saves in <300ms → 1 write. */
export const DEBOUNCE_LOCATION_SAVE_MS = 300

export interface DebouncedLocationSave {
  /** Schedule a write of `cfi` 300ms after the last call. */
  save: (cfi: string) => void
  /** Write the latest pending value immediately and clear the timer. No-op if nothing pending. */
  flush: () => void
  /** Discard the pending value without writing. */
  cancel: () => void
}

export function useDebouncedLocationSave(persist: (cfi: string) => void): DebouncedLocationSave {
  // Latest persist fn — read at fire time so a re-rendered caller passing a
  // fresh `mutate` doesn't strand the pending write on a stale closure.
  const persistRef = useRef(persist)
  useEffect(() => {
    persistRef.current = persist
  }, [persist])

  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pendingValueRef = useRef<string | null>(null)
  const hasPendingRef = useRef(false)

  const clearTimer = useCallback((): void => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
  }, [])

  const save = useCallback(
    (cfi: string): void => {
      pendingValueRef.current = cfi
      hasPendingRef.current = true
      clearTimer()
      timerRef.current = setTimeout(() => {
        timerRef.current = null
        if (!hasPendingRef.current) return
        const value = pendingValueRef.current
        hasPendingRef.current = false
        pendingValueRef.current = null
        if (value !== null) persistRef.current(value)
      }, DEBOUNCE_LOCATION_SAVE_MS)
    },
    [clearTimer]
  )

  const flush = useCallback((): void => {
    clearTimer()
    if (!hasPendingRef.current) return
    const value = pendingValueRef.current
    hasPendingRef.current = false
    pendingValueRef.current = null
    if (value !== null) persistRef.current(value)
  }, [clearTimer])

  const cancel = useCallback((): void => {
    clearTimer()
    hasPendingRef.current = false
    pendingValueRef.current = null
  }, [clearTimer])

  // Flush on unmount so we never lose the user's last position when the
  // component tears down (book close, window close, route change).
  useEffect(() => {
    return () => {
      // Use refs directly instead of `flush()` — at unmount-time React has
      // already started teardown, so any setState-style work inside the
      // persist fn is fine (mutation.mutate is fire-and-forget) but we
      // shouldn't depend on the memoized `flush` identity for cleanup.
      if (timerRef.current !== null) {
        clearTimeout(timerRef.current)
        timerRef.current = null
      }
      if (hasPendingRef.current) {
        const value = pendingValueRef.current
        hasPendingRef.current = false
        pendingValueRef.current = null
        if (value !== null) persistRef.current(value)
      }
    }
  }, [])

  return { save, flush, cancel }
}
