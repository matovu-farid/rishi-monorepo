/**
 * Generates a subtle, looping "thinking" audio cue using the Web Audio API.
 * Plays soft, rhythmic tones to indicate the AI is processing/fetching context.
 * No external audio files required.
 */

let ctx: AudioContext | null = null
let gainNode: GainNode | null = null
let intervalId: ReturnType<typeof setInterval> | null = null

const VOLUME = 0.08
const TICK_INTERVAL_MS = 600
const TICK_DURATION = 0.12
const BASE_FREQ = 660

function getContext(): AudioContext {
  if (!ctx || ctx.state === 'closed') {
    ctx = new AudioContext()
    gainNode = ctx.createGain()
    gainNode.gain.value = 0
    gainNode.connect(ctx.destination)
  }
  return ctx
}

function playTick() {
  const audioCtx = getContext()
  if (!gainNode) return

  const osc = audioCtx.createOscillator()
  osc.type = 'sine'
  osc.frequency.value = BASE_FREQ

  const tickGain = audioCtx.createGain()
  const now = audioCtx.currentTime
  // Soft fade in/out for each tick
  tickGain.gain.setValueAtTime(0, now)
  tickGain.gain.linearRampToValueAtTime(VOLUME, now + TICK_DURATION * 0.3)
  tickGain.gain.linearRampToValueAtTime(0, now + TICK_DURATION)

  osc.connect(tickGain)
  tickGain.connect(audioCtx.destination)

  osc.start(now)
  osc.stop(now + TICK_DURATION)
}

export function startThinkingSound() {
  stopThinkingSound()
  // Resume context if suspended (browser autoplay policy)
  const audioCtx = getContext()
  if (audioCtx.state === 'suspended') {
    void audioCtx.resume()
  }
  // Play first tick immediately, then loop
  playTick()
  intervalId = setInterval(playTick, TICK_INTERVAL_MS)
}

export function stopThinkingSound() {
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
  if (ctx && ctx.state !== 'closed') {
    ctx.close().catch(() => {})
    ctx = null
    gainNode = null
  }
}
