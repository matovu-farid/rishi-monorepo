/**
 * Phase 1 — useRequireAuth hook (mobile).
 *
 * The hook wraps a premium-feature action with the sign-in gate:
 *   - Authenticated user: runs the action immediately, no gate.
 *   - Signed-out user once auth has hydrated: calls openPremiumGate(feature)
 *     and DOES NOT run the action — the user must sign in first.
 *   - Cold start (auth not yet hydrated): the trigger is a NO-OP. Neither
 *     the action nor the gate fires — we wait for auth to hydrate before
 *     deciding (P0-T fix). The previous "optimistic" behavior produced
 *     raw 401s for signed-out users on cold start.
 *
 * The hook is the only consumer of the auth-gating contract in mobile
 * call sites (TTSControls, RealtimeVoiceButton, ChatInput, etc.).
 *
 * We follow the existing mobile test convention (see
 * __tests__/highlights/undo-snackbar.test.tsx):
 *   - Mock react-native primitives to host stubs.
 *   - Use react-test-renderer + a tiny Harness component to exercise
 *     the hook. Avoids pulling in the heavyweight RN preset.
 *
 * The file is intentionally `.test.ts` (not .tsx) — the harness creates
 * its element via React.createElement so the source has no JSX.
 */

// ── react-native primitives stub (Harness renders nothing, but importing
//    @/lib/stores/authStore transitively pulls react-native via mmkv) ────────
jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((p: any, r: unknown) => React.createElement('View', { ...p, ref: r })),
    Text: React.forwardRef((p: any, r: unknown) => React.createElement('Text', { ...p, ref: r })),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

// ── MMKV mock (authStore initializes storage on import) ──────────────────────
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  }),
}))

// ── Auth surface mocks (authStore hydrates from these) ───────────────────────
jest.mock('@/lib/auth', () => ({
  getSessionToken: jest.fn(async () => null),
}))

// ── authStore mock — selector-based to mirror the real Zustand contract ──────
//
// The hook reads slices via selectors. After GAT-011 it also reads
// `user` so it can hand it to the shared `shouldGate` predicate (single
// source of truth). We expose a mutable state object the tests can
// prime per-case.
const openPremiumGate = jest.fn()
type AuthUser = { id: string; email: string | null } | null
let storeState: {
  isAuthenticated: boolean
  authHydrated: boolean
  user: AuthUser
  openPremiumGate: typeof openPremiumGate
} = {
  isAuthenticated: false,
  authHydrated: true,
  user: null,
  openPremiumGate,
}

jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: <T,>(selector: (s: typeof storeState) => T) => selector(storeState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { useRequireAuth } from '@/components/auth/useRequireAuth'

function Harness(props: { onReady: (gate: (action: () => void) => void) => void }) {
  const gate = useRequireAuth('tts')
  React.useEffect(() => {
    props.onReady(gate)
  })
  return null
}

beforeEach(() => {
  openPremiumGate.mockClear()
  storeState = {
    isAuthenticated: false,
    authHydrated: true,
    user: null,
    openPremiumGate,
  }
})

describe('useRequireAuth (mobile)', () => {
  it('runs action immediately when authenticated + hydrated (no gate)', () => {
    storeState = {
      isAuthenticated: true,
      authHydrated: true,
      user: { id: 'u-1', email: null },
      openPremiumGate,
    }
    const action = jest.fn()
    let gate!: (a: () => void) => void
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    act(() => {
      gate(action)
    })
    expect(action).toHaveBeenCalledTimes(1)
    expect(openPremiumGate).not.toHaveBeenCalled()
  })

  it('opens premium gate (and skips action) when signed-out + hydrated', () => {
    storeState = {
      isAuthenticated: false,
      authHydrated: true,
      user: null,
      openPremiumGate,
    }
    const action = jest.fn()
    let gate!: (a: () => void) => void
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    act(() => {
      gate(action)
    })
    expect(action).not.toHaveBeenCalled()
    expect(openPremiumGate).toHaveBeenCalledTimes(1)
    // P0-U: the would-be action is forwarded into openPremiumGate so the
    // store can replay it after sign-in.
    expect(openPremiumGate).toHaveBeenCalledWith('tts', action)
  })

  it('cold-start (auth not yet hydrated) defers: does NOT run action and does NOT open gate (P0-T)', () => {
    storeState = {
      isAuthenticated: false,
      authHydrated: false,
      user: null,
      openPremiumGate,
    }
    const action = jest.fn()
    let gate!: (a: () => void) => void
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
  })

  it('GAT-011: routes the decision through shared shouldGate(user, feature)', () => {
    // We can't easily spy through the module-resolution mock above without
    // unmocking, so instead pin the contract via behaviour:
    //   - `user: null` AND `isAuthenticated: false` → gated.
    //   - `user: { id }` (non-null) wins regardless of an out-of-sync
    //     `isAuthenticated` boolean — the shared predicate uses `user`,
    //     which is the single source of truth across electron + mobile.
    // If `useRequireAuth` ever drifts off shouldGate (e.g. starts
    // trusting only `isAuthenticated`), this test breaks.
    storeState = {
      isAuthenticated: false, // boolean intentionally stale
      authHydrated: true,
      user: { id: 'u-99', email: null },
      openPremiumGate,
    }
    const action = jest.fn()
    let gate!: (a: () => void) => void
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => (gate = g) }),
      )
    })
    act(() => {
      gate(action)
    })
    expect(action).toHaveBeenCalledTimes(1)
    expect(openPremiumGate).not.toHaveBeenCalled()
  })

  it('returns a stable function reference across re-renders when state is unchanged', () => {
    storeState = {
      isAuthenticated: true,
      authHydrated: true,
      user: { id: 'u-1', email: null },
      openPremiumGate,
    }
    const gates: Array<(a: () => void) => void> = []
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        React.createElement(Harness, { onReady: (g) => gates.push(g) }),
      )
    })
    // Force a re-render with the same props.
    act(() => {
      tree.update(
        React.createElement(Harness, { onReady: (g) => gates.push(g) }),
      )
    })
    expect(gates.length).toBeGreaterThanOrEqual(2)
    expect(gates[0]).toBe(gates[gates.length - 1])
  })
})
