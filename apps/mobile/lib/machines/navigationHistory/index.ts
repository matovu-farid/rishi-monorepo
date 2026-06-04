// apps/mobile/lib/machines/navigationHistory/index.ts
//
// Mobile entry point for the shared navigationHistory machine
// (T-P2.6 / NAVHIST-001). Re-exports the parametric shared machine
// and owns the long-lived actor instance that the mobile readers
// + nav-history hooks subscribe to.
//
// The actor is module-scoped (same pattern as the electron renderer's
// `navigationHistoryActor.ts`) so every reader / hook subscribes to the
// same instance. `BOOK_OPENED` / `BOOK_CLOSED` events scope it per-book.

import { createActor } from 'xstate'
import { navigationHistoryMachine } from '@rishi/shared/machines/navigationHistory'
import type {
  AnchorPoint,
  NavigationHistoryEvent,
} from '@rishi/shared/machines/navigationHistory'

export {
  navigationHistoryMachine,
  pageKey,
  STACK_MAX_DEPTH,
  DWELL_MS,
} from '@rishi/shared/machines/navigationHistory'

export type {
  AnchorPoint,
  JumpSource,
  NavigationHistoryContext,
  NavigationHistoryEmitted,
  NavigationHistoryEvent,
  PositionDescriptor,
  TtsContext,
} from '@rishi/shared/machines/navigationHistory'

export const navigationHistoryActor = createActor(navigationHistoryMachine)
navigationHistoryActor.start()

export function sendNavigationHistory(event: NavigationHistoryEvent): void {
  navigationHistoryActor.send(event)
}

export function onResumeRequested(
  handler: (anchor: AnchorPoint) => void,
): () => void {
  const sub = navigationHistoryActor.on(
    'RESUME_REQUESTED',
    (event: { type: 'RESUME_REQUESTED'; anchor: AnchorPoint }) =>
      handler(event.anchor),
  )
  return () => sub.unsubscribe()
}
