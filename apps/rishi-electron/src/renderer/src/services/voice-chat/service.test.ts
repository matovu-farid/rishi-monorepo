import { describe, it, expect, vi } from 'vitest'
import { createVoiceChatService } from './service'
import { OfflineError as OfflineErrorImport } from './types'
import type {
  AgentFactoryArgs,
  AudioElementLike,
  ChatStatus,
  ClockPort,
  EffectsPort,
  MediaPort,
  MediaStreamLike,
  RealtimeAgentLike,
  RealtimeSessionLike,
  RtcTransportLike,
  SessionFactoryOpts,
  VoiceChatConfig,
  VoiceChatIpc,
  VoiceChatPublicState,
  VoiceChatServiceDeps,
  WebrtcFactoryArgs
} from './types'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'

// =============================================================================
// Test helpers — defined once, reused across every test in this file.
// =============================================================================

export function makeRag(): RagService {
  return {
    searchSemantic: vi.fn().mockResolvedValue([{ text: 'fake chunk' }]),
    searchKeyword: vi.fn().mockResolvedValue([]),
    hasVectorsForBook: vi.fn().mockResolvedValue(true)
  } as unknown as RagService
}

export function makeConnectivity(
  opts?: { initialOnline?: boolean }
): ConnectivityService & { setOnline(b: boolean): void } {
  let online = opts?.initialOnline ?? true
  const listeners = new Set<(online: boolean) => void>()
  return {
    isOnline: () => online,
    subscribe: (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    start: () => {},
    stop: () => {},
    setOnline(b) {
      if (online === b) return
      online = b
      for (const l of listeners) l(b)
    }
  }
}

export function makeIpc(opts?: { key?: string; failWith?: Error }): VoiceChatIpc {
  return {
    getRealtimeClientSecret: vi.fn().mockImplementation(async () => {
      if (opts?.failWith) throw opts.failWith
      return opts?.key ?? 'test-key'
    })
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
} {
  let lastArgs: AgentFactoryArgs | null = null
  let lastOnEnd: ((reason: string) => void) | null = null
  return {
    factory: (args) => {
      lastArgs = args
      lastOnEnd = args.onEndConversation
      return { _agent: {} } as RealtimeAgentLike
    },
    lastArgs: () => lastArgs,
    triggerEnd: (reason) => lastOnEnd?.(reason)
  }
}

export function makeSession(opts?: {
  connectDelayMs?: number
  connectFailWith?: Error
}): {
  factory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  session: RealtimeSessionLike
  mute: ReturnType<typeof vi.fn>
  interrupt: ReturnType<typeof vi.fn>
  close: ReturnType<typeof vi.fn>
  updateAgent: ReturnType<typeof vi.fn>
  connect: ReturnType<typeof vi.fn>
  fire: (event: string, ...args: unknown[]) => void
  lastConnectOpts: () => { apiKey: string } | null
} {
  const handlers = new Map<string, Set<(...args: unknown[]) => void>>()
  let lastConnectOpts: { apiKey: string } | null = null
  const connect = vi.fn().mockImplementation(async (o: { apiKey: string }) => {
    lastConnectOpts = o
    if (opts?.connectFailWith) throw opts.connectFailWith
    if (opts?.connectDelayMs) {
      await new Promise((r) => setTimeout(r, opts.connectDelayMs))
    }
  })
  const mute = vi.fn()
  const interrupt = vi.fn()
  const close = vi.fn()
  const updateAgent = vi.fn().mockResolvedValue(undefined)
  const session: RealtimeSessionLike = {
    connect,
    mute,
    interrupt,
    close,
    updateAgent,
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
    fire: (ev, ...args) => {
      const set = handlers.get(ev)
      if (!set) return
      for (const l of [...set]) l(...args)
    },
    lastConnectOpts: () => lastConnectOpts
  }
}

export function makeMedia(opts?: { denyMic?: boolean }): MediaPort & {
  stream: MediaStreamLike
  audioElement: AudioElementLike
} {
  const stream: MediaStreamLike = { getTracks: () => [{ stop: vi.fn() }] }
  const audioElement: AudioElementLike = {
    muted: false,
    srcObject: null,
    autoplay: true,
    pause: vi.fn()
  }
  return {
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
    createAudioElement: vi.fn().mockReturnValue(audioElement)
  }
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
    idleTimeoutMs: 15 * 60 * 1000,
    connectTimeoutMs: 60 * 1000,
    keyTtlMs: 9 * 60 * 1000,
    ...overrides
  }
}

export function makeDeps(
  overrides?: Partial<VoiceChatServiceDeps>
): VoiceChatServiceDeps {
  return {
    rag: makeRag(),
    connectivity: makeConnectivity(),
    ipc: makeIpc(),
    webrtcFactory: makeWebrtc().factory,
    agentFactory: makeAgent().factory,
    sessionFactory: makeSession().factory,
    media: makeMedia(),
    effects: makeEffects(),
    clock: makeClock(),
    config: makeConfig(),
    ...overrides
  }
}

// =============================================================================
// Tests — start/stop lifecycle.
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
    svc.stop() // no throw

    // After stop(), a connectivity transition does not affect state.
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

  // Multi-subscriber + offline transition assertions land in Task 10
  // (connectivity wiring). Edge-detection is sufficient here.
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
    expect(media.getUserMedia).toHaveBeenCalledWith({ audio: true })
    expect(webrtc.callCount()).toBe(1)
    expect(agent.lastArgs()?.bookId).toBe(7)
    expect(agent.lastArgs()?.pageText).toBe('hello')
    expect(session.connect).toHaveBeenCalledWith({ apiKey: 'EPHEMERAL' })
    expect(session.mute).toHaveBeenCalledWith(false)
    expect(svc.getState()).toBe('active')
  })

  it('deactivate() from active → paused; session.interrupt + mute(true)', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.deactivate()

    expect(session.interrupt).toHaveBeenCalledTimes(1)
    expect(session.mute).toHaveBeenLastCalledWith(true)
    expect(svc.getState()).toBe('paused')
  })

  it('dispose() from active → idle; session.close() called', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('chatStatus fires connecting → idle around a cold activate', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
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
    const svc = createVoiceChatService(
      makeDeps({ media, sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'a' })
    expect(media.getUserMedia).toHaveBeenCalledTimes(1)

    await svc.activate(1, { pageText: 'b' })

    expect(session.updateAgent).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).toHaveBeenCalledTimes(1) // not called again
  })

  it('warm activate skips updateAgent when ctx fingerprint is unchanged', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'same' })
    await svc.activate(1, { pageText: 'same' })

    expect(session.updateAgent).not.toHaveBeenCalled()
  })

  it('activate on different bookId disposes the old session first', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'a' })
    await svc.activate(2, { pageText: 'b' })

    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('active')
  })

  it('concurrent activate calls share the in-flight promise', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    const [p1, p2] = [svc.activate(7, { pageText: 'p' }), svc.activate(7, { pageText: 'p' })]
    await Promise.all([p1, p2])

    expect(session.connect).toHaveBeenCalledTimes(1)
  })

  it('preconnect is no-op when hasUsedVoiceInSession is false', async () => {
    const session = makeSession()
    const ipc = makeIpc()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory, ipc })
    )
    await svc.preconnect(1, { pageText: 'p' })

    expect(session.connect).not.toHaveBeenCalled()
    expect(ipc.getRealtimeClientSecret).not.toHaveBeenCalled()
  })

  it('preconnect after a real activate connects + mutes (paused)', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    await svc.preconnect(1, { pageText: 'p' })

    // Two cold connects total: the user-initiated one and the preconnect.
    expect(session.connect).toHaveBeenCalledTimes(2)
    expect(session.mute).toHaveBeenLastCalledWith(true)
    expect(svc.getState()).toBe('paused')
  })

  it('prewarmKey() fetches the ephemeral key without prompting for mic', async () => {
    const ipc = makeIpc({ key: 'PREWARM' })
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ ipc, media }))

    svc.prewarmKey()
    await new Promise((r) => setTimeout(r, 0))

    expect(ipc.getRealtimeClientSecret).toHaveBeenCalledTimes(1)
    expect(media.getUserMedia).not.toHaveBeenCalled()
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
    const svc = createVoiceChatService(
      makeDeps({ sessionFactory: session.factory })
    )

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
