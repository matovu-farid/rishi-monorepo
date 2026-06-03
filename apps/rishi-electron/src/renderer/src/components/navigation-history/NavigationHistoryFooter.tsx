import type { JSX } from 'react'
import { usePillVisible, useTopAnchor, useStackDepth } from '@/hooks/useNavigationHistory'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'

export function NavigationHistoryFooter(): JSX.Element | null {
  const visible = usePillVisible()
  const anchor = useTopAnchor()
  const depth = useStackDepth()

  if (!visible || !anchor) return null

  const text = depth > 1 ? `← Back to ${anchor.label} (${depth})` : `← Back to ${anchor.label}`

  return (
    <div
      role="status"
      aria-live="polite"
      // Mark the pill so `useEngagementDetector` can skip pointerdowns that
      // originate inside it. Without this, the pointerdown that initiates a
      // click on the back-label button bubbles to the reader root, the
      // engagement detector treats it as ENGAGEMENT_TAP, the engagement
      // region transitions to `engaged`, whose `entry` action `hidePill`
      // unmounts this footer synchronously. The pill DOM goes away BEFORE
      // the synthesized click event fires, so the button's `onClick` never
      // runs and POP_BACK / DISMISS_PILL are dropped — the user appears to
      // click the pill and nothing happens (the visible e2e symptom:
      // restoredPage stayed at the jump-target page because POP_BACK was
      // never delivered). A React onPointerDown stopPropagation does NOT
      // fix this: React 17+ delegates synthetic events at the React root,
      // which is reached AFTER the native engagement listener on the reader
      // root has already fired.
      data-nav-history-pill="true"
      className="pointer-events-auto fixed bottom-16 left-1/2 z-50 -translate-x-1/2
                 flex items-center gap-2 rounded-full border border-white/10
                 bg-zinc-900/95 px-4 py-2 text-sm text-white shadow-lg backdrop-blur"
    >
      <button
        type="button"
        data-testid="nav-history-back-label"
        onClick={() => navigationHistoryActor.send({ type: 'POP_BACK' })}
        className="min-h-[44px] px-2"
      >
        {text}
      </button>
      <button
        type="button"
        data-testid="nav-history-dismiss"
        aria-label="Dismiss back navigation"
        onClick={() => navigationHistoryActor.send({ type: 'DISMISS_PILL' })}
        className="min-h-[44px] px-2 opacity-60 hover:opacity-100"
      >
        ✕
      </button>
    </div>
  )
}
