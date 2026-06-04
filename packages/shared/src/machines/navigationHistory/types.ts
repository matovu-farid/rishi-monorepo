// packages/shared/src/machines/navigationHistory/types.ts
//
// Shared port of electron's navigationHistory types. The only difference vs
// `apps/rishi-electron/src/renderer/src/machines/navigationHistory/types.ts`
// is that `resumeMap` is a plain `Record<string, AnchorPoint>` instead of a
// `Map` (REVIEW-01 MINOR-05 — JSON-serializable for XState devtools).

export type PositionDescriptor =
  | { kind: 'pdf'; page: number; offset: number }
  | { kind: 'epub'; cfi: string }
  | { kind: 'azw3'; cfi: string }
  | { kind: 'mobi'; cfi: string }

export type TtsContext = {
  paragraphIndex: number
} | null

export type JumpSource = 'link' | 'toc' | 'bookmark' | 'search' | 'engagement'

export type AnchorPoint = {
  id: string
  bookId: string
  position: PositionDescriptor
  tts: TtsContext
  label: string
  capturedAt: number
  source: JumpSource
}

export type NavigationHistoryContext = {
  bookId: string | null
  stack: AnchorPoint[]
  resumeMap: Record<string, AnchorPoint>
  currentPage: PositionDescriptor | null
  currentTts: TtsContext
  pillVisible: boolean
}

export type NavigationHistoryEvent =
  | { type: 'BOOK_OPENED'; bookId: string; initialPosition: PositionDescriptor }
  | { type: 'BOOK_CLOSED' }
  | { type: 'PAGE_VISITED'; position: PositionDescriptor; ttsContext: TtsContext }
  | {
      type: 'JUMP_REQUESTED'
      from: PositionDescriptor
      fromTts: TtsContext
      to: PositionDescriptor
      source: JumpSource
      fromLabel: string
    }
  | { type: 'POP_BACK' }
  | { type: 'DISMISS_PILL' }
  | { type: 'ENGAGEMENT_TAP' }
  | { type: 'ENGAGEMENT_TTS_PLAYING' }
  | { type: 'DWELL_ELAPSED' }
  | { type: 'VISIBILITY_HIDDEN' }
  | { type: 'VISIBILITY_VISIBLE' }

export type NavigationHistoryEmitted = { type: 'RESUME_REQUESTED'; anchor: AnchorPoint }

export const STACK_MAX_DEPTH = 10
export const DWELL_MS = 20_000
