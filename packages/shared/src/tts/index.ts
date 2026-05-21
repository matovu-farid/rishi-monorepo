/**
 * Shared TTS public surface. Mirrors
 * `apps/rishi-electron/src/renderer/src/services/tts/index.ts` except
 * `getActiveEpubFrame` is not re-exported (that registry is a
 * renderer-specific concern; consumers pass the body element directly).
 */
export { createTtsService } from './service'
export { createCache } from './cache'
export { makeProgram } from './program'
export { createEmitter } from './emitter'
export {
  AuthFailedError,
  TransportError,
  ParseError,
  CancelledError,
  QueueOverflowError,
  toPublicError
} from './errors'
export type { TtsTaggedError } from './errors'
export type {
  AudioRequest,
  AudioReadyEvent,
  AudioErrorEvent,
  AuthHeader,
  QueueStatus,
  TtsConfig,
  TtsIpcChannels,
  TtsService,
  TtsServiceDeps
} from './types'

export { createVisualCueEmitter } from './visual-cue-emitter'
export type { VisualCueEmitter, VisualNearbyEvent } from './visual-cue-emitter'
export type { VisualHit, VisualKind, VisualSummary } from './visual-heuristic'
export { detectVisualsNear, summarizeVisuals } from './visual-heuristic'

export { resolveParagraphElement } from './resolve-paragraph'
