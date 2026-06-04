/**
 * Electron-side type re-exports for the navigationHistory machine. The
 * canonical definitions now live in `@rishi/shared/machines/navigationHistory`.
 * Keeping this barrel preserves existing `@/machines/navigationHistory/types`
 * import paths across electron consumers (pdf, mobi, azw3, epub viewers).
 *
 * Note: `resumeMap` on the shared `NavigationHistoryContext` is a
 * `Record<string, AnchorPoint>` (not `Map`) per REVIEW-01 MINOR-05 — XState
 * snapshots stay JSON-serializable. Electron consumers that previously read
 * `resumeMap.get(k)` should adapt to `resumeMap[k]`.
 */
export type {
  AnchorPoint,
  JumpSource,
  NavigationHistoryContext,
  NavigationHistoryEmitted,
  NavigationHistoryEvent,
  PositionDescriptor,
  TtsContext
} from '@rishi/shared/machines/navigationHistory'

export {
  DWELL_MS,
  STACK_MAX_DEPTH
} from '@rishi/shared/machines/navigationHistory'
