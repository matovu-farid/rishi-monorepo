import { useEffect, type RefObject } from 'react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export type UseEngagementDetectorOptions = {
  targetRef: RefObject<HTMLElement | null>
  enabled: boolean
}

export function useEngagementDetector({ targetRef, enabled }: UseEngagementDetectorOptions): void {
  useEffect(() => {
    if (!enabled) return
    const node = targetRef.current
    if (!node) return

    const onPointerDown = (e: PointerEvent): void => {
      // Skip pointerdowns originating inside the navigation-history pill —
      // see `components/navigation-history/NavigationHistoryFooter.tsx` for
      // the full rationale. Short version: ENGAGEMENT_TAP synchronously
      // hides the pill (entry: hidePill in the engaged state), which
      // unmounts the button before its click fires, dropping POP_BACK /
      // DISMISS_PILL on the floor. A React onPointerDown stopPropagation
      // does NOT fix this because React's synthetic delegation reaches the
      // pill AFTER this native listener has already run.
      const target = e.target as Element | null
      if (target?.closest('[data-nav-history-pill="true"]')) return
      navigationHistoryActor.send({ type: 'ENGAGEMENT_TAP' })
    }

    const onSelectionChange = (): void => {
      const sel = window.getSelection()
      if (!sel || sel.isCollapsed) return
      navigationHistoryActor.send({ type: 'ENGAGEMENT_TAP' })
    }

    const onVisibility = (): void => {
      navigationHistoryActor.send({
        type: document.visibilityState === 'hidden' ? 'VISIBILITY_HIDDEN' : 'VISIBILITY_VISIBLE'
      })
    }

    const onBlur = (): void => navigationHistoryActor.send({ type: 'VISIBILITY_HIDDEN' })
    const onFocus = (): void => navigationHistoryActor.send({ type: 'VISIBILITY_VISIBLE' })

    node.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('selectionchange', onSelectionChange)
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    window.addEventListener('focus', onFocus)

    return () => {
      node.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('selectionchange', onSelectionChange)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
      window.removeEventListener('focus', onFocus)
    }
  }, [targetRef, enabled])
}
