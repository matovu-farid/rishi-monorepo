import { useEffect, useRef } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

/**
 * Drives the BOOK_OPENED / BOOK_CLOSED lifecycle of the navigation-history
 * state machine for the EPUB reader.
 *
 * Why this exists (#226):
 *   `book.location` is initialised as `''` for freshly-imported books
 *   (see `main/ipc/formats.ts:129`). PR #222 swapped `||` → `??` on
 *   EpubView's `useState` initialiser, so on first open the EPUB reader
 *   mounts with `currentLocation === ''` until epubjs fires its first
 *   `locationChanged` and seeds a real CFI.
 *
 *   The old inline effect had deps `[book.id]` and early-returned when
 *   `!currentLocation`, so for fresh imports it never dispatched
 *   `BOOK_OPENED`. The navigation-history machine therefore stayed in
 *   `inactive` for the entire reader session — the back/forward pill
 *   was silently disabled until the user closed and reopened the book.
 *
 *   The fix re-fires `BOOK_OPENED` once a real CFI arrives. Naively
 *   adding `currentLocation` to the deps array would re-fire on every
 *   page turn, which re-runs `hydrateOnOpen`
 *   (navigationHistoryMachine.ts:27) and resets the stack to empty.
 *   We therefore split the lifecycle into two effects:
 *
 *     1. BOOK_OPENED runs whenever `bookId` or `currentLocation` change,
 *        guarded by a ref so it dispatches at most once per bookId —
 *        the first time we observe a non-empty CFI.
 *     2. BOOK_CLOSED runs only on unmount or genuine bookId change
 *        (deps `[bookId]`), and only if BOOK_OPENED actually fired for
 *        that bookId, so we don't emit spurious BOOK_CLOSED events for
 *        fresh imports that close before epubjs ever reports a CFI.
 */
export function useEpubNavHistoryLifecycle({
  bookId,
  currentLocation
}: {
  bookId: string
  currentLocation: string
}): void {
  // Tracks which bookId we have already announced via BOOK_OPENED so
  // mid-session CFI changes (page turns, TTS-driven relocateds) do not
  // re-fire BOOK_OPENED and clobber the navigation-history stack.
  const openedForBookIdRef = useRef<string | null>(null)

  // Effect 1: BOOK_OPENED. Re-runs on every CFI change so we can catch
  // the first non-empty CFI for freshly-imported books, but the ref
  // guard ensures we dispatch exactly once per bookId.
  useEffect(() => {
    if (!currentLocation) return
    if (openedForBookIdRef.current === bookId) return

    openedForBookIdRef.current = bookId
    navigationHistoryActor.send({
      type: 'BOOK_OPENED',
      bookId,
      initialPosition: { kind: 'epub', cfi: currentLocation }
    })
  }, [bookId, currentLocation])

  // Effect 2: BOOK_CLOSED on unmount or bookId change. Suppressed when
  // BOOK_OPENED was never dispatched for the closing bookId (fresh
  // import that closed before the first CFI arrived).
  useEffect(() => {
    return () => {
      if (openedForBookIdRef.current === bookId) {
        navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
        openedForBookIdRef.current = null
      }
    }
  }, [bookId])
}
