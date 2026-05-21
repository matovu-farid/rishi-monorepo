/**
 * Tests for MobileConnectivityPort — the NetInfo → xstate adapter that
 * implements the shared `ConnectivityPort` interface from
 * `@rishi/shared/connectivity/types`.
 *
 * We mock `@react-native-community/netinfo` and drive the machine through
 * the port's subscribe callback. The state-value transitions are the
 * same as the standalone machine tests, but routed through the adapter.
 */

type NetInfoState = { isConnected: boolean | null }
type Listener = (state: NetInfoState) => void

const listeners: Listener[] = []
let initialIsConnected: boolean | null = true

const mockAddEventListener = jest.fn((listener: Listener) => {
  listeners.push(listener)
  return () => {
    const i = listeners.indexOf(listener)
    if (i >= 0) listeners.splice(i, 1)
  }
})

const mockFetch = jest.fn(() => Promise.resolve({ isConnected: initialIsConnected }))

jest.mock('@react-native-community/netinfo', () => ({
  __esModule: true,
  default: {
    addEventListener: mockAddEventListener,
    fetch: mockFetch,
  },
  addEventListener: mockAddEventListener,
  fetch: mockFetch,
}))

import { createMobileConnectivityPort } from '@/lib/connectivity/MobileConnectivityPort'

describe('MobileConnectivityPort', () => {
  beforeEach(() => {
    listeners.length = 0
    initialIsConnected = true
    mockAddEventListener.mockClear()
    mockFetch.mockClear()
  })

  it('starts online when NetInfo reports isConnected=true', () => {
    const port = createMobileConnectivityPort()
    port.start()
    expect(port.isOnline()).toBe(true)
    port.stop()
  })

  it('transitions to offline when NetInfo emits isConnected=false', () => {
    const port = createMobileConnectivityPort()
    port.start()
    expect(port.isOnline()).toBe(true)
    listeners.forEach((l) => l({ isConnected: false }))
    expect(port.isOnline()).toBe(false)
    port.stop()
  })

  it('subscribe(...) listener fires on transitions, returns unsubscribe', () => {
    const port = createMobileConnectivityPort()
    port.start()
    const events: boolean[] = []
    const unsub = port.subscribe((online) => events.push(online))

    listeners.forEach((l) => l({ isConnected: false }))
    listeners.forEach((l) => l({ isConnected: true }))
    listeners.forEach((l) => l({ isConnected: true })) // no-op repeat

    expect(events).toEqual([false, true])

    unsub()
    // After unsubscribe, transitions no longer notify.
    listeners.forEach((l) => l({ isConnected: false }))
    expect(events).toEqual([false, true])
    port.stop()
  })

  it('stop() removes the NetInfo subscription and is idempotent', () => {
    const port = createMobileConnectivityPort()
    port.start()
    expect(listeners.length).toBe(1)
    port.stop()
    expect(listeners.length).toBe(0)
    // Idempotent
    expect(() => port.stop()).not.toThrow()
  })

  it('start() is idempotent — calling twice does not double-subscribe', () => {
    const port = createMobileConnectivityPort()
    port.start()
    port.start()
    expect(listeners.length).toBe(1)
    port.stop()
  })

  it('isConnected=null (unknown) is treated as online (last-known) until next event', () => {
    // Per RN docs, isConnected can be null briefly during startup. We
    // intentionally do NOT flip to offline on null; only an explicit `false`
    // counts as offline.
    const port = createMobileConnectivityPort()
    port.start()
    listeners.forEach((l) => l({ isConnected: null }))
    expect(port.isOnline()).toBe(true)
    port.stop()
  })

  it('after stop() then start(), the port re-subscribes with a fresh actor', () => {
    const port = createMobileConnectivityPort()
    port.start()
    listeners.forEach((l) => l({ isConnected: false }))
    expect(port.isOnline()).toBe(false)
    port.stop()
    port.start()
    // Fresh start defaults to online
    expect(port.isOnline()).toBe(true)
    port.stop()
  })
})
