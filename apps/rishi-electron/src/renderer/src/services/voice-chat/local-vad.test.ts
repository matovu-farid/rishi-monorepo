import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createLocalVad, VadTimeoutError, VadDisposedError } from './local-vad'
import type { LocalVadConfig, MediaStreamLike } from './types'

// =============================================================================
// Fake Web Audio API — drives the real createLocalVad against scripted RMS
// values. happy-dom does not provide AudioContext, so we stub the globals.
// =============================================================================

class FakeAnalyser {
  fftSize = 256
  smoothingTimeConstant = 0.85
  // Single source of truth for what getFloatTimeDomainData writes: a per-call
  // amplitude that the test sets via FakeAudioContext.setAmplitude(). RMS of
  // a constant-amplitude buffer is just |amp|.
  amp = 0
  // The production code calls .connect() / .disconnect() on the analyser for
  // side-effect parity with the real Web Audio graph. vi.fn() satisfies the
  // contract AND lets any future test assert call counts without rewriting
  // the fake.
  connect = vi.fn<(dest?: unknown) => void>()
  disconnect = vi.fn<() => void>()
  getFloatTimeDomainData(out: Float32Array): void {
    out.fill(this.amp)
  }
}

class FakeStreamSource {
  connect = vi.fn<(dest: unknown) => void>()
  disconnect = vi.fn<() => void>()
}

class FakeAudioContext {
  static lastInstance: FakeAudioContext | null = null
  static throwOnConstruct = false
  static throwOnCreateSource = false

  state: 'suspended' | 'running' | 'closed' = 'suspended'
  readonly analyser = new FakeAnalyser()
  readonly source = new FakeStreamSource()
  closeCalls = 0
  resumeCalls = 0

  constructor() {
    if (FakeAudioContext.throwOnConstruct) throw new Error('AudioContext blocked')
    FakeAudioContext.lastInstance = this
  }

  resume(): Promise<void> {
    this.resumeCalls++
    this.state = 'running'
    return Promise.resolve()
  }

  close(): Promise<void> {
    this.closeCalls++
    this.state = 'closed'
    return Promise.resolve()
  }

  createMediaStreamSource(_stream: MediaStreamLike): FakeStreamSource {
    if (FakeAudioContext.throwOnCreateSource) throw new Error('source blocked')
    return this.source
  }

  createAnalyser(): FakeAnalyser {
    return this.analyser
  }

  setAmplitude(amp: number): void {
    this.analyser.amp = amp
  }
}

function makeStream(): MediaStreamLike {
  return { getTracks: () => [{ stop: vi.fn() }] }
}

const baseConfig: LocalVadConfig = {
  rmsThreshold: 0.05,
  hangoverMs: 700,
  pollIntervalMs: 50,
  fftSize: 256
}

beforeEach(() => {
  FakeAudioContext.lastInstance = null
  FakeAudioContext.throwOnConstruct = false
  FakeAudioContext.throwOnCreateSource = false
  vi.stubGlobal('AudioContext', FakeAudioContext as unknown as typeof AudioContext)
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

/** Advance time AND flush microtasks so awaited promises settle. */
async function advance(ms: number): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms)
}

// =============================================================================
// Tests
// =============================================================================

describe('createLocalVad — construction', () => {
  it('returns a VAD instance when AudioContext is available', () => {
    const vad = createLocalVad(makeStream(), baseConfig)
    expect(vad).not.toBeNull()
    expect(vad!.everSpoke()).toBe(false)
  })

  it('returns null when AudioContext constructor throws', () => {
    FakeAudioContext.throwOnConstruct = true
    const vad = createLocalVad(makeStream(), baseConfig)
    expect(vad).toBeNull()
  })

  it('returns null when createMediaStreamSource throws; AudioContext is closed', () => {
    FakeAudioContext.throwOnCreateSource = true
    const vad = createLocalVad(makeStream(), baseConfig)
    expect(vad).toBeNull()
    // The defensively-closed AudioContext is the one that was constructed
    // before createMediaStreamSource blew up.
    expect(FakeAudioContext.lastInstance?.closeCalls).toBe(1)
  })

  it('returns null when global AudioContext is undefined', () => {
    vi.stubGlobal('AudioContext', undefined)
    const vad = createLocalVad(makeStream(), baseConfig)
    expect(vad).toBeNull()
  })

  it('calls resume() defensively after construction', () => {
    createLocalVad(makeStream(), baseConfig)
    expect(FakeAudioContext.lastInstance?.resumeCalls).toBe(1)
  })
})

describe('createLocalVad — everSpoke', () => {
  it('returns false when RMS never crosses the threshold', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    FakeAudioContext.lastInstance!.setAmplitude(0.01) // below 0.05
    await advance(500)
    expect(vad.everSpoke()).toBe(false)
    vad.dispose()
  })

  it('becomes true after a single above-threshold poll', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    FakeAudioContext.lastInstance!.setAmplitude(0.1) // above 0.05
    await advance(baseConfig.pollIntervalMs)
    expect(vad.everSpoke()).toBe(true)
    vad.dispose()
  })

  it('stays true after speech returns to silence (sticky)', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    ctx.setAmplitude(0.2)
    await advance(baseConfig.pollIntervalMs)
    expect(vad.everSpoke()).toBe(true)
    ctx.setAmplitude(0)
    await advance(2000)
    expect(vad.everSpoke()).toBe(true)
    vad.dispose()
  })
})

describe('createLocalVad — waitForSpeechEnd', () => {
  it('resolves immediately when everSpoke() is false', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    await expect(vad.waitForSpeechEnd(5000)).resolves.toBeUndefined()
    vad.dispose()
  })

  it('resolves immediately when speech already ended (past hangover)', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    ctx.setAmplitude(0.2)
    await advance(baseConfig.pollIntervalMs)
    ctx.setAmplitude(0)
    // Drive past the hangover.
    await advance(baseConfig.hangoverMs + baseConfig.pollIntervalMs)
    // Now waitForSpeechEnd should resolve without further ticks.
    await expect(vad.waitForSpeechEnd(5000)).resolves.toBeUndefined()
    vad.dispose()
  })

  it('blocks while speech is active; resolves after hangoverMs of silence', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    // Speech starts and stays active.
    ctx.setAmplitude(0.2)
    await advance(baseConfig.pollIntervalMs)
    expect(vad.everSpoke()).toBe(true)

    const settled = vi.fn()
    const waitPromise = vad.waitForSpeechEnd(10_000).then(settled, settled)

    // Still speaking → wait should not settle.
    await advance(2000)
    expect(settled).not.toHaveBeenCalled()

    // Drop to silence; the hangover window starts now.
    ctx.setAmplitude(0)
    await advance(baseConfig.hangoverMs - baseConfig.pollIntervalMs)
    expect(settled).not.toHaveBeenCalled()

    // Cross the hangover threshold.
    await advance(2 * baseConfig.pollIntervalMs)
    await waitPromise
    expect(settled).toHaveBeenCalledTimes(1)
    expect(settled).toHaveBeenCalledWith(undefined)
    vad.dispose()
  })

  it('rejects with VadTimeoutError when timeoutMs elapses while still speaking', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    ctx.setAmplitude(0.2)
    await advance(baseConfig.pollIntervalMs)

    const settled = vi.fn()
    const waitPromise = vad.waitForSpeechEnd(300).then(
      () => settled('ok'),
      (e: unknown) => settled(e)
    )

    await advance(400)
    await waitPromise
    expect(settled).toHaveBeenCalledTimes(1)
    const arg = settled.mock.calls[0]![0]
    expect(arg).toBeInstanceOf(VadTimeoutError)
    expect((arg as VadTimeoutError).ms).toBe(300)
    vad.dispose()
  })

  it('rejects with VadDisposedError when dispose() is called mid-wait', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    ctx.setAmplitude(0.2)
    await advance(baseConfig.pollIntervalMs)

    const settled = vi.fn()
    const waitPromise = vad.waitForSpeechEnd(10_000).then(
      () => settled('ok'),
      (e: unknown) => settled(e)
    )

    vad.dispose()
    await advance(0)
    await waitPromise
    expect(settled).toHaveBeenCalledTimes(1)
    expect(settled.mock.calls[0]![0]).toBeInstanceOf(VadDisposedError)
  })

  it('rejects synchronously with VadDisposedError when called after dispose', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    vad.dispose()
    await expect(vad.waitForSpeechEnd(1000)).rejects.toBeInstanceOf(VadDisposedError)
  })
})

describe('createLocalVad — dispose', () => {
  it('closes the AudioContext and stops the poll interval', async () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    const ctx = FakeAudioContext.lastInstance!
    expect(ctx.closeCalls).toBe(0)

    vad.dispose()
    expect(ctx.closeCalls).toBe(1)

    // After dispose, further amplitude changes must not flip everSpoke.
    ctx.setAmplitude(0.5)
    await advance(2000)
    expect(vad.everSpoke()).toBe(false)
  })

  it('is idempotent — double dispose does not double-close', () => {
    const vad = createLocalVad(makeStream(), baseConfig)!
    vad.dispose()
    vad.dispose()
    expect(FakeAudioContext.lastInstance!.closeCalls).toBe(1)
  })
})
