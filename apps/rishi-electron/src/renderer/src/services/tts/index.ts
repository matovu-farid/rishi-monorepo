export { createTtsService } from './service'
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

import { createVisualCueEmitter, type VisualCueEmitter } from './visual-cue-emitter'

let _visualCueEmitter: VisualCueEmitter | null = null

export function getVisualCueEmitter(): VisualCueEmitter {
  _visualCueEmitter ??= createVisualCueEmitter()
  return _visualCueEmitter
}

export type { VisualNearbyEvent } from './visual-cue-emitter'

import { getActiveEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

/**
 * Best-effort mapping from paragraph index to its DOM element in the active
 * reader. Returns null when no reasonable element can be located (PDF mode,
 * iframe not yet rendered, paragraph out of range). Used by the TTS visual
 * cue — null disables the cue silently.
 */
export function resolveParagraphElement(paragraphIndexInPage: number): Element | null {
  const frame = getActiveEpubFrame()
  const body = frame?.contentDocument?.body
  if (!body) return null
  // Match common block-level elements that typically map to paragraphs in
  // EPUB content. Order-preserving querySelectorAll guarantees positional
  // correspondence with paragraphs published by the EPUB reader.
  const candidates = body.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li')
  return candidates[paragraphIndexInPage] ?? null
}
