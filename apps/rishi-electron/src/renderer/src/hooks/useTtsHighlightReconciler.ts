import { useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'

export type ReconcileTtsHighlight = (desiredIndex: string | null) => void

/**
 * Subscribe to playerStore.activeParagraph and to window/document focus
 * events; call the supplied reconciler on every trigger with the current
 * desired paragraph index. The reconciler is responsible for making the
 * DOM (or annotation store) converge to that state.
 *
 * When activeParagraph is null, the hook falls back to
 * lastPlayedParagraphIndex so the resume position is highlighted on
 * load before playback resumes.
 *
 * Idempotency of `reconcile` is required — this hook fires on multiple
 * trigger types that can overlap (focus + visibilitychange in sequence
 * on macOS Space return).
 *
 * The `iframe` argument is optional: pass the reader's content iframe
 * so the reconciler re-runs after chapter swaps. PDF does not use this
 * hook.
 *
 * Callers MUST pass a stable `reconcile` (wrap it in `useCallback`).
 * The hook's effect depends on `reconcile` identity; an unstable
 * function will tear down and re-bind all four listeners on every
 * render.
 */
export function useTtsHighlightReconciler(
  reconcile: ReconcileTtsHighlight,
  iframe: HTMLIFrameElement | null
): void {
  useEffect(() => {
    const run = (): void => {
      const state = usePlayerStore.getState()
      const desired = state.activeParagraph?.index ?? state.lastPlayedParagraphIndex ?? null
      reconcile(desired)
    }

    run()

    const unsubStore = usePlayerStore.subscribe(
      (s) => ({ active: s.activeParagraph, resume: s.lastPlayedParagraphIndex }),
      () => run(),
      { equalityFn: (a, b) => a.active === b.active && a.resume === b.resume }
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
