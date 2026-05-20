import type { LocalVadConfig, LocalVoiceVad, MediaStreamLike } from './types'

export class VadTimeoutError extends Error {
  override readonly name = 'VadTimeoutError' as const
  constructor(public readonly ms: number) {
    super(`Local VAD timed out waiting for speech end after ${ms}ms`)
  }
}

export class VadDisposedError extends Error {
  override readonly name = 'VadDisposedError' as const
  constructor() {
    super('Local VAD was disposed while waiting for speech end')
  }
}

interface AudioCtxLike {
  state: 'suspended' | 'running' | 'closed'
  resume(): Promise<void>
  close(): Promise<void>
  createMediaStreamSource(stream: MediaStreamLike): { connect(dest: unknown): void; disconnect(): void }
  createAnalyser(): AnalyserLike
}

interface AnalyserLike {
  fftSize: number
  smoothingTimeConstant: number
  connect(dest: unknown): void
  disconnect(): void
  getFloatTimeDomainData(buf: Float32Array): void
}

/** Read the global AudioContext constructor, tolerating absence (test envs). */
function readGlobalAudioContext(): (new () => AudioCtxLike) | null {
  const g = globalThis as unknown as { AudioContext?: new () => AudioCtxLike }
  return typeof g.AudioContext === 'function' ? g.AudioContext : null
}

function computeRms(samples: Float32Array): number {
  let sumSq = 0
  for (let i = 0; i < samples.length; i++) {
    const s = samples[i]!
    sumSq += s * s
  }
  return Math.sqrt(sumSq / samples.length)
}

export function createLocalVad(
  stream: MediaStreamLike,
  config: LocalVadConfig
): LocalVoiceVad | null {
  const Ctor = readGlobalAudioContext()
  if (!Ctor) return null

  let ctx: AudioCtxLike
  try {
    ctx = new Ctor()
  } catch {
    return null
  }

  let analyser: AnalyserLike
  let source: { connect(dest: unknown): void; disconnect(): void }
  try {
    source = ctx.createMediaStreamSource(stream)
    analyser = ctx.createAnalyser()
    analyser.fftSize = config.fftSize
    analyser.smoothingTimeConstant = 0.85
    source.connect(analyser)
  } catch {
    void ctx.close().catch(() => undefined)
    return null
  }

  // resume() defensively — AudioContext starts suspended-until-gesture. Voice
  // chat is already behind a user click so this is a no-op in practice, but
  // it's cheap insurance against new entry points.
  void ctx.resume().catch(() => undefined)

  const buffer = new Float32Array(config.fftSize)
  let disposed = false
  let everSpoke = false
  let currentlySpeaking = false
  /** When currentlySpeaking transitions false, mark the time. End-of-utterance fires after hangoverMs. */
  let lastAboveThresholdAt: number | null = null
  let pendingResolve: (() => void) | null = null
  let pendingReject: ((err: unknown) => void) | null = null
  let pendingTimeoutHandle: ReturnType<typeof setTimeout> | null = null

  function settleResolve(): void {
    const r = pendingResolve
    pendingResolve = null
    pendingReject = null
    if (pendingTimeoutHandle !== null) {
      clearTimeout(pendingTimeoutHandle)
      pendingTimeoutHandle = null
    }
    if (r) r()
  }

  function settleReject(err: unknown): void {
    const r = pendingReject
    pendingResolve = null
    pendingReject = null
    if (pendingTimeoutHandle !== null) {
      clearTimeout(pendingTimeoutHandle)
      pendingTimeoutHandle = null
    }
    if (r) r(err)
  }

  function poll(): void {
    if (disposed) return
    analyser.getFloatTimeDomainData(buffer)
    const rms = computeRms(buffer)
    const now = Date.now()
    if (rms >= config.rmsThreshold) {
      everSpoke = true
      currentlySpeaking = true
      lastAboveThresholdAt = now
    } else if (currentlySpeaking && lastAboveThresholdAt !== null) {
      if (now - lastAboveThresholdAt >= config.hangoverMs) {
        currentlySpeaking = false
        settleResolve()
      }
    }
  }

  const pollHandle = setInterval(poll, config.pollIntervalMs)

  return {
    everSpoke: () => everSpoke,
    waitForSpeechEnd: (timeoutMs: number) => {
      if (disposed) return Promise.reject(new VadDisposedError())
      // Nothing to wait for: never spoke, or already past the hangover.
      if (!everSpoke || !currentlySpeaking) return Promise.resolve()
      return new Promise<void>((resolve, reject) => {
        pendingResolve = resolve
        pendingReject = reject
        pendingTimeoutHandle = setTimeout(() => {
          pendingTimeoutHandle = null
          settleReject(new VadTimeoutError(timeoutMs))
        }, timeoutMs)
      })
    },
    dispose: () => {
      if (disposed) return
      disposed = true
      clearInterval(pollHandle)
      settleReject(new VadDisposedError())
      try {
        source.disconnect()
      } catch {
        /* best-effort */
      }
      try {
        analyser.disconnect()
      } catch {
        /* best-effort */
      }
      void ctx.close().catch(() => undefined)
    }
  }
}
