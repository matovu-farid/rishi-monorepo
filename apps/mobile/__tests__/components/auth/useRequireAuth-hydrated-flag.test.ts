/**
 * GAT-105 (#77) — useRequireAuth must expose an `authHydrated` flag so
 * callers can disable / dim premium-feature triggers during cold start.
 *
 * Today the hook silently swallows taps while `!authHydrated`, leaving
 * no UI affordance — premium buttons appear active but do nothing. The
 * fix attaches an `authHydrated` boolean to the callable returned by
 * the hook, mirroring the live store value at render time. Callers
 * (TTS / voice / chat buttons) thread it into their `disabled` prop.
 *
 * The callable remains directly invokable for backward compatibility
 * with existing sites that just call `requireFoo(action)`.
 */

// ── react-native primitives stub ─────────────────────────────────────────────
jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((p: any, r: unknown) =>
      React.createElement('View', { ...p, ref: r }),
    ),
    Text: React.forwardRef((p: any, r: unknown) =>
      React.createElement('Text', { ...p, ref: r }),
    ),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  }),
}))

jest.mock('@/lib/auth', () => ({
  getSessionToken: jest.fn(async () => null),
}))

const openPremiumGate = jest.fn()
let storeState: {
  isAuthenticated: boolean
  authHydrated: boolean
  openPremiumGate: typeof openPremiumGate
} = {
  isAuthenticated: false,
  authHydrated: false,
  openPremiumGate,
}

jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: Object.assign(
    <T,>(selector: (s: typeof storeState) => T) => selector(storeState),
    { getState: () => storeState },
  ),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { useRequireAuth } from '@/components/auth/useRequireAuth'

function Harness(props: {
  onReady: (gate: ReturnType<typeof useRequireAuth>) => void
}) {
  const gate = useRequireAuth('tts')
  React.useEffect(() => {
    props.onReady(gate)
  })
  return null
}

beforeEach(() => {
  openPremiumGate.mockClear()
})

describe('useRequireAuth — authHydrated flag (#77)', () => {
  it('exposes `authHydrated: false` on the returned callable while hydration is pending', () => {
    storeState = {
      isAuthenticated: false,
      authHydrated: false,
      openPremiumGate,
    }
    let gate!: ReturnType<typeof useRequireAuth>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    // The hook's return value is still callable…
    expect(typeof gate).toBe('function')
    // …but advertises its hydration status so callers can disable UI.
    expect(gate.authHydrated).toBe(false)
  })

  it('exposes `authHydrated: true` once the auth store has hydrated', () => {
    storeState = {
      isAuthenticated: true,
      authHydrated: true,
      openPremiumGate,
    }
    let gate!: ReturnType<typeof useRequireAuth>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    expect(gate.authHydrated).toBe(true)
  })

  it('still defers (no-op) when invoked before hydration — UI is expected to disable instead', () => {
    storeState = {
      isAuthenticated: false,
      authHydrated: false,
      openPremiumGate,
    }
    const action = jest.fn()
    let gate!: ReturnType<typeof useRequireAuth>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    act(() => {
      gate(action)
    })
    expect(action).not.toHaveBeenCalled()
    expect(openPremiumGate).not.toHaveBeenCalled()
    expect(gate.authHydrated).toBe(false)
  })
})
