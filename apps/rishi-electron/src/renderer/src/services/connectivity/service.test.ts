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
