import { useEffect, useRef } from 'react'
import { usePlayerStore } from '@/stores/playerStore'

type PageHandler = () => void | Promise<void>

/**
 * Subscribe to `playerStore.pageRequest` and route 'next'/'prev' events to
 * the supplied callbacks. When `autoClear` is true, the store's
 * `clearPageRequest` is called after each dispatch so the request slot is
 * empty before the next event.
 *
 * NOTE: `onNext` and `onPrev` are accessed via refs (React Compiler safe).
 * The store subscription is established once and is NOT recreated when the
 * callback identities change — the underlying refs are updated in place so
 * the latest closure always runs.
 */
export function usePageRequestSubscription({
  onNext,
  onPrev,
  autoClear
}: {
  onNext: PageHandler
  onPrev: PageHandler
  autoClear: boolean
}): void {
  const onNextRef = useRef(onNext)
  const onPrevRef = useRef(onPrev)

  // Update the refs in place so the subscription closure always sees the
  // latest callbacks without re-subscribing.
  useEffect(() => {
    onNextRef.current = onNext
  }, [onNext])
  useEffect(() => {
    onPrevRef.current = onPrev
  }, [onPrev])

  useEffect(() => {
    const unsub = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      (request) => {
        if (request === 'next') void onNextRef.current()
        else if (request === 'prev') void onPrevRef.current()
        if (request && autoClear) {
          usePlayerStore.getState().clearPageRequest()
        }
      }
    )
    return unsub
  }, [autoClear])
}
