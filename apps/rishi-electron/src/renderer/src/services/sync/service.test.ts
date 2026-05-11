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
export function makeEngine(opts?: {
  syncImpl?: () => Promise<void>
}): { engineFactory: EngineFactory; engine: EngineLike; syncCount: () => number } {
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

export const makeAuthToken = (token: string | null = 'test-bearer') =>
  vi.fn(async () => token)

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
    await new Promise((r) => setTimeout(r, 0))

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
    await new Promise((r) => setTimeout(r, 0))

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
    await new Promise((r) => setTimeout(r, 0))

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
    await new Promise((r) => setTimeout(r, 0)) // let initial sync settle
    expect(syncCount()).toBe(1)

    service.triggerWrite()
    service.triggerWrite()
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs - 1)
    expect(syncCount()).toBe(1)

    clock.tick(1)
    await new Promise((r) => setTimeout(r, 0))
    expect(syncCount()).toBe(2)
  })

  it('is a no-op before start()', async () => {
    const clock = makeClock()
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, engineFactory }))

    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(0)
  })

  it('is a no-op when connectivity reports offline', async () => {
    const clock = makeClock()
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(
      makeDeps({ clock, connectivity, engineFactory })
    )

    service.start()
    await new Promise((r) => setTimeout(r, 0))
    const baseline = syncCount() // 1 from initial sync

    connectivity.setOnline(false)
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(baseline)
  })
})
