import { describe, it, expect, vi } from 'vitest'
import { createVoiceChatService } from './service'
import { OfflineError as OfflineErrorImport } from './types'
import type {
  AgentFactoryArgs,
  AudioElementLike,
  ChatStatus,
  ClockPort,
  EffectsPort,
  LocalVoiceVad,
  MediaPort,
  MediaStreamLike,
  NetworkPort,
  RealtimeAgentLike,
  RealtimeSessionLike,
  RtcTransportLike,
  SessionFactoryOpts,
  VadPort,
  VoiceChatConfig,
  VoiceChatConnectivityPort,
  VoiceChatIpc,
  VoiceChatPublicState,
  VoiceChatRagPort,
  VoiceChatServiceDeps,
  WebrtcFactoryArgs
} from './types'
import { VadTimeoutError, VadDisposedError } from './local-vad'

// =============================================================================
// Test helpers — verbatim port from
// `apps/rishi-electron/src/renderer/src/services/voice-chat/service.test.ts`.
// The only changes vs. electron:
//   - `RagService` -> `VoiceChatRagPort`
//   - `ConnectivityService` -> `VoiceChatConnectivityPort`
//   - `vitest` import path stays the same.
// =============================================================================

export function makeRag(): VoiceChatRagPort {
  return {
    searchSemantic: vi.fn().mockResolvedValue([{ text: 'fake chunk' }])
  }
}

export function makeConnectivity(opts?: {
  initialOnline?: boolean
}): VoiceChatConnectivityPort & { setOnline(b: boolean): void } {
  let online = opts?.initialOnline ?? true
  const listeners = new Set<(online: boolean) => void>()
  return {
    isOnline: () => online,
    subscribe: (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    setOnline(b) {
      if (online === b) return
      online = b
      for (const l of listeners) l(b)
    }
  }
}

export function makeIpc(opts?: {
  key?: string
  failWith?: Error
  transcript?: string
  transcribeFailWith?: Error
}): VoiceChatIpc & { transcribeAudio: ReturnType<typeof vi.fn> } {
  const transcribeAudio = vi.fn().mockImplementation(async (_blob: Blob) => {
    if (opts?.transcribeFailWith) throw opts.transcribeFailWith
    return opts?.transcript ?? ''
  })
  return {
    getRealtimeClientSecret: vi.fn().mockImplementation(async (_language: string) => {
      if (opts?.failWith) throw opts.failWith
      return opts?.key ?? 'test-key'
    }),
    transcribeAudio
  }
}

export function makeWebrtc(): {
  factory: (args: WebrtcFactoryArgs) => RtcTransportLike
  callCount: () => number
  lastArgs: () => WebrtcFactoryArgs | null
} {
  let count = 0
  let lastArgs: WebrtcFactoryArgs | null = null
  return {
    factory: (args) => {
      count++
      lastArgs = args
      return { _transport: { id: count } } as RtcTransportLike
    },
    callCount: () => count,
    lastArgs: () => lastArgs
  }
}

export function makeAgent(): {
  factory: (args: AgentFactoryArgs) => RealtimeAgentLike
  lastArgs: () => AgentFactoryArgs | null
  triggerEnd: (reason: string) => void
  triggerInspectImage: (image: { dataUrl: string; width: number; height: number; bytes: number }) => void
} {
  let lastArgs: AgentFactoryArgs | null = null
  let lastOnEnd: ((reason: string) => void) | null = null
  let lastOnInspect: ((image: { dataUrl: string; width: number; height: number; bytes: number }) => void) | null = null
  return {
    factory: (args) => {
      lastArgs = args
      lastOnEnd = args.onEndConversation
      lastOnInspect = args.onInspectImage ?? null
      return { _agent: {} } as RealtimeAgentLike
    },
    lastArgs: () => lastArgs,
    triggerEnd: (reason) => lastOnEnd?.(reason),
    triggerInspectImage: (image) => lastOnInspect?.(image)
  }
}

export function makeSession(opts?: { connectDelayMs?: number; connectFailWith?: Error }): {
  factory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  session: RealtimeSessionLike
  mute: ReturnType<typeof vi.fn>
  interrupt: ReturnType<typeof vi.fn>
  close: ReturnType<typeof vi.fn>
  updateAgent: ReturnType<typeof vi.fn>
  connect: ReturnType<typeof vi.fn>
  sendMessage: ReturnType<typeof vi.fn>
  addImage: ReturnType<typeof vi.fn>
  fire: (event: string, ...args: unknown[]) => void
  lastConnectOpts: () => { apiKey: string } | null
} {
  const handlers = new Map<string, Set<(...args: unknown[]) => void>>()
  let lastConnectOpts: { apiKey: string } | null = null
  const connect = vi.fn().mockImplementation(async (o: { apiKey: string }) => {
    lastConnectOpts = o
    if (opts?.connectFailWith) throw opts.connectFailWith
    if (opts?.connectDelayMs) {
      await new Promise((r) => {
        setTimeout(r, opts.connectDelayMs)
      })
    }
  })
  const mute = vi.fn()
  const interrupt = vi.fn()
  const close = vi.fn()
  const updateAgent = vi.fn().mockResolvedValue(undefined)
  const sendMessage = vi.fn()
  const addImage = vi.fn()
  const session: RealtimeSessionLike = {
    connect,
    mute,
    interrupt,
    close,
    updateAgent,
    sendMessage,
    addImage,
    on: (ev, l) => {
      if (!handlers.has(ev)) handlers.set(ev, new Set())
      handlers.get(ev)!.add(l)
    },
    off: (ev, l) => {
      handlers.get(ev)?.delete(l)
    }
  }
  return {
    factory: () => session,
    session,
    mute,
    interrupt,
    close,
    updateAgent,
    connect,
    sendMessage,
    addImage,
    fire: (ev, ...args) => {
      const set = handlers.get(ev)
      if (!set) return
      for (const l of [...set]) l(...args)
    },
    lastConnectOpts: () => lastConnectOpts
  }
}

export interface FakeRecorder {
  start: ReturnType<typeof vi.fn>
  stop: ReturnType<typeof vi.fn>
  state: 'inactive' | 'recording' | 'paused'
  ondataavailable: ((event: { data: Blob }) => void) | null
  onstop: (() => void) | null
  emitChunk: (data: Blob) => void
  fireOnstop: () => void
}

export function makeMedia(opts?: {
  denyMic?: boolean
  withRecorder?: boolean
  recorderConstructThrows?: boolean
  recorderStopThrows?: boolean
  deferOnstop?: boolean
}): MediaPort & {
  stream: MediaStreamLike
  audioElement: AudioElementLike
  lastRecorder: () => FakeRecorder | null
  lastWebrtcClone: () => MediaStreamLike | null
  cloneTrackStops: () => Array<ReturnType<typeof vi.fn>>
} {
  const stream: MediaStreamLike = { getTracks: () => [{ stop: vi.fn() }] }
  const audioElement: AudioElementLike = {
    muted: false,
    srcObject: null,
    autoplay: true,
    pause: vi.fn()
  }
  const cloneTrackStops: Array<ReturnType<typeof vi.fn>> = []
  let lastClone: MediaStreamLike | null = null
  const cloneStreamForWebrtcSend = vi.fn().mockImplementation((_source: MediaStreamLike) => {
    const stop = vi.fn()
    cloneTrackStops.push(stop)
    const cloned: MediaStreamLike = { getTracks: () => [{ stop }] }
    lastClone = cloned
    return cloned
  })
  let lastRec: FakeRecorder | null = null
  const port: MediaPort & {
    stream: MediaStreamLike
    audioElement: AudioElementLike
    lastRecorder: () => FakeRecorder | null
    lastWebrtcClone: () => MediaStreamLike | null
    cloneTrackStops: () => Array<ReturnType<typeof vi.fn>>
  } = {
    stream,
    audioElement,
    getUserMedia: vi.fn().mockImplementation(async () => {
      if (opts?.denyMic) {
        const err = new Error('Permission denied')
        ;(err as { name: string }).name = 'NotAllowedError'
        throw err
      }
      return stream
    }),
    createAudioElement: vi.fn().mockReturnValue(audioElement),
    cloneStreamForWebrtcSend,
    lastRecorder: () => lastRec,
    lastWebrtcClone: () => lastClone,
    cloneTrackStops: () => cloneTrackStops
  }
  if (opts?.withRecorder) {
    port.createMediaRecorder = vi.fn().mockImplementation((_s: MediaStreamLike) => {
      if (opts?.recorderConstructThrows) throw new Error('MediaRecorder construct failed')
      const rec: FakeRecorder = {
        start: vi.fn().mockImplementation(() => {
          rec.state = 'recording'
        }),
        stop: vi.fn().mockImplementation(() => {
          if (opts?.recorderStopThrows) throw new Error('stop failed')
          rec.state = 'inactive'
          if (!opts?.deferOnstop) rec.onstop?.()
        }),
        state: 'inactive',
        ondataavailable: null,
        onstop: null,
        emitChunk: (data) => rec.ondataavailable?.({ data }),
        fireOnstop: () => rec.onstop?.()
      }
      lastRec = rec
      return rec
    })
  }
  return port
}

export function makeEffects(): EffectsPort & {
  readyChimeCalls: () => number
  thinkingStartCalls: () => number
  thinkingStopCalls: () => number
} {
  let ready = 0
  let start = 0
  let stop = 0
  return {
    playReadyChime: () => {
      ready++
    },
    startThinkingSound: () => {
      start++
    },
    stopThinkingSound: () => {
      stop++
    },
    readyChimeCalls: () => ready,
    thinkingStartCalls: () => start,
    thinkingStopCalls: () => stop
  }
}

export function makeClock(): ClockPort & { tick(ms: number): void; setNow(t: number): void } {
  let now = 0
  const timers: Array<{ id: number; at: number; fn: () => void; cancelled: boolean }> = []
  let nextId = 1
  return {
    now: () => now,
    setTimeout: (fn, ms) => {
      const id = nextId++
      timers.push({ id, at: now + ms, fn, cancelled: false })
      return id as unknown as ReturnType<typeof setTimeout>
    },
    clearTimeout: (handle) => {
      const t = timers.find((x) => x.id === (handle as unknown as number))
      if (t) t.cancelled = true
    },
    tick(ms) {
      const target = now + ms
      while (true) {
        const due = timers
          .filter((t) => !t.cancelled && t.at <= target)
          .sort((a, b) => a.at - b.at)[0]
        if (!due) break
        now = due.at
        due.cancelled = true
        due.fn()
      }
      now = target
    },
    setNow(t) {
      now = t
    }
  }
}

export function makeConfig(overrides?: Partial<VoiceChatConfig>): VoiceChatConfig {
  return {
    inactivityTimeoutMs: 3 * 60 * 1000,
    connectTimeoutMs: 60 * 1000,
    keyTtlMs: 9 * 60 * 1000,
    bufferedSpeechReplayEnabled: true,
    localVad: {
      rmsThreshold: 0.05,
      hangoverMs: 700,
      pollIntervalMs: 50,
      fftSize: 256
    },
    serverVad: {
      threshold: 0.7,
      silenceDurationMs: 700,
      prefixPaddingMs: 300
    },
    ...overrides
  }
}

export interface FakeVad extends LocalVoiceVad {
  emitSpeechStart: () => void
  emitSpeechEnd: () => void
  setEverSpoke: (value: boolean) => void
  disposeCalls: () => number
  hasPendingWait: () => boolean
}

export function makeVad(opts?: {
  initialEverSpoke?: boolean
  initiallySpeaking?: boolean
  unavailable?: boolean
}): {
  port: VadPort
  vad: FakeVad | null
  lastStream: () => MediaStreamLike | null
} {
  let everSpoke = opts?.initialEverSpoke ?? true
  let speaking = opts?.initiallySpeaking ?? false
  let disposeCalls = 0
  let pendingResolve: (() => void) | null = null
  let pendingReject: ((err: unknown) => void) | null = null
  let pendingTimeoutId: ReturnType<typeof setTimeout> | null = null
  let disposed = false
  let lastStream: MediaStreamLike | null = null

  const vad: FakeVad | null = opts?.unavailable
    ? null
    : {
        everSpoke: () => everSpoke,
        waitForSpeechEnd: (timeoutMs: number) => {
          if (disposed) return Promise.reject(new VadDisposedError())
          if (!everSpoke || !speaking) return Promise.resolve()
          return new Promise<void>((resolve, reject) => {
            pendingResolve = resolve
            pendingReject = reject
            pendingTimeoutId = setTimeout(() => {
              pendingResolve = null
              pendingReject = null
              pendingTimeoutId = null
              reject(new VadTimeoutError(timeoutMs))
            }, timeoutMs)
          })
        },
        dispose: () => {
          if (disposed) return
          disposed = true
          disposeCalls++
          if (pendingTimeoutId !== null) clearTimeout(pendingTimeoutId)
          const reject = pendingReject
          pendingResolve = null
          pendingReject = null
          pendingTimeoutId = null
          if (reject) reject(new VadDisposedError())
        },
        emitSpeechStart: () => {
          speaking = true
          everSpoke = true
        },
        emitSpeechEnd: () => {
          speaking = false
          if (pendingTimeoutId !== null) clearTimeout(pendingTimeoutId)
          const resolve = pendingResolve
          pendingResolve = null
          pendingReject = null
          pendingTimeoutId = null
          if (resolve) resolve()
        },
        setEverSpoke: (value: boolean) => {
          everSpoke = value
        },
        disposeCalls: () => disposeCalls,
        hasPendingWait: () => pendingResolve !== null
      }

  const port: VadPort = {
    create: (stream) => {
      lastStream = stream
      return vad
    }
  }

  return { port, vad, lastStream: () => lastStream }
}

export function makeNetwork(): NetworkPort & {
  preconnectCalls: () => number
} {
  let calls = 0
  return {
    preconnectOpenAI: () => {
      calls++
    },
    preconnectCalls: () => calls
  }
}

export function makeDeps(overrides?: Partial<VoiceChatServiceDeps>): VoiceChatServiceDeps {
  return {
    rag: makeRag(),
    connectivity: makeConnectivity(),
    ipc: makeIpc(),
    webrtcFactory: makeWebrtc().factory,
    agentFactory: makeAgent().factory,
    sessionFactory: makeSession().factory,
    media: makeMedia(),
    vad: makeVad().port,
    effects: makeEffects(),
    clock: makeClock(),
    network: makeNetwork(),
    config: makeConfig(),
    getLanguage: () => 'en',
    ...overrides
  }
}

// =============================================================================
// Tests — lifecycle.
// =============================================================================

describe('createVoiceChatService — lifecycle', () => {
  it('starts in idle state with no error', () => {
    const svc = createVoiceChatService(makeDeps())
    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })

  it('start() is idempotent — calling twice does not double-subscribe connectivity', () => {
    const connectivity = makeConnectivity()
    const subSpy = vi.spyOn(connectivity, 'subscribe')
    const svc = createVoiceChatService(makeDeps({ connectivity }))

    svc.start()
    svc.start()

    expect(subSpy).toHaveBeenCalledTimes(1)
  })

  it('stop() unsubscribes connectivity + is idempotent', () => {
    const connectivity = makeConnectivity()
    const svc = createVoiceChatService(makeDeps({ connectivity }))

    svc.start()
    svc.stop()
    svc.stop()

    connectivity.setOnline(false)
    expect(svc.getState()).toBe('idle')
  })
})

describe('createVoiceChatService — onStateChange', () => {
  it('edge-detects no-value transitions (same machine value -> no fire)', () => {
    const svc = createVoiceChatService(makeDeps())
    const spy = vi.fn()
    svc.onStateChange(spy)

    svc.dispose()
    svc.dispose()
    svc.dispose()

    expect(spy).not.toHaveBeenCalled()
  })
})

describe('createVoiceChatService — activate (cold happy path)', () => {
  it('idle → connecting → active; mic + transport + agent + session + connect + mute(false)', async () => {
    const media = makeMedia()
    const webrtc = makeWebrtc()
    const agent = makeAgent()
    const session = makeSession()
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const states: VoiceChatPublicState[] = []

    const svc = createVoiceChatService(
      makeDeps({
        media,
        webrtcFactory: webrtc.factory,
        agentFactory: agent.factory,
        sessionFactory: session.factory,
        ipc
      })
    )
    svc.onStateChange((s) => states.push(s))

    await svc.activate(7, { pageText: 'hello' })

    expect(states).toEqual(['connecting', 'active'])
    expect(media.getUserMedia).toHaveBeenCalledWith({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    })
    expect(webrtc.callCount()).toBe(1)
    expect(agent.lastArgs()?.bookId).toBe(7)
    expect(agent.lastArgs()?.pageText).toBe('hello')
    expect(session.connect).toHaveBeenCalledWith({ apiKey: 'EPHEMERAL' })
    expect(session.mute).toHaveBeenCalledWith(false)
    expect(svc.getState()).toBe('active')
  })

  it('deactivate() from active → idle; session.close + mic tracks stopped', async () => {
    const media = makeMedia()
    const stopSpy = vi.fn()
    media.stream.getTracks = () => [{ stop: stopSpy }]
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'p' })
    svc.deactivate()

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(stopSpy).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('deactivate() during in-flight cold path interrupts fiber + tears down resources', async () => {
    const stopSpy = vi.fn()
    const media = makeMedia()
    media.stream.getTracks = () => [{ stop: stopSpy }]
    const session = makeSession({ connectDelayMs: 50 })
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    const activatePromise = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => {
      setTimeout(r, 10)
    })
    expect(svc.getState()).toBe('connecting')

    svc.deactivate()

    await activatePromise.catch(() => undefined)

    expect(stopSpy).toHaveBeenCalledTimes(1)
    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('dispose() from active → idle; session.close() called', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('chatStatus fires connecting → idle around a cold activate', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    const statuses: ChatStatus[] = []
    svc.onChatStatus((s) => statuses.push(s))

    await svc.activate(1, { pageText: 'p' })

    expect(statuses[0]).toBe('connecting')
    expect(statuses[statuses.length - 1]).toBe('idle')
  })
})

describe('createVoiceChatService — warm path + preconnect + prewarm', () => {
  it('warm activate on same bookId calls updateAgent when ctx changes; no new mic prompt', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'a' })
    expect(media.getUserMedia).toHaveBeenCalledTimes(1)

    await svc.activate(1, { pageText: 'b' })

    expect(session.updateAgent).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).toHaveBeenCalledTimes(1)
  })

  it('warm activate skips updateAgent when ctx fingerprint is unchanged', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'same' })
    await svc.activate(1, { pageText: 'same' })

    expect(session.updateAgent).not.toHaveBeenCalled()
  })

  it('warm activate does NOT call updateAgent when only activeParagraphText changes', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'page', activeParagraphText: 'first paragraph' })
    await svc.activate(1, { pageText: 'page', activeParagraphText: 'second paragraph' })
    await svc.activate(1, { pageText: 'page', activeParagraphText: 'third paragraph' })

    expect(session.updateAgent).not.toHaveBeenCalled()
  })

  it('activate on different bookId disposes the old session first', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'a' })
    await svc.activate(2, { pageText: 'b' })

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('active')
  })

  it('concurrent activate calls share the in-flight promise', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    const [p1, p2] = [svc.activate(7, { pageText: 'p' }), svc.activate(7, { pageText: 'p' })]
    await Promise.all([p1, p2])

    expect(session.connect).toHaveBeenCalledTimes(1)
  })

  it('preconnect never opens a session or prompts for mic', async () => {
    const session = makeSession()
    const ipc = makeIpc()
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory, ipc, media }))

    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    const connectCallsBefore = session.connect.mock.calls.length
    const mediaCallsBefore = (media.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length

    await svc.preconnect(1, { pageText: 'p' })

    expect(session.connect.mock.calls.length).toBe(connectCallsBefore)
    expect((media.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length).toBe(
      mediaCallsBefore
    )
    expect(svc.getState()).toBe('idle')
  })

  it('preconnect() triggers network.preconnectOpenAI for TLS/DNS warmup', async () => {
    const network = makeNetwork()
    const svc = createVoiceChatService(makeDeps({ network }))

    await svc.preconnect(1, { pageText: 'p' })

    expect(network.preconnectCalls()).toBe(1)
  })

  it('preconnect() primes the key cache so the next activate skips the mint roundtrip', async () => {
    const ipc = makeIpc({ key: 'PRECONNECTED_KEY' })
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await svc.preconnect(1, { pageText: 'p' })
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)

    await svc.activate(1, { pageText: 'p' })
    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)
  })

  it('preconnect() is best-effort: network.preconnectOpenAI throwing does not reject', async () => {
    const network: NetworkPort = {
      preconnectOpenAI: () => {
        throw new Error('link insertion blew up')
      }
    }
    const svc = createVoiceChatService(makeDeps({ network }))

    await expect(svc.preconnect(1, { pageText: 'p' })).resolves.toBeUndefined()
    expect(svc.getState()).toBe('idle')
  })

  it('preconnect() is best-effort: key-mint failure does not reject', async () => {
    const ipc = makeIpc()
    ;(ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>).mockRejectedValueOnce(
      new Error('worker 503')
    )
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await expect(svc.preconnect(1, { pageText: 'p' })).resolves.toBeUndefined()
    expect(svc.getState()).toBe('idle')
  })

  it('preconnect() called repeatedly while a session is active does not disturb the session', async () => {
    const session = makeSession()
    const network = makeNetwork()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory, network }))

    await svc.activate(1, { pageText: 'p' })
    expect(svc.getState()).toBe('active')

    await svc.preconnect(1, { pageText: 'p' })
    await svc.preconnect(1, { pageText: 'p' })

    expect(svc.getState()).toBe('active')
    expect(session.close).not.toHaveBeenCalled()
  })

  it('prewarmKey() fetches the ephemeral key without prompting for mic', async () => {
    const ipc = makeIpc({ key: 'PREWARM' })
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ ipc, media }))

    svc.prewarmKey()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).not.toHaveBeenCalled()
  })

  it('invalidateKey() drops the cached ephemeral key so next activate() refetches', async () => {
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const svc = createVoiceChatService(makeDeps({ ipc }))
    svc.start()

    await svc.activate(1, { pageText: 'p' })
    const callsAfterFirstActivate = (ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>).mock
      .calls.length
    svc.deactivate()

    svc.invalidateKey()

    await svc.activate(1, { pageText: 'p' })
    const callsAfterSecondActivate = (ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>).mock
      .calls.length

    expect(callsAfterSecondActivate).toBe(callsAfterFirstActivate + 1)
  })

  it('passes language from getLanguage() to agentFactory and getRealtimeClientSecret', async () => {
    const ipc = makeIpc({ key: 'EPHEMERAL' })
    const agent = makeAgent()
    const svc = createVoiceChatService(
      makeDeps({
        ipc,
        agentFactory: agent.factory,
        getLanguage: () => 'es'
      })
    )
    svc.start()

    await svc.activate(1, { pageText: 'p' })

    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledWith('es')
    expect(agent.lastArgs()?.language).toBe('es')
  })
})

describe('createVoiceChatService — errors', () => {
  it('mic denial classifies as mic_denied; state → error; getError populated', async () => {
    const media = makeMedia({ denyMic: true })
    const svc = createVoiceChatService(makeDeps({ media }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toMatchObject({
      name: 'NotAllowedError'
    })

    expect(svc.getState()).toBe('error')
    expect(svc.getError()).toEqual({ reason: 'mic_denied', message: 'Permission denied' })
  })

  it('auth failure classifies as auth_failed', async () => {
    const ipc = makeIpc({ failWith: new Error('Not authenticated') })
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow(/Not authenticated/)
    expect(svc.getError()?.reason).toBe('auth_failed')
  })

  it('session.connect failure classifies as connect_failed; half-built session closed', async () => {
    const session = makeSession({ connectFailWith: new Error('boom') })
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow('boom')
    expect(session.close).toHaveBeenCalled()
    expect(svc.getError()?.reason).toBe('connect_failed')
    expect(svc.getState()).toBe('error')
  })

  it('dismissError clears the error and transitions error → idle', async () => {
    const ipc = makeIpc({ failWith: new Error('Not authenticated') })
    const svc = createVoiceChatService(makeDeps({ ipc }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow()
    expect(svc.getState()).toBe('error')

    svc.dismissError()
    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })
})

describe('createVoiceChatService — connectivity gating', () => {
  it('activate while offline rejects with OfflineError; state → offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: false })
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ connectivity, media }))

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toBeInstanceOf(OfflineErrorImport)
    expect(svc.getState()).toBe('offline')
    expect(media.getUserMedia).not.toHaveBeenCalled()
  })

  it('mid-session offline transition disposes the session + state → offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ connectivity, sessionFactory: session.factory }))
    svc.start()
    await svc.activate(1, { pageText: 'p' })
    expect(svc.getState()).toBe('active')

    connectivity.setOnline(false)

    expect(session.close).toHaveBeenCalled()
    expect(svc.getState()).toBe('offline')
  })

  it('offline → online transitions back to idle (error cleared)', async () => {
    const connectivity = makeConnectivity({ initialOnline: false })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    await expect(svc.activate(1, { pageText: 'p' })).rejects.toBeInstanceOf(OfflineErrorImport)
    expect(svc.getState()).toBe('offline')

    connectivity.setOnline(true)

    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })

  it('onStateChange fans out to multiple subscribers on offline transition', () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    const a = vi.fn()
    const b = vi.fn()
    svc.onStateChange(a)
    svc.onStateChange(b)

    connectivity.setOnline(false)

    expect(a).toHaveBeenCalledWith('offline')
    expect(b).toHaveBeenCalledWith('offline')
  })

  it('unsubscribe stops further onStateChange invocations', () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const svc = createVoiceChatService(makeDeps({ connectivity }))
    svc.start()
    const spy = vi.fn()
    const off = svc.onStateChange(spy)

    connectivity.setOnline(false)
    expect(spy).toHaveBeenCalledTimes(1)

    off()
    connectivity.setOnline(true)
    expect(spy).toHaveBeenCalledTimes(1)
  })
})

describe('createVoiceChatService — inactivity timeout', () => {
  it('auto-closes the session after inactivityTimeoutMs of no activity', async () => {
    const clock = makeClock()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        clock,
        sessionFactory: session.factory,
        config: makeConfig({ inactivityTimeoutMs: 3 * 60 * 1000 })
      })
    )
    await svc.activate(1, { pageText: 'p' })
    expect(svc.getState()).toBe('active')

    clock.tick(3 * 60 * 1000)

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('resets the inactivity timer when the agent emits a chatStatus event', async () => {
    const clock = makeClock()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        clock,
        sessionFactory: session.factory,
        config: makeConfig({ inactivityTimeoutMs: 3 * 60 * 1000 })
      })
    )
    await svc.activate(1, { pageText: 'p' })

    clock.tick(2 * 60 * 1000)
    session.fire('audio_start')
    clock.tick(2 * 60 * 1000)

    expect(session.close).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')

    clock.tick(1 * 60 * 1000)
    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('inactivity timeout fires onEndedByAgent listeners so consumers can reset UI state', async () => {
    const clock = makeClock()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        clock,
        sessionFactory: session.factory,
        config: makeConfig({ inactivityTimeoutMs: 3 * 60 * 1000 })
      })
    )
    const endedReasons: string[] = []
    svc.onEndedByAgent((reason) => endedReasons.push(reason))
    await svc.activate(1, { pageText: 'p' })

    clock.tick(3 * 60 * 1000)

    expect(endedReasons).toEqual(['inactivity_timeout'])
    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('tool events reset the inactivity timer so long tool calls do not auto-close', async () => {
    const clock = makeClock()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        clock,
        sessionFactory: session.factory,
        config: makeConfig({ inactivityTimeoutMs: 3 * 60 * 1000 })
      })
    )
    await svc.activate(1, { pageText: 'p' })

    clock.tick(2 * 60 * 1000)
    session.fire('agent_tool_start')
    clock.tick(2 * 60 * 1000)
    session.fire('agent_tool_end')
    clock.tick(2 * 60 * 1000)

    expect(session.close).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')
  })

  it('clears the inactivity timer on explicit dispose so it never double-fires', async () => {
    const clock = makeClock()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        clock,
        sessionFactory: session.factory,
        config: makeConfig({ inactivityTimeoutMs: 3 * 60 * 1000 })
      })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()
    expect(session.close).toHaveBeenCalledTimes(1)

    clock.tick(10 * 60 * 1000)

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })
})

describe('createVoiceChatService — RAG passthrough + onEndedByAgent', () => {
  it('passes the injected RAG port through agentFactory', async () => {
    const rag = makeRag()
    const agent = makeAgent()
    const svc = createVoiceChatService(makeDeps({ rag, agentFactory: agent.factory }))
    await svc.activate(1, { pageText: 'p' })

    expect(agent.lastArgs()?.rag).toBe(rag)
    expect(agent.lastArgs()?.bookId).toBe(1)
  })

  it('onEndedByAgent fires when the agent invokes endConversation tool', async () => {
    const agent = makeAgent()
    const svc = createVoiceChatService(makeDeps({ agentFactory: agent.factory }))
    const spy = vi.fn()
    svc.onEndedByAgent(spy)

    await svc.activate(1, { pageText: 'p' })
    agent.triggerEnd('all done')

    expect(spy).toHaveBeenCalledWith('all done')
  })

  it('onEndedByAgent unsubscribe stops further deliveries', async () => {
    const agent = makeAgent()
    const svc = createVoiceChatService(makeDeps({ agentFactory: agent.factory }))
    const spy = vi.fn()
    const off = svc.onEndedByAgent(spy)

    await svc.activate(1, { pageText: 'p' })
    agent.triggerEnd('one')
    off()
    agent.triggerEnd('two')

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith('one')
  })
})

describe('createVoiceChatService — buffered speech replay', () => {
  it('starts a MediaRecorder during connect when MediaPort supports it', async () => {
    const media = makeMedia({ withRecorder: true })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })

    const rec = media.lastRecorder()
    expect(rec).not.toBeNull()
    expect(rec!.start).toHaveBeenCalled()
  })

  it('replays buffered audio as a text message after the session becomes active', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'what did you mean by gravitas' })
    const session = makeSession({ connectDelayMs: 20 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['fake audio'], { type: 'audio/webm' }))
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    expect(session.sendMessage).toHaveBeenCalledWith('what did you mean by gravitas')
  })

  it('does not call sendMessage when no audio chunks were captured', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'nope' })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).not.toHaveBeenCalled()
    expect(session.sendMessage).not.toHaveBeenCalled()
  })

  it('does not call sendMessage when transcript is empty/whitespace', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: '   ' })
    const session = makeSession({ connectDelayMs: 20 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['x'], { type: 'audio/webm' }))
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    expect(session.sendMessage).not.toHaveBeenCalled()
  })

  it('transcription failure does not fail activation or close the session', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({
      key: 'k',
      transcribeFailWith: new Error('deepgram exploded')
    })
    const session = makeSession({ connectDelayMs: 20 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['x'], { type: 'audio/webm' }))
    await expect(activation).resolves.toBeUndefined()
    await new Promise((r) => setTimeout(r, 0))

    expect(svc.getState()).toBe('active')
    expect(session.sendMessage).not.toHaveBeenCalled()
    expect(session.close).not.toHaveBeenCalled()
  })

  it('feature is skipped silently when MediaPort lacks createMediaRecorder', async () => {
    const media = makeMedia()
    const ipc = makeIpc({ key: 'k', transcript: 'unreachable' })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).not.toHaveBeenCalled()
    expect(session.sendMessage).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')
  })

  it('stops the recorder if activation fails before connect completes', async () => {
    const media = makeMedia({ withRecorder: true })
    const session = makeSession({ connectFailWith: new Error('boom') })
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )

    await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow('boom')

    const rec = media.lastRecorder()
    expect(rec).not.toBeNull()
    expect(rec!.stop).toHaveBeenCalled()
  })

  it('skips the recorder entirely when the feature flag is disabled', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'unreachable' })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        media,
        ipc,
        sessionFactory: session.factory,
        config: makeConfig({ bufferedSpeechReplayEnabled: false })
      })
    )

    await svc.activate(1, { pageText: 'p' })

    expect(media.createMediaRecorder).not.toHaveBeenCalled()
    expect(media.lastRecorder()).toBeNull()
    expect(ipc.transcribeAudio).not.toHaveBeenCalled()
    expect(session.sendMessage).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')
  })

  it('activation succeeds when createMediaRecorder throws on construction', async () => {
    const media = makeMedia({ withRecorder: true, recorderConstructThrows: true })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )

    await svc.activate(1, { pageText: 'p' })

    expect(media.lastRecorder()).toBeNull()
    expect(session.sendMessage).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')
  })

  it('activation succeeds when recorder.stop() throws during replay', async () => {
    const media = makeMedia({ withRecorder: true, recorderStopThrows: true })
    const ipc = makeIpc({ key: 'k', transcript: 'should not be called' })
    const session = makeSession({ connectDelayMs: 20 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['x'], { type: 'audio/webm' }))
    await expect(activation).resolves.toBeUndefined()

    expect(svc.getState()).toBe('active')
    expect(session.close).not.toHaveBeenCalled()
  })

  it('captures chunks that arrive between stop() and onstop', async () => {
    const media = makeMedia({ withRecorder: true, deferOnstop: true })
    const ipc = makeIpc({ key: 'k', transcript: 'late audio captured' })
    const session = makeSession({ connectDelayMs: 20 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    const rec = media.lastRecorder()!
    rec.emitChunk(new Blob(['early'], { type: 'audio/webm' }))
    await new Promise((r) => setTimeout(r, 30))
    rec.emitChunk(new Blob(['late'], { type: 'audio/webm' }))
    rec.fireOnstop()
    await activation

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    const sentBlob = ipc.transcribeAudio.mock.calls[0][0] as Blob
    expect(sentBlob.size).toBeGreaterThanOrEqual('earlylate'.length)
    expect(session.sendMessage).toHaveBeenCalledWith('late audio captured')
  })

  it('drops oldest chunks once the rolling buffer cap is exceeded', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'capped' })
    const session = makeSession({ connectDelayMs: 30 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    const rec = media.lastRecorder()!
    for (let i = 0; i < 20; i++) {
      rec.emitChunk(new Blob([String.fromCharCode(0x30 + i)], { type: 'audio/webm' }))
    }
    await activation

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    const sentBlob = ipc.transcribeAudio.mock.calls[0][0] as Blob
    expect(sentBlob.size).toBe(16)
  })

  it('each cold-path activation gets its own buffer (no leak across runs)', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'fresh-text' })
    const session = makeSession({ connectDelayMs: 15 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory })
    )

    const first = svc.activate(1, { pageText: 'p1' })
    await new Promise((r) => setTimeout(r, 0))
    const firstRec = media.lastRecorder()!
    firstRec.emitChunk(new Blob(['first-chunk'], { type: 'audio/webm' }))
    await first
    const firstTranscribeCalls = ipc.transcribeAudio.mock.calls.length

    const second = svc.activate(2, { pageText: 'p2' })
    await new Promise((r) => setTimeout(r, 0))
    const secondRec = media.lastRecorder()!
    expect(secondRec).not.toBe(firstRec)
    secondRec.emitChunk(new Blob(['second-chunk'], { type: 'audio/webm' }))
    await second

    expect(ipc.transcribeAudio.mock.calls.length).toBe(firstTranscribeCalls + 1)
    const secondBlob = ipc.transcribeAudio.mock.calls.at(-1)![0] as Blob
    expect(secondBlob.size).toBe('second-chunk'.length)
  })

  it('deactivate during in-flight cold path stops the recorder via finalizer', async () => {
    const media = makeMedia({ withRecorder: true })
    const session = makeSession({ connectDelayMs: 100 })
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )

    const activatePromise = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 10))
    expect(svc.getState()).toBe('connecting')
    const rec = media.lastRecorder()!
    expect(rec.start).toHaveBeenCalled()

    svc.deactivate()
    await activatePromise.catch(() => undefined)

    expect(rec.stop).toHaveBeenCalled()
    expect(svc.getState()).toBe('idle')
  })
})

describe('createVoiceChatService — VAD gating', () => {
  it('user never spoke during connect: no transcribe, no sendMessage, mic opens silent', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'unreachable' })
    const session = makeSession({ connectDelayMs: 20 })
    const { port: vadPort, vad } = makeVad({ initialEverSpoke: false })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory, vad: vadPort })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(vad!.everSpoke()).toBe(false)
    expect(ipc.transcribeAudio).not.toHaveBeenCalled()
    expect(session.sendMessage).not.toHaveBeenCalled()
    expect(session.mute).toHaveBeenCalledWith(false)
    expect(svc.getState()).toBe('active')
  })

  it('user spoke then stopped BEFORE connect resolves: transcript injected, mic opens after', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'where does the chapter pivot' })
    const session = makeSession({ connectDelayMs: 30 })
    const { port: vadPort } = makeVad({ initialEverSpoke: true, initiallySpeaking: false })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory, vad: vadPort })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['fake-audio'], { type: 'audio/webm' }))
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    expect(session.sendMessage).toHaveBeenCalledWith('where does the chapter pivot')

    const sendOrder = session.sendMessage.mock.invocationCallOrder[0]!
    const muteOrder = session.mute.mock.invocationCallOrder.find(
      (n) => session.mute.mock.calls[session.mute.mock.invocationCallOrder.indexOf(n)]?.[0] === false
    )
    expect(sendOrder).toBeLessThan(muteOrder!)
  })

  it('user still speaking when connect resolves: mute(false) is gated on emitSpeechEnd', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'and what about this passage' })
    const session = makeSession({ connectDelayMs: 10 })
    const { port: vadPort, vad } = makeVad({
      initialEverSpoke: true,
      initiallySpeaking: true
    })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory, vad: vadPort })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['mid-sentence'], { type: 'audio/webm' }))

    await new Promise((r) => setTimeout(r, 50))
    expect(vad!.hasPendingWait()).toBe(true)
    expect(session.mute).not.toHaveBeenCalledWith(false)
    expect(session.sendMessage).not.toHaveBeenCalled()

    vad!.emitSpeechEnd()
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    expect(session.sendMessage).toHaveBeenCalledWith('and what about this passage')
    expect(session.mute).toHaveBeenCalledWith(false)
  })

  it('VAD safety timeout: activation completes even if emitSpeechEnd never fires', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'partial utterance' })
    const session = makeSession({ connectDelayMs: 5 })
    const { port: vadPort } = makeVad({
      initialEverSpoke: true,
      initiallySpeaking: true
    })
    const config = makeConfig({ connectTimeoutMs: 50 })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory, vad: vadPort, config })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['partial'], { type: 'audio/webm' }))

    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalled()
    expect(session.mute).toHaveBeenCalledWith(false)
    expect(svc.getState()).toBe('active')
  })

  it('VadPort returning null degrades to current behavior (no VAD gate)', async () => {
    const media = makeMedia({ withRecorder: true })
    const ipc = makeIpc({ key: 'k', transcript: 'a clear sentence' })
    const session = makeSession({ connectDelayMs: 10 })
    const { port: vadPort } = makeVad({ unavailable: true })
    const svc = createVoiceChatService(
      makeDeps({ media, ipc, sessionFactory: session.factory, vad: vadPort })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 0))
    media.lastRecorder()!.emitChunk(new Blob(['x'], { type: 'audio/webm' }))
    await activation
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.transcribeAudio).toHaveBeenCalledTimes(1)
    expect(session.sendMessage).toHaveBeenCalledWith('a clear sentence')
    expect(session.mute).toHaveBeenCalledWith(false)
  })

  it('deactivate during a pending VAD wait does not stall the fiber', async () => {
    const media = makeMedia({ withRecorder: true })
    const session = makeSession({ connectDelayMs: 5 })
    const { port: vadPort, vad } = makeVad({
      initialEverSpoke: true,
      initiallySpeaking: true
    })
    const config = makeConfig({ connectTimeoutMs: 60_000 })
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory, vad: vadPort, config })
    )

    const activation = svc.activate(1, { pageText: 'p' })
    await new Promise((r) => setTimeout(r, 20))
    expect(vad!.hasPendingWait()).toBe(true)

    const before = Date.now()
    svc.deactivate()
    await activation.catch(() => undefined)
    const elapsed = Date.now() - before

    expect(elapsed).toBeLessThan(1000)
    expect(vad!.disposeCalls()).toBeGreaterThanOrEqual(1)
    expect(svc.getState()).toBe('idle')
  })

  it('VAD is disposed alongside the session', async () => {
    const { port: vadPort, vad } = makeVad({ initialEverSpoke: true })
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, vad: vadPort })
    )

    await svc.activate(1, { pageText: 'p' })
    expect(vad!.disposeCalls()).toBe(0)

    svc.deactivate()
    expect(vad!.disposeCalls()).toBe(1)
  })
})

describe('createVoiceChatService — webrtc send-track gating', () => {
  it('webrtcFactory receives the cloned stream, not the original mic stream', async () => {
    const media = makeMedia()
    const webrtc = makeWebrtc()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({
        media,
        webrtcFactory: webrtc.factory,
        sessionFactory: session.factory
      })
    )

    await svc.activate(1, { pageText: 'p' })

    const args = webrtc.lastArgs()
    expect(args).not.toBeNull()
    const cloned = media.lastWebrtcClone()
    expect(cloned).not.toBeNull()
    expect(args!.mediaStream).toBe(cloned)
    expect(args!.mediaStream).not.toBe(media.stream)
  })

  it('cloneStreamForWebrtcSend is called exactly once per cold-path activation', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' })

    expect(media.cloneStreamForWebrtcSend).toHaveBeenCalledTimes(1)
    expect(media.cloneStreamForWebrtcSend).toHaveBeenCalledWith(media.stream)
  })

  it('cloneStreamForWebrtcSend is NOT re-called on warm-path activate (same bookId)', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' })
    await svc.activate(1, { pageText: 'p2' })

    expect(media.cloneStreamForWebrtcSend).toHaveBeenCalledTimes(1)
  })

  it('deactivate stops the cloned stream tracks (mic-indicator hygiene)', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' })
    const stops = media.cloneTrackStops()
    expect(stops.length).toBeGreaterThan(0)
    for (const s of stops) expect(s).not.toHaveBeenCalled()

    svc.deactivate()

    for (const s of stops) expect(s).toHaveBeenCalled()
  })

  it('connect failure stops the cloned stream tracks (no leak on cold-path error)', async () => {
    const media = makeMedia()
    const session = makeSession({ connectFailWith: new Error('boom') })
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' }).catch(() => undefined)

    const stops = media.cloneTrackStops()
    expect(stops.length).toBeGreaterThan(0)
    for (const s of stops) expect(s).toHaveBeenCalled()
  })

  it('reactivate with different bookId re-clones the new mic stream', async () => {
    const media = makeMedia()
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    await svc.activate(1, { pageText: 'p' })
    await svc.activate(2, { pageText: 'q' })

    expect(media.cloneStreamForWebrtcSend).toHaveBeenCalledTimes(2)
  })
})

describe('createVoiceChatService — serverVad wiring', () => {
  it('passes serverVad config to sessionFactory on cold activate', async () => {
    let captured: SessionFactoryOpts | null = null
    const baseFactory = makeSession().factory
    const sessionFactory: VoiceChatServiceDeps['sessionFactory'] = (agent, opts) => {
      captured = opts
      return baseFactory(agent, opts)
    }
    const config = makeConfig({
      serverVad: { threshold: 0.65, silenceDurationMs: 800, prefixPaddingMs: 250 }
    })
    const svc = createVoiceChatService(makeDeps({ sessionFactory, config }))

    await svc.activate(1, { pageText: 'p' })

    expect(captured).not.toBeNull()
    expect(captured!.serverVad).toEqual({
      threshold: 0.65,
      silenceDurationMs: 800,
      prefixPaddingMs: 250
    })
  })
})

describe('createVoiceChatService — inspectCurrentPage image injection', () => {
  it('forwards captured images to session.addImage with triggerResponse: false', async () => {
    const agent = makeAgent()
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ agentFactory: agent.factory, sessionFactory: session.factory })
    )
    svc.start()
    await svc.activate(1, { pageText: 'hi' })

    agent.triggerInspectImage({
      dataUrl: 'data:image/webp;base64,XYZ',
      width: 800,
      height: 600,
      bytes: 100
    })

    expect(session.addImage).toHaveBeenCalledWith('data:image/webp;base64,XYZ', {
      triggerResponse: false
    })
  })
})
