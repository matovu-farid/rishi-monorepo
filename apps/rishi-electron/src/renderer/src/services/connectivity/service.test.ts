import { describe, it, expect, vi } from 'vitest'
import { createConnectivityService } from './service'
import type { ConnectivitySource } from './types'

/**
 * In-memory ConnectivitySource. Exposes `goOnline()` / `goOffline()` /
 * `setOnLine()` / `listenerCount()` test helpers. ~40 LOC, no jsdom.
 */
export function makeFakeSource(opts?: { initialOnline?: boolean }): ConnectivitySource & {
  goOnline(): void
  goOffline(): void
  setOnLine(value: boolean): void
  listenerCount(type: 'online' | 'offline'): number
} {
  let online = opts?.initialOnline ?? true
  const map = new Map<'online' | 'offline', Set<() => void>>([
    ['online', new Set()],
    ['offline', new Set()]
  ])
  return {
    get onLine() {
      return online
    },
    addEventListener(type, listener) {
      map.get(type)!.add(listener)
    },
    removeEventListener(type, listener) {
      map.get(type)!.delete(listener)
    },
    goOnline() {
      if (online) return
      online = true
      for (const l of [...(map.get('online') ?? [])]) l()
    },
    goOffline() {
      if (!online) return
      online = false
      for (const l of [...(map.get('offline') ?? [])]) l()
    },
    setOnLine(value) {
      online = value
    },
    listenerCount(type) {
      return map.get(type)?.size ?? 0
    }
  }
}

describe('ConnectivityService.isOnline', () => {
  it('returns source.onLine before start()', () => {
    const onlineSource = makeFakeSource({ initialOnline: true })
    const offlineSource = makeFakeSource({ initialOnline: false })

    expect(createConnectivityService({ source: onlineSource }).isOnline()).toBe(true)
    expect(createConnectivityService({ source: offlineSource }).isOnline()).toBe(false)
  })

  it('returns source.onLine after start()', () => {
    const source = makeFakeSource({ initialOnline: false })
    const service = createConnectivityService({ source })
    service.start()
    expect(service.isOnline()).toBe(false)
  })
})

describe('ConnectivityService.start', () => {
  it('is idempotent — calling start() twice registers source listeners exactly once', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })

    service.start()
    service.start()

    expect(source.listenerCount('online')).toBe(1)
    expect(source.listenerCount('offline')).toBe(1)
  })
})

describe('ConnectivityService.subscribe', () => {
  it('fires listeners with false on online → offline transition', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOffline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
    expect(service.isOnline()).toBe(false)
  })

  it('fires listeners with true on offline → online transition', () => {
    const source = makeFakeSource({ initialOnline: false })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOnline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(true)
    expect(service.isOnline()).toBe(true)
  })

  it('edge-detects duplicate offline events (no double fire)', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    source.goOffline()
    // The fake's goOffline() is a no-op when already offline; this exercises
    // the actor's no-op-transition path. The service's edge-detector also
    // guards against any duplicate that does propagate from the actor.
    source.goOffline()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith(false)
  })

  it('unsubscribe stops invocations; multiple subscribers each receive notifications', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const a = vi.fn()
    const b = vi.fn()
    service.start()
    const unsubA = service.subscribe(a)
    service.subscribe(b)

    source.goOffline()
    expect(a).toHaveBeenCalledTimes(1)
    expect(a).toHaveBeenCalledWith(false)
    expect(b).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledWith(false)

    unsubA()
    source.goOnline()
    expect(a).toHaveBeenCalledTimes(1) // unchanged
    expect(b).toHaveBeenCalledTimes(2)
    expect(b).toHaveBeenLastCalledWith(true)
  })
})

describe('ConnectivityService.stop', () => {
  it('removes source listeners; subsequent transitions do not fire subscribers', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })
    const spy = vi.fn()
    service.start()
    service.subscribe(spy)

    expect(source.listenerCount('online')).toBe(1)
    expect(source.listenerCount('offline')).toBe(1)

    service.stop()
    expect(source.listenerCount('online')).toBe(0)
    expect(source.listenerCount('offline')).toBe(0)

    source.goOffline()
    expect(spy).not.toHaveBeenCalled()
  })

  it('is idempotent — calling stop() twice is a no-op', () => {
    const source = makeFakeSource({ initialOnline: true })
    const service = createConnectivityService({ source })

    service.start()
    service.stop()
    service.stop() // no throw

    expect(source.listenerCount('online')).toBe(0)
    expect(source.listenerCount('offline')).toBe(0)
  })
})
