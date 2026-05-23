/**
 * Voice-chat sound effects: ready chime + thinking-tick loop. Wraps
 * `react-native-audio-api` if it ever lands; for SDK 54 (Worklets 0.5.x)
 * we degrade silently and rely on `expo-audio` for the chime alone.
 *
 * Electron's `readyChime` and `thinkingSound` both synthesise tones via
 * the Web Audio API. React Native has no `AudioContext` constructor in
 * Hermes, so we substitute a minimal expo-audio-based fallback for the
 * chime and (per P1-AJ) a periodic haptic for the thinking-tick loop.
 *
 * Behavior parity:
 *   - playReadyChime(): plays a short positive cue once. Best-effort —
 *     if expo-audio fails the call is swallowed.
 *   - startThinkingSound() / stopThinkingSound(): drives a recurring
 *     `Haptics.selectionAsync` pulse at THINKING_TICK_MS cadence so the
 *     user gets a subtle tactile cue while the model is preparing a
 *     reply. Idempotent — start can be called repeatedly without
 *     stacking timers.
 *
 * The chime uses a 700ms tone synthesised at import time so we don't
 * ship an asset for it. We render a small WAV in memory and write it to
 * the document cache the first time playReadyChime() runs.
 */
import { createAudioPlayer } from 'expo-audio'
import { File, Paths } from 'expo-file-system'
import type { EffectsPort } from '@rishi/shared/voice-chat'

/**
 * Cadence between thinking-tick haptics. Tuned conservatively (1.5s) so
 * the pulse reads as ambient feedback rather than an attention-grabbing
 * notification. Matches the rough "thinking spinner heartbeat" rate
 * used by electron's oscillator tick.
 */
const THINKING_TICK_MS = 1500

/**
 * Lazy expo-haptics accessor. Resolved via `require` inside the tick
 * callback rather than a top-level ESM `import` so untransformed
 * voice-chat tests that don't exercise the thinking loop (they never
 * resolve this require) keep working without each having to mock
 * `expo-haptics` themselves. Tests that DO exercise the loop mock
 * `expo-haptics` directly via `jest.mock`.
 */
function tickHaptic(): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const Haptics = require('expo-haptics') as {
      selectionAsync: () => Promise<unknown>
    }
    void Haptics.selectionAsync().catch(() => undefined)
  } catch {
    /* best-effort — missing module or platform failure is non-fatal */
  }
}

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
 * Module-level singleton effects port. Both the shared voice-chat service
 * (which fires startThinkingSound on `agent_tool_start`) AND the
 * `useVoiceChat` hook (which fires it on the broader `chatStatus === 'thinking'`
 * transition — CHT-007) need to drive the same interval handle. If each
 * caller built its own port they'd stack timers and double-haptic the user.
 */
let _singletonPort: EffectsPort | null = null

/**
 * Returns the process-wide mobile EffectsPort. Constructed lazily on the
 * first call. Subsequent calls return the SAME instance so service + hook
 * share the start/stop interval handle.
 */
export function getMobileEffectsPort(): EffectsPort {
  if (!_singletonPort) {
    _singletonPort = createMobileEffectsPort()
  }
  return _singletonPort
}

/**
 * Reset the singleton — test-only hook. Allows each test to re-mock the
 * underlying haptics module and re-construct the port without bleed.
 */
export function _resetMobileEffectsPortForTests(): void {
  _singletonPort = null
}

/**
 * Build the mobile EffectsPort. Best-effort — never throws upward.
 *
 * Most call sites should prefer `getMobileEffectsPort()` so the
 * thinking-haptic loop's interval handle is shared between the shared
 * voice-chat service and the `useVoiceChat` hook (CHT-007). This factory
 * is retained for tests that want a fresh instance.
 */
export function createMobileEffectsPort(): EffectsPort {
  // Scoped to this port instance: a single setInterval handle that ticks
  // the thinking-state haptic. Held in closure so start/stop can clear
  // it without leaking timers across calls.
  let thinkingHandle: ReturnType<typeof setInterval> | null = null

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
      // P1-AJ: subtle haptic pulse while the model is composing a reply.
      // Idempotent — if a loop is already running, leave it alone so a
      // second call doesn't stack timers (which would double the
      // perceived cadence).
      if (thinkingHandle !== null) return
      thinkingHandle = setInterval(tickHaptic, THINKING_TICK_MS)
    },
    stopThinkingSound() {
      if (thinkingHandle !== null) {
        clearInterval(thinkingHandle)
        thinkingHandle = null
      }
    }
  }
}
