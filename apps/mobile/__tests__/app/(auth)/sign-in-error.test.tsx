/**
 * STA-020 — Sign-in screen previously displayed the raw provider error
 * message (e.g. "Sign-in callback URL is missing the required `state`
 * parameter"). Map known shapes onto user-facing copy before storing on
 * the `error` state.
 *
 * Pinned behaviour:
 *   1. State / PKCE mismatch (and "state parameter missing") → friendly
 *      "Something went wrong with sign-in" copy.
 *   2. Network / fetch failures → "Check your connection and try again."
 *   3. Unknown errors fall back to a generic "Couldn't sign in" message.
 *   4. Cancellations / dismissals are NOT surfaced (existing behaviour
 *      preserved).
 */

// ── Mocks ─────────────────────────────────────────────────────────────
const mockSignIn = jest.fn()
jest.mock('@/lib/auth', () => ({
  signIn: (...args: unknown[]) => mockSignIn(...args),
}))

const mockReplace = jest.fn()
jest.mock('expo-router', () => ({
  __esModule: true,
  useRouter: () => ({ replace: mockReplace, push: jest.fn(), back: jest.fn() }),
}))

jest.mock('react-native-safe-area-context', () => ({
  __esModule: true,
  SafeAreaView: ({ children }: { children: React.ReactNode }) => children,
}))

// Lightweight react-native shim — host strings for primitives so the
// renderer doesn't try to load the real RN runtime.
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    __esModule: true,
    View: mk('View'),
    Text: mk('Text'),
    TouchableOpacity: mk('TouchableOpacity'),
    ActivityIndicator: mk('ActivityIndicator'),
    KeyboardAvoidingView: mk('KeyboardAvoidingView'),
    Platform: { OS: 'ios', select: (s: Record<string, unknown>) => s.ios },
  }
})

// authStore — selector-style: `useAuthStore((s) => s.x)`.
const authState = {
  isAuthenticating: false,
  setAuthenticating: jest.fn((v: boolean) => {
    authState.isAuthenticating = v
  }),
  setSession: jest.fn(),
}
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: (selector: (s: typeof authState) => unknown) =>
    selector(authState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import SignInScreen from '@/app/(auth)/sign-in'

function findError(root: TestRenderer.ReactTestInstance): string | null {
  try {
    const node = root.findByProps({ testID: 'sign-in-error' })
    const children = node.props.children
    return typeof children === 'string' ? children : String(children)
  } catch {
    return null
  }
}

function tap(root: TestRenderer.ReactTestInstance, testID: string): void {
  const node = root.findByProps({ testID })
  const onPress = node.props.onPress as () => void
  onPress()
}

beforeEach(() => {
  mockSignIn.mockReset()
  mockReplace.mockReset()
  authState.isAuthenticating = false
  authState.setAuthenticating.mockClear()
  authState.setSession.mockClear()
})

describe('STA-020 — sign-in maps raw provider error to friendly copy', () => {
  it('state-parameter / PKCE mismatch is shown as a friendly message', async () => {
    mockSignIn.mockRejectedValueOnce(
      new Error(
        'Sign-in callback URL is missing the required `state` parameter',
      ),
    )

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(React.createElement(SignInScreen))
    })

    await act(async () => {
      tap(tree.root, 'google-sign-in-button')
      // Drain microtasks so the promise rejection settles + state updates.
      await Promise.resolve()
      await Promise.resolve()
    })

    const errText = findError(tree.root)
    expect(errText).not.toBeNull()
    expect(errText).not.toMatch(/state parameter/i)
    expect(errText).toMatch(/something went wrong|sign-in/i)
  })

  it('PKCE 403 errors map to the same friendly message', async () => {
    mockSignIn.mockRejectedValueOnce(new Error('PKCE pkce_mismatch (403)'))

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(React.createElement(SignInScreen))
    })

    await act(async () => {
      tap(tree.root, 'google-sign-in-button')
      await Promise.resolve()
      await Promise.resolve()
    })

    const errText = findError(tree.root)
    expect(errText).not.toMatch(/pkce_mismatch|403/i)
  })

  it('network errors map to a connection hint', async () => {
    mockSignIn.mockRejectedValueOnce(new Error('Network request failed'))

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(React.createElement(SignInScreen))
    })

    await act(async () => {
      tap(tree.root, 'google-sign-in-button')
      await Promise.resolve()
      await Promise.resolve()
    })

    const errText = findError(tree.root)
    expect(errText).toMatch(/connection|try again/i)
    expect(errText).not.toMatch(/network request failed/i)
  })

  it('cancellation is NOT surfaced as an error', async () => {
    mockSignIn.mockRejectedValueOnce(new Error('User cancelled the flow'))

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(React.createElement(SignInScreen))
    })

    await act(async () => {
      tap(tree.root, 'google-sign-in-button')
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(findError(tree.root)).toBeNull()
  })

  it('unknown errors fall back to a generic friendly message', async () => {
    mockSignIn.mockRejectedValueOnce(new Error('xyzzy_unrecognized_provider_thing'))

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(React.createElement(SignInScreen))
    })

    await act(async () => {
      tap(tree.root, 'google-sign-in-button')
      await Promise.resolve()
      await Promise.resolve()
    })

    const errText = findError(tree.root)
    expect(errText).not.toMatch(/xyzzy_unrecognized_provider_thing/i)
    expect(errText).toMatch(/sign in|try again/i)
  })
})
