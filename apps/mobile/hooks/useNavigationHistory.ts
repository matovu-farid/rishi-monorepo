// apps/mobile/hooks/useNavigationHistory.ts
//
// Hooks that subscribe React components to the mobile navigation-history
// actor (T-P2.6 / NAVHIST-001). Mirrors
// `apps/rishi-electron/src/renderer/src/hooks/useNavigationHistory.ts` so the
// NavBackPill component has the same surface area as
// `NavigationHistoryFooter` on electron.

import { useSelector } from '@xstate/react'
import { navigationHistoryActor } from '@/lib/machines/navigationHistory'
import type { AnchorPoint } from '@/lib/machines/navigationHistory'

export function usePillVisible(): boolean {
  return useSelector(navigationHistoryActor, (s) => s.context.pillVisible)
}

export function useTopAnchor(): AnchorPoint | null {
  return useSelector(navigationHistoryActor, (s) => {
    const stack = s.context.stack
    return stack.length === 0 ? null : stack[stack.length - 1]
  })
}

export function useStackDepth(): number {
  return useSelector(navigationHistoryActor, (s) => s.context.stack.length)
}
