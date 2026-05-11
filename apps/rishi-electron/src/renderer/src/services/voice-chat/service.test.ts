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
