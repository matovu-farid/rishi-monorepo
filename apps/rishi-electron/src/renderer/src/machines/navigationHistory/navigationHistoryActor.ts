import { createActor } from 'xstate'
import { create } from 'zustand'
import { navigationHistoryMachine } from '@rishi/shared/machines/navigationHistory'
import type { AnchorPoint, NavigationHistoryEvent } from './types'

export const navigationHistoryActor = createActor(navigationHistoryMachine)
navigationHistoryActor.start()

type SendStore = {
  send: (event: NavigationHistoryEvent) => void
}

export const useNavigationHistorySend = create<SendStore>(() => ({
  send: (event) => navigationHistoryActor.send(event)
}))

export function onResumeRequested(handler: (anchor: AnchorPoint) => void): () => void {
  const sub = navigationHistoryActor.on(
    'RESUME_REQUESTED',
    (event: { type: 'RESUME_REQUESTED'; anchor: AnchorPoint }) => handler(event.anchor)
  )
  return () => sub.unsubscribe()
}
