/**
 * Voice-chat sound effects: ready chime + thinking-tick loop. Wraps
 * `react-native-audio-api` if it ever lands; for SDK 54 (Worklets 0.5.x)
 * we degrade silently and rely on `expo-audio` for the chime alone.
 *
 * Electron's `readyChime` and `thinkingSound` both synthesise tones via
 * the Web Audio API. React Native has no `AudioContext` constructor in
 * Hermes, so we substitute a minimal expo-audio-based fallback for the
 * chime and a no-op for the looping thinking tick (the on-screen status
 * label conveys the same information).
 *
 * Behavior parity:
 *   - playReadyChime(): plays a short positive cue once. Best-effort —
 *     if expo-audio fails the call is swallowed.
 *   - startThinkingSound() / stopThinkingSound(): no-op on mobile.
 *     Documented in BATCH-4-NOTES.md.
 *
 * If a future batch wants the looping tick, options:
 *   1. Ship a small <600ms `tick.mp3` asset and loop via expo-audio.
 *   2. Upgrade `react-native-worklets` to ≥0.6 and use
 *      `react-native-audio-api`'s OscillatorNode, mirroring electron.
 *   3. Use the native iOS/Android haptic engine for a soft pulse.
 *
 * The chime uses a 700ms tone synthesised at import time so we don't
 * ship an asset for it. We render a small WAV in memory and write it to
 * the document cache the first time playReadyChime() runs.
 */
import { createAudioPlayer } from 'expo-audio'
import { File, Paths } from 'expo-file-system'
import type { EffectsPort } from '@rishi/shared/voice-chat'

let chimeFileUri: string | null = null
let chimeWriteInFlight: Promise<string> | null = null

/**
 * Synthesise a short two-tone "ding" as a 16-bit PCM WAV. Matches
 * electron's "C5 → E5" two-tone pattern (523 Hz then 659 Hz, 150ms
 * each), but emitted at half-volume to be comfortable on phone
 * speakers.
 */
function synthesizeChimeWav(): Uint8Array {
  const sampleRate = 22050
  const totalMs = 300
  const transitionMs = 150
  const numSamples = Math.floor((sampleRate * totalMs) / 1000)
  const data = new Int16Array(numSamples)

  const freqA = 523 // C5
  const freqB = 659 // E5
  const amp = 0.3 * 32767

  for (let i = 0; i < numSamples; i++) {
    const tMs = (i / sampleRate) * 1000
    const freq = tMs < transitionMs ? freqA : freqB
    const envelope = 1 - tMs / totalMs // linear decay
    const sample = Math.sin((2 * Math.PI * freq * i) / sampleRate) * envelope * amp
    data[i] = Math.max(-32768, Math.min(32767, Math.round(sample)))
  }

  // Build a 44-byte WAV header + PCM body.
  const header = new Uint8Array(44)
  const view = new DataView(header.buffer)
  const byteRate = sampleRate * 2 // 16-bit mono
  const dataBytes = data.byteLength
  // RIFF chunk
  view.setUint8(0, 0x52)
  view.setUint8(1, 0x49)
  view.setUint8(2, 0x46)
  view.setUint8(3, 0x46)
  view.setUint32(4, 36 + dataBytes, true)
  view.setUint8(8, 0x57)
  view.setUint8(9, 0x41)
  view.setUint8(10, 0x56)
  view.setUint8(11, 0x45)
  // fmt subchunk
  view.setUint8(12, 0x66)
  view.setUint8(13, 0x6d)
  view.setUint8(14, 0x74)
  view.setUint8(15, 0x20)
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true) // PCM
  view.setUint16(22, 1, true) // mono
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, byteRate, true)
  view.setUint16(32, 2, true) // block align
  view.setUint16(34, 16, true) // bits per sample
  // data subchunk
  view.setUint8(36, 0x64)
  view.setUint8(37, 0x61)
  view.setUint8(38, 0x74)
  view.setUint8(39, 0x61)
  view.setUint32(40, dataBytes, true)

  const out = new Uint8Array(header.byteLength + dataBytes)
  out.set(header, 0)
  out.set(new Uint8Array(data.buffer), header.byteLength)
  return out
}

async function getChimeUri(): Promise<string> {
  if (chimeFileUri) return chimeFileUri
  if (chimeWriteInFlight) return chimeWriteInFlight

  chimeWriteInFlight = (async () => {
    const dir = Paths.cache
    const file = new File(dir, 'voice-chat-ready-chime.wav')
    if (!file.exists) {
      const wav = synthesizeChimeWav()
      // expo-file-system File.write accepts Uint8Array; write the raw bytes.
      file.write(wav)
    }
    const uri = file.uri
    chimeFileUri = uri
    return uri
  })()

  try {
    return await chimeWriteInFlight
  } finally {
    chimeWriteInFlight = null
  }
}

/**
 * Build the mobile EffectsPort. Best-effort — never throws upward.
 */
export function createMobileEffectsPort(): EffectsPort {
  return {
    playReadyChime() {
      // Fire-and-forget.
      void (async () => {
        try {
          const uri = await getChimeUri()
          const player = createAudioPlayer({ uri })
          player.volume = 1.0
          player.play()
          // Release after the chime finishes. 350ms covers the 300ms tone
          // plus a small safety margin.
          setTimeout(() => {
            try {
              player.remove()
            } catch {
              /* best-effort */
            }
          }, 500)
        } catch {
          /* best-effort */
        }
      })()
    },
    startThinkingSound() {
      // No-op: see file-level docs. The on-screen 'thinking' chat status
      // label conveys the same information without needing an audio loop.
    },
    stopThinkingSound() {
      // No-op for symmetry.
    }
  }
}
