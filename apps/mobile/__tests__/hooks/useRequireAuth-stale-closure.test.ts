/**
 * CHT-008 / #58 — `useRequireAuth` must read auth state on each replay, not
 * via the closure snapshot.
 *
 * Pre-fix, the returned gate function captured `isAuthenticated` at hook
 * call time. If the store flipped between hook construction and gate
 * invocation (e.g. the user signed in via another surface, then tapped
 * the still-mounted gated control before the consuming component
 * re-rendered), the gate would observe the stale snapshot.
 *
 * Red signal: prime the mock store as signed-OUT, render the harness,
 * grab the returned gate, flip the store to signed-IN *without
 * re-rendering*, then call the gate. The action MUST run, NOT the gate.
 */

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

// authStore mock — exposes a mutable state object, a getState() that
// returns the LIVE object, and a selector-based useAuthStore. The hook
// MUST read `isAuthenticated` via getState() at invocation time for the
// fix to land — selectors alone would still capture the snapshot value
// because the hook's returned callback closes over the slice value.
const openPremiumGate = jest.fn()
const storeState: {
  isAuthenticated: boolean
  authHydrated: boolean
  openPremiumGate: typeof openPremiumGate
} = {
  isAuthenticated: false,
  authHydrated: true,
  openPremiumGate,
}

jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: Object.assign(
    <T,>(selector: (s: typeof storeState) => T) => selector(storeState),
    {
      getState: () => storeState,
    },
  ),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { useRequireAuth } from '@/components/auth/useRequireAuth'

function Harness(props: { onReady: (gate: (action: () => void) => void) => void }) {
  const gate = useRequireAuth('ai-chat')
  React.useEffect(() => {
    props.onReady(gate)
  })
  return null
}

beforeEach(() => {
  openPremiumGate.mockClear()
  storeState.isAuthenticated = false
  storeState.authHydrated = true
})

describe('CHT-008 — useRequireAuth resists stale closure capture (#58)', () => {
  it('reads CURRENT auth state on each gate invocation, not the snapshot at hook time', () => {
    // Prime: render with isAuthenticated=false. The hook's returned gate
    // is captured before the store flips. Pre-fix, this gate would treat
    // the user as signed-out forever.
    let gate!: (a: () => void) => void
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })

    // Flip the store WITHOUT re-rendering the harness. The hook is still
    // mounted with its (stale) closure values from the previous render.
    storeState.isAuthenticated = true

    const action = jest.fn()
    act(() => {
      gate(action)
    })

    // Post-fix: gate observes the live store, runs the action.
    expect(action).toHaveBeenCalledTimes(1)
    expect(openPremiumGate).not.toHaveBeenCalled()
  })

  it('still opens the gate when the live store is signed-OUT (parity with existing tests)', () => {
    let gate!: (a: () => void) => void
    // Hook constructed while signed-in — old closure would let any action
    // through forever. Post-fix, flipping the store to signed-out below
    // must cause the gate to open instead of running the action.
    storeState.isAuthenticated = true
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })

    storeState.isAuthenticated = false

    const action = jest.fn()
    act(() => {
      gate(action)
    })

    expect(action).not.toHaveBeenCalled()
    expect(openPremiumGate).toHaveBeenCalledTimes(1)
    expect(openPremiumGate).toHaveBeenCalledWith('ai-chat', action)
  })
})
