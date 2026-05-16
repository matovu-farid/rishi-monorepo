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

export function makeConnectivity(opts?: {
  initialOnline?: boolean
}): ConnectivityService & { setOnline(b: boolean): void } {
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
    getRealtimeClientSecret: vi.fn().mockImplementation(async (_language: string) => {
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

export function makeSession(opts?: { connectDelayMs?: number; connectFailWith?: Error }): {
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
      await new Promise((r) => {
        setTimeout(r, opts.connectDelayMs)
      })
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
    inactivityTimeoutMs: 3 * 60 * 1000,
    connectTimeoutMs: 60 * 1000,
    keyTtlMs: 9 * 60 * 1000,
    ...overrides
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
    effects: makeEffects(),
    clock: makeClock(),
    config: makeConfig(),
    getLanguage: () => 'en',
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
    // Audio constraints request echo cancellation + noise suppression so TTS
    // playback doesn't bleed from speakers into the mic and get re-sent
    // through the realtime API as billable audio input.
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
    // Reviewer-found race: if the user taps "stop chat" while activate() is
    // still connecting (cold path), the Effect fiber resolves, writes a live
    // session into the service closure, and nothing closes it. Verify the
    // fiber is interrupted so the acquireRelease finalizers tear everything
    // down. After the race, no live session should remain.
    const stopSpy = vi.fn()
    const media = makeMedia()
    media.stream.getTracks = () => [{ stop: stopSpy }]
    const session = makeSession({ connectDelayMs: 50 })
    const svc = createVoiceChatService(makeDeps({ media, sessionFactory: session.factory }))

    const activatePromise = svc.activate(1, { pageText: 'p' })
    // Yield once so the cold-path fiber starts and acquireRelease runs the
    // mic + audio-element + session-build steps before connect's delay.
    await new Promise((r) => {
      setTimeout(r, 10)
    })
    expect(svc.getState()).toBe('connecting')

    svc.deactivate()

    // The activate() promise resolves or rejects (likely rejects with the
    // synthetic interrupt) — either way, no live session should remain.
    await activatePromise.catch(() => undefined)

    // The acquireRelease finalizers stop the mic track and close the session.
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
    expect(media.getUserMedia).toHaveBeenCalledTimes(1) // not called again
  })

  it('warm activate skips updateAgent when ctx fingerprint is unchanged', async () => {
    const session = makeSession()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory }))
    await svc.activate(1, { pageText: 'same' })
    await svc.activate(1, { pageText: 'same' })

    expect(session.updateAgent).not.toHaveBeenCalled()
  })

  it('warm activate does NOT call updateAgent when only activeParagraphText changes', async () => {
    // activeParagraphText ticks on every TTS paragraph advance. Including it
    // in the fingerprint causes session.updateAgent to re-upload the full
    // multi-KB instructions block as input tokens once per paragraph — the
    // primary cause of the May 2026 realtime-token cost spike.
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

  it('preconnect never opens a session — always a no-op', async () => {
    const session = makeSession()
    const ipc = makeIpc()
    const media = makeMedia()
    const svc = createVoiceChatService(makeDeps({ sessionFactory: session.factory, ipc, media }))

    // Even after a prior activate (which would have set hasUsedVoiceInSession),
    // preconnect must not open a billable realtime session.
    await svc.activate(1, { pageText: 'p' })
    svc.dispose()

    const connectCallsBefore = session.connect.mock.calls.length
    const mediaCallsBefore = (media.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length
    const keyCallsBefore = (ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>).mock.calls
      .length

    await svc.preconnect(1, { pageText: 'p' })

    expect(session.connect.mock.calls.length).toBe(connectCallsBefore)
    expect((media.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length).toBe(
      mediaCallsBefore
    )
    expect((ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>).mock.calls.length).toBe(
      keyCallsBefore
    )
    expect(svc.getState()).toBe('idle')
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
    const callsAfterFirstActivate = (
      ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>
    ).mock.calls.length
    svc.deactivate()

    // Without invalidate, the key cache (TTL 9min) would skip the second fetch.
    svc.invalidateKey()

    await svc.activate(1, { pageText: 'p' })
    const callsAfterSecondActivate = (
      ipc.getRealtimeClientSecret as ReturnType<typeof vi.fn>
    ).mock.calls.length

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
    // Synchronously enter offline via failed activate.
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

    // Advance to T+2m (under the 3m limit), then simulate agent activity.
    clock.tick(2 * 60 * 1000)
    session.fire('audio_start')
    // Advance another 2m — without reset this is T+4m (would have fired).
    // With reset, only 2m has passed since last activity. No close.
    clock.tick(2 * 60 * 1000)

    expect(session.close).not.toHaveBeenCalled()
    expect(svc.getState()).toBe('active')

    // Advance one more minute (total 3m of inactivity since the reset) — now close.
    clock.tick(1 * 60 * 1000)
    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })

  it('inactivity timeout fires onEndedByAgent listeners so consumers can reset UI state', async () => {
    // Without this, chatStore.isChatting stays true after the timer fires:
    // session is closed and billing stops (correct) but the chat overlay
    // stays open because chatStore only resets isChatting on onEndedByAgent.
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
    // agent_tool_start/end fire during RAG lookups. A tool call that takes
    // longer than inactivityTimeoutMs would otherwise auto-close the session
    // even though the agent is actively working.
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

    // Total fake time elapsed: 6m. With resets at +2m and +4m, no 3m window
    // ever expires. Session must still be open.
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

    // Timer would have fired at T+3m; if not cleared, it would call close on a
    // null session — guarded — but state would flip out of idle.
    expect(session.close).toHaveBeenCalledTimes(1)
    expect(svc.getState()).toBe('idle')
  })
})

describe('createVoiceChatService — RAG passthrough + onEndedByAgent', () => {
  it('passes the injected RagService through agentFactory', async () => {
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
