import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'

export type ReconcileTtsHighlight = (desiredIndex: string | null) => void

/**
 * Subscribe to playerStore.activeParagraph and to window/document focus
 * events; call the supplied reconciler on every trigger with the current
 * desired paragraph index. The reconciler is responsible for making the
 * DOM (or annotation store) converge to that state.
 *
 * Idempotency of `reconcile` is required — this hook fires on multiple
 * trigger types that can overlap (focus + visibilitychange in sequence
 * on macOS Space return).
 *
 * The `iframe` argument is optional: pass the reader's content iframe
 * so the reconciler re-runs after chapter swaps. PDF does not use this
 * hook.
 */
export function useTtsHighlightReconciler(
  reconcile: ReconcileTtsHighlight,
  iframe: HTMLIFrameElement | null,
): void {
  useEffect(() => {
    const run = (): void => {
      reconcile(usePlayerStore.getState().activeParagraph?.index ?? null)
    }

    run()

    const unsubStore = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      () => run(),
    )

    const onVisibility = (): void => {
      if (document.visibilityState === 'visible') run()
    }
    const onFocus = (): void => run()
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('focus', onFocus)

    const onIframeLoad = (): void => run()
    iframe?.addEventListener('load', onIframeLoad)

    return () => {
      unsubStore()
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('focus', onFocus)
      iframe?.removeEventListener('load', onIframeLoad)
    }
  }, [reconcile, iframe])
}
