/**
 * Electron TTS glue. The TTS service implementation now lives in
 * `@rishi/shared/tts`; this barrel re-exports the public surface plus the
 * electron-specific helpers (`getVisualCueEmitter`, `resolveParagraphElement`)
 * that reach into renderer-only globals (`getActiveEpubFrame` registry).
 */
export { createTtsService } from '@rishi/shared/tts'
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
} from '@rishi/shared/tts'

import {
  createVisualCueEmitter,
  resolveParagraphElement as resolveParagraphElementInBody,
  type VisualCueEmitter
} from '@rishi/shared/tts'

let _visualCueEmitter: VisualCueEmitter | null = null

export function getVisualCueEmitter(): VisualCueEmitter {
  _visualCueEmitter ??= createVisualCueEmitter()
  return _visualCueEmitter
}

export type { VisualNearbyEvent } from '@rishi/shared/tts'

import { getActiveEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

/**
 * Best-effort mapping from paragraph index to its DOM element in the active
 * reader. Returns null when no reasonable element can be located (PDF mode,
 * iframe not yet rendered, paragraph out of range). Used by the TTS visual
 * cue — null disables the cue silently.
 *
 * Thin electron-side wrapper around `@rishi/shared/tts`'s pure
 * `resolveParagraphElement(body, index)` — supplies the body element from the
 * renderer-only EPUB-frame registry.
 */
export function resolveParagraphElement(paragraphIndexInPage: number): Element | null {
  const frame = getActiveEpubFrame()
  const body = frame?.contentDocument?.body
  return resolveParagraphElementInBody(body, paragraphIndexInPage)
}
