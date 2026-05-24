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
