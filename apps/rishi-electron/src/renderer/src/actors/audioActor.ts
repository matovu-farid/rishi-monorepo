// apps/electron/src/renderer/src/actors/audioActor.ts
//
// Long-running side-effect actor that owns a singleton HTMLMediaElement and
// the surrounding load/play/pause/stop lifecycle. Built as an xstate v5
// `fromCallback` so the parent (`playerMachine`) can `sendTo` the actor
// instead of poking the audio element through a zustand-mediated bridge.
//
// What it owns:
//   - The HTMLMediaElement reference (default: the module-level singleton).
//   - Forwarding native 'ended' / 'error' events to the parent.
//   - Sequencing PLAY commands so a newer PLAY supersedes any in-flight
//     canplaythrough listener from an older PLAY (no more `fetchGeneration`).
//
// What it explicitly does NOT own:
//   - TTS fetching — that's a `fromPromise` invoked alongside this actor.
//   - Decisions about WHEN to play — those live in the parent machine's
//     state graph (loading → invoke → onDone → sendTo(audio, PLAY)).
//
// Tests inject a fake media element via `input.audio` so they don't depend
// on happy-dom's incomplete HTMLAudioElement.
import { fromCallback } from 'xstate'
import { debugLog } from '@/utils/debugLog'

// Singleton HTMLAudioElement used for TTS playback in production.
// Exported so the E2E expose-stores layer can attach it to `window` for
// browser-side observation. Inside the actor, prefer the `input.audio`
// path so tests can inject a fake without touching this singleton.
export const audioElement: HTMLAudioElement =
  typeof Audio !== 'undefined' ? new Audio() : ({} as HTMLAudioElement)

export type AudioCommand =
  | { type: 'PLAY'; src: string }
  | { type: 'PAUSE' }
  | { type: 'RESUME' }
  | { type: 'STOP' }
  | { type: 'CLEAR_SRC' }

export type AudioEmit =
  | { type: 'AUDIO_LOADED' }
  | { type: 'AUDIO_ENDED' }
  | { type: 'AUDIO_ERROR'; error: string }

type AudioInput = { audio?: HTMLMediaElement }

const MEDIA_ERROR_LABELS: Record<number, string> = {
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED'
}

function describeMediaError(audio: HTMLMediaElement): string {
  const err = audio.error
  const message = err?.message
  if (message && message.length > 0) return message
  if (err?.code !== undefined)
    return MEDIA_ERROR_LABELS[err.code] ?? `Audio error (code ${err.code})`
  return 'Audio playback error'
}

export const audioActor = fromCallback<AudioCommand, AudioInput>(({ sendBack, receive, input }) => {
  const audio = input.audio ?? audioElement

  // The pending canplaythrough handler for the most-recent PLAY. A new PLAY
  // removes the previous one before installing its own, so a single error
  // or canplaythrough event can never fire two handlers (which would emit
  // two AUDIO_LOADED / AUDIO_ERROR events to the parent).
  let pendingCanPlay: (() => void) | null = null

  const handleEnded = (): void => {
    debugLog('audio:ended', { src: audio.src.slice(-40) })
    sendBack({ type: 'AUDIO_ENDED' })
  }
  const handleError = (): void => {
    // Drop any in-flight canplaythrough — the load has failed, no LOADED
    // will follow. Without this, a delayed canplaythrough would still fire
    // play() on a broken stream.
    if (pendingCanPlay) {
      audio.removeEventListener('canplaythrough', pendingCanPlay)
      pendingCanPlay = null
    }
    const error = describeMediaError(audio)
    debugLog('audio:error', { error, src: audio.src.slice(-40) })
    sendBack({ type: 'AUDIO_ERROR', error })
  }
  audio.addEventListener('ended', handleEnded)
  audio.addEventListener('error', handleError)

  receive((event) => {
    const cmd = event
    debugLog('audio:command', { cmd: cmd.type, paused: audio.paused })
    if (cmd.type === 'PLAY') {
      if (pendingCanPlay) {
        audio.removeEventListener('canplaythrough', pendingCanPlay)
      }
      audio.pause()
      audio.currentTime = 0
      audio.src = cmd.src
      audio.load()

      const handleCanPlay = (): void => {
        audio.removeEventListener('canplaythrough', handleCanPlay)
        // Defensive: if a newer PLAY swapped the pending handler before this
        // ran, the listener was already removed and we shouldn't emit.
        if (pendingCanPlay !== handleCanPlay) return
        pendingCanPlay = null
        audio.play().then(
          () => sendBack({ type: 'AUDIO_LOADED' }),
          (err: unknown) => {
            const msg = err instanceof Error ? err.message : String(err)
            sendBack({ type: 'AUDIO_ERROR', error: msg })
          }
        )
      }
      pendingCanPlay = handleCanPlay
      audio.addEventListener('canplaythrough', handleCanPlay)
    } else if (cmd.type === 'PAUSE') {
      audio.pause()
    } else if (cmd.type === 'RESUME') {
      void audio.play()
    } else if (cmd.type === 'STOP') {
      audio.pause()
      audio.currentTime = 0
    } else {
      // CLEAR_SRC (only remaining variant in AudioCommand).
      audio.pause()
      audio.src = ''
    }
  })

  return () => {
    audio.removeEventListener('ended', handleEnded)
    audio.removeEventListener('error', handleError)
    if (pendingCanPlay) {
      audio.removeEventListener('canplaythrough', pendingCanPlay)
      pendingCanPlay = null
    }
    audio.pause()
    audio.src = ''
  }
})
