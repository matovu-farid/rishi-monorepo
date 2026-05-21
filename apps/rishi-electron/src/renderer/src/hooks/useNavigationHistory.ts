import { useSelector } from '@xstate/react'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import type { AnchorPoint } from '@/machines/navigationHistory/types'

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
