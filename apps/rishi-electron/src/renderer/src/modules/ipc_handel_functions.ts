/**
 * TTS service wrapper functions for Electron.
 * Replaces Tauri's convertFileSrc with blob URL handling since
 * Electron TTS returns blob URLs directly from the renderer-side queue.
 */
import { ttsService } from './ttsService'
import { captureError } from '../utils/sentry'

export const requestTTSAudio = async (
  bookId: string,
  cfiRange: string,
  text: string,
  priority = 0
) => {
  try {
    // In Electron, ttsService.requestAudio already returns a blob URL
    const audioUrl = await ttsService.requestAudio(bookId, cfiRange, text, priority)
    return audioUrl
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
