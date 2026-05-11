/**
 * Thin Sentry-instrumented delegate around the TTS service's `requestAudio`.
 * Kept as a named export so library-level callers (e.g. `ttsPrefetch`) can
 * benefit from the structured error capture without re-implementing it.
 */
import { getTtsService } from '@/services'
import { captureError } from '../utils/sentry'

export const requestTTSAudio = async (
  bookId: string,
  cfiRange: string,
  text: string,
  priority = 0
) => {
  try {
    return await getTtsService().requestAudio({ bookId, cfiRange, text, priority })
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error)
    console.error(`TTS request failed [${bookId}]: ${msg}`)
    captureError(error, {
      operation: 'tts-request',
      step: 'requestTTSAudio',
      bookId,
      cfiRange,
      textLength: text.length,
      priority
    })
    throw error
  }
}
