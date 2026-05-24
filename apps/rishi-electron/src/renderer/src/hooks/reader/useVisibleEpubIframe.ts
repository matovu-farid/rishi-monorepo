import { useCallback, useSyncExternalStore } from 'react'
import type { Rendition } from 'epubjs'
import { getVisibleIframe } from '@/modules/epubwrapper'

/**
 * Track the currently-visible epub.js content iframe declaratively.
 *
 * `useSyncExternalStore` is the React-19 way to expose a mutable third-party
 * subscription as a render value: it subscribes on mount, calls `getSnapshot`
 * during render, and re-renders when the subscription's `onChange` is invoked.
 *
 * The previous shape lived inside an `useEffect` and called
 * `setEpubContentIframe(...)` synchronously after the rendition mounted —
 * which the `react-hooks/set-state-in-effect` rule flags as a cascading
 * render. Lifting subscription + snapshot into this hook eliminates both the
 * effect and the setState call: the iframe is read on every render via
 * `getVisibleIframe`, and re-renders are triggered only by the actual epub.js
 * `rendered` event (the same event the effect was using to refresh state).
 *
 * When `rendition` is null the hook returns null without subscribing.
 */
export function useVisibleEpubIframe(rendition: Rendition | null): HTMLIFrameElement | null {
  // `subscribe` is keyed on the rendition identity. When the rendition swaps,
  // React will re-subscribe to the new instance. `useCallback` keeps the
  // identity stable across renders of the same rendition so we don't tear
  // down + re-add the listener on every parent render.
  const subscribe = useCallback(
    (onChange: () => void) => {
      if (!rendition) return () => {}
      rendition.on('rendered', onChange)
      return () => {
        rendition.off('rendered', onChange)
      }
    },
    [rendition]
  )

  // `getSnapshot` must be a referentially-stable function for a given
  // rendition AND must return a referentially-stable value while the
  // underlying iframe hasn't changed. `getVisibleIframe` already returns the
  // live DOM node, which has stable identity until epub.js mounts a new view
  // — so we can call it directly.
  const getSnapshot = useCallback((): HTMLIFrameElement | null => {
    if (!rendition) return null
    return getVisibleIframe(rendition) ?? null
  }, [rendition])

  return useSyncExternalStore(subscribe, getSnapshot, () => null)
}
