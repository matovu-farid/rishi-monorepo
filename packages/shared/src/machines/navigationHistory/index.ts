// packages/shared/src/machines/navigationHistory/index.ts
//
// Public barrel for the shared navigationHistory machine.

export { navigationHistoryMachine } from './navigationHistoryMachine'
export { pageKey } from './pageKey'
export type {
  AnchorPoint,
  JumpSource,
  NavigationHistoryContext,
  NavigationHistoryEmitted,
  NavigationHistoryEvent,
  PositionDescriptor,
  TtsContext
} from './types'
export { DWELL_MS, STACK_MAX_DEPTH } from './types'
