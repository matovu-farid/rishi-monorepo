import { describe, it, expect, vi } from 'vitest'
import { createSyncService } from './service'
import type {
  ConnectivityPort,
  EngineFactory,
  EngineLike,
  SyncConfig,
  SyncServiceDeps,
  WindowEventsPort
} from './types'
import { makeIpc } from './adapter.test'
import { makeClock } from './debounce.test'

/**
 * Build an engine factory that returns a controllable `{ sync }`. The
 * caller can pass `syncImpl` to override the default no-op resolution.
 */
export function makeEngine(opts?: { syncImpl?: () => Promise<void> }): {
  engineFactory: EngineFactory
  engine: EngineLike
  syncCount: () => number
} {
  let count = 0
  const sync = vi.fn(async () => {
    count++
    if (opts?.syncImpl) return opts.syncImpl()
  })
  const engine: EngineLike = { sync }
  const engineFactory: EngineFactory = vi.fn(() => engine)
  return { engineFactory, engine, syncCount: () => count }
}

export function makeConnectivity(opts?: {
  initialOnline?: boolean
}): ConnectivityPort & { setOnline(b: boolean): void } {
  let online = opts?.initialOnline ?? true
  const listeners = new Set<(b: boolean) => void>()
  return {
    isOnline: () => online,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    setOnline(b) {
      if (b === online) return
      online = b
      for (const l of [...listeners]) l(b)
    }
  }
}

export const makeAuthToken = (token: string | null = 'test-bearer') => vi.fn(async () => token)

export const makeDevBypass = (secret: string | null = null) => vi.fn(async () => secret)

export function makeWindowEvents(): WindowEventsPort & {
  fire(type: string, event?: Event): void
  listeners(type: string): EventListener[]
} {
  const map = new Map<string, Set<EventListener>>()
  const dispatched: Event[] = []
  return {
    addEventListener(type, listener) {
      if (!map.has(type)) map.set(type, new Set())
      map.get(type)!.add(listener)
    },
    removeEventListener(type, listener) {
      map.get(type)?.delete(listener)
    },
    dispatchEvent(event) {
      dispatched.push(event)
      for (const l of map.get(event.type) ?? []) l(event)
    },
    fire(type, event) {
      for (const l of map.get(type) ?? []) l(event ?? new Event(type))
    },
    listeners(type) {
      return [...(map.get(type) ?? [])]
    }
  }
}

export const baseConfig: SyncConfig = {
  workerUrl: 'https://api.example.com',
  intervalMs: 10_000,
  debounceMs: 100,
  requestTimeoutMs: 30_000
}

/** Build a full deps object with sensible defaults; each test can override. */
export function makeDeps(overrides: Partial<SyncServiceDeps> = {}): SyncServiceDeps {
  const ipc = overrides.ipc ?? makeIpc()
  const { engineFactory } = overrides.engineFactory
    ? { engineFactory: overrides.engineFactory }
    : makeEngine()
  return {
    ipc,
    engineFactory,
    fetch: vi.fn(async () => new Response('{}', { status: 200 })),
    getAuthToken: makeAuthToken(),
    getDevBypassSecret: makeDevBypass(),
    connectivity: makeConnectivity(),
    clock: makeClock(),
    windowEvents: makeWindowEvents(),
    config: baseConfig,
    ...overrides
  }
}

describe('SyncService.start', () => {
  it('kicks an initial sync and transitions not-synced → syncing → synced', async () => {
    const { engineFactory, syncCount } = makeEngine()
    const clock = makeClock()
    const deps = makeDeps({ engineFactory, clock })
    const service = createSyncService(deps)
    const snapshots: string[] = []
    service.onStatusChange((s) => snapshots.push(s.status))

    service.start()
    // Drain microtasks: the initial sync awaits engine.sync().
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(syncCount()).toBe(1)
    expect(snapshots).toEqual(['not-synced', 'syncing', 'synced'])
    expect(service.getStatus().status).toBe('synced')
    expect(service.getStatus().lastSyncAt).toBe(clock.now())
  })
})

describe('SyncService.start idempotency', () => {
  it('second start() is a no-op (engineFactory called once, only one initial sync)', async () => {
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ engineFactory }))

    service.start()
    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(engineFactory).toHaveBeenCalledTimes(1)
    expect(syncCount()).toBe(1)
  })
})

describe('SyncService.stop', () => {
  it('removes focus listener, clears interval, and is idempotent', async () => {
    const clock = makeClock()
    const windowEvents = makeWindowEvents()
    const { engineFactory } = makeEngine()
    const service = createSyncService(makeDeps({ clock, windowEvents, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(windowEvents.listeners('focus').length).toBe(1)
    expect(clock.pendingTimers()).toBeGreaterThan(0)

    service.stop()
    expect(windowEvents.listeners('focus').length).toBe(0)
    expect(clock.pendingTimers()).toBe(0)

    // Second stop() does not throw
    expect(() => service.stop()).not.toThrow()
  })
})

describe('SyncService.triggerWrite', () => {
  it('debounces multiple calls within config.debounceMs into a single sync', async () => {
    const clock = makeClock()
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    }) // let initial sync settle
    expect(syncCount()).toBe(1)

    service.triggerWrite()
    service.triggerWrite()
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs - 1)
    expect(syncCount()).toBe(1)

    clock.tick(1)
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(syncCount()).toBe(2)
  })

  it('is a no-op before start()', async () => {
    const clock = makeClock()
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, engineFactory }))

    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(syncCount()).toBe(0)
  })

  it('is a no-op when connectivity reports offline', async () => {
    const clock = makeClock()
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, connectivity, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    const baseline = syncCount() // 1 from initial sync

    connectivity.setOnline(false)
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(syncCount()).toBe(baseline)
  })
})

describe('SyncService connectivity transitions', () => {
  it('offline transition sets status to offline immediately (no engine call)', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(service.getStatus().status).toBe('synced')
    const baseline = syncCount()

    connectivity.setOnline(false)

    expect(service.getStatus().status).toBe('offline')
    expect(syncCount()).toBe(baseline) // no new engine call
  })

  it('online recovery from offline kicks a sync', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))
    const snapshots: string[] = []
    service.onStatusChange((s) => snapshots.push(s.status))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    connectivity.setOnline(false)
    expect(service.getStatus().status).toBe('offline')

    connectivity.setOnline(true)
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(syncCount()).toBe(2) // initial + online-recovery
    expect(snapshots).toContain('offline')
    expect(snapshots[snapshots.length - 1]).toBe('synced')
  })
})

describe('SyncService error classification', () => {
  it('engine error with connectivity online classifies as error', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        throw new Error('boom')
      }
    })
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(service.getStatus().status).toBe('error')
  })

  it('engine error with connectivity offline classifies as offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        connectivity.setOnline(false) // model: network died mid-flight
        throw new Error('network down')
      }
    })
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(service.getStatus().status).toBe('offline')
  })

  it('AUTH_EXPIRED dispatches sync-auth-expired event and sets status to error', async () => {
    const windowEvents = makeWindowEvents()
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        throw new Error('AUTH_EXPIRED')
      }
    })
    const service = createSyncService(makeDeps({ windowEvents, engineFactory }))

    const dispatched: Event[] = []
    windowEvents.addEventListener('sync-auth-expired', (e) => dispatched.push(e))

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    expect(dispatched).toHaveLength(1)
    expect(dispatched[0].type).toBe('sync-auth-expired')
    expect(service.getStatus().status).toBe('error')
  })
})

describe('SyncService.onStatusChange', () => {
  it('invokes the listener immediately on subscribe and again on every transition; unsubscribe stops delivery', async () => {
    const { engineFactory } = makeEngine()
    const service = createSyncService(makeDeps({ engineFactory }))
    const calls: string[] = []
    const unsub = service.onStatusChange((s) => calls.push(s.status))

    expect(calls).toEqual(['not-synced']) // immediate

    service.start()
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(calls).toEqual(['not-synced', 'syncing', 'synced'])

    unsub()
    service.stop()
    service.start() // restart should fire more events but listener should be gone
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(calls).toEqual(['not-synced', 'syncing', 'synced']) // unchanged
  })

  it('suppresses status updates after stop() even if a sync is mid-flight', async () => {
    let resolveSync: () => void = () => {}
    const blocker = new Promise<void>((r) => {
      resolveSync = r
    })
    const { engineFactory } = makeEngine({ syncImpl: () => blocker })
    const service = createSyncService(makeDeps({ engineFactory }))
    const calls: string[] = []
    service.onStatusChange((s) => calls.push(s.status))

    service.start() // status → syncing, awaits engine.sync
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(calls).toContain('syncing')
    expect(calls).not.toContain('synced')

    service.stop()
    resolveSync()
    await new Promise((r) => {
      setTimeout(r, 0)
    })

    // No 'synced' or 'error' snapshot should have been emitted after stop()
    expect(calls).not.toContain('synced')
    expect(calls).not.toContain('error')
  })
})

describe('SyncService apiFetch (passed into engineFactory)', () => {
  it('builds an apiFetch that retries 401 once with a fresh bearer token', async () => {
    // We intercept the apiFetch by capturing the value passed to engineFactory.
    let capturedApiFetch: ((path: string, init?: RequestInit) => Promise<Response>) | null = null
    const engineFactory: EngineFactory = (cfg) => {
      capturedApiFetch = cfg.apiFetch
      return { sync: async () => {} }
    }

    let tokenCalls = 0
    const tokens = ['stale-token', 'fresh-token']
    const getAuthToken = vi.fn(async () => tokens[tokenCalls++] ?? 'fresh-token')

    const fetch = vi.fn(async (_url: string, init?: RequestInit) => {
      const headers = (init?.headers ?? {}) as Record<string, string>
      const auth = headers['Authorization']
      if (auth === 'Bearer stale-token') return new Response('', { status: 401 })
      return new Response('{"ok":true}', { status: 200 })
    })

    const service = createSyncService(makeDeps({ engineFactory, getAuthToken, fetch }))
    service.start()

    expect(capturedApiFetch).not.toBeNull()
    const res = await capturedApiFetch!('/sync/push', { method: 'POST' })

    expect(res.status).toBe(200)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(getAuthToken).toHaveBeenCalledTimes(2)
  })

  it('falls back to X-Dev-Bypass header when no auth token is available', async () => {
    let capturedApiFetch: ((path: string, init?: RequestInit) => Promise<Response>) | null = null
    const engineFactory: EngineFactory = (cfg) => {
      capturedApiFetch = cfg.apiFetch
      return { sync: async () => {} }
    }

    const fetch = vi.fn(
      async (_url: string, init?: RequestInit) =>
        new Response(JSON.stringify({ headers: init?.headers }), { status: 200 })
    )

    const service = createSyncService(
      makeDeps({
        engineFactory,
        getAuthToken: makeAuthToken(null),
        getDevBypassSecret: makeDevBypass('s3cret'),
        fetch
      })
    )
    service.start()

    await capturedApiFetch!('/sync/pull')
    const sentHeaders = fetch.mock.calls[0][1]?.headers as Record<string, string>
    expect(sentHeaders['X-Dev-Bypass']).toBe('s3cret')
    expect(sentHeaders['Authorization']).toBeUndefined()
  })
})
