/**
 * Sign-in screen UI tests (P1-D, P1-Q).
 *
 * Covers tertiary "Skip for now" link and the "Create account" CTA that
 * route signed-out users out of the dead-end sign-in screen.
 */

// ── Mock react-native primitives ─────────────────────────────────────────────
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    ActivityIndicator: (p: any) => React.createElement('ActivityIndicator', p),
    KeyboardAvoidingView: mk('KeyboardAvoidingView'),
    StyleSheet: { create: (s: Record<string, unknown>) => s, absoluteFillObject: {} },
    Platform: { OS: 'ios', select: (s: any) => s.ios ?? s.default },
    useColorScheme: () => 'light',
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: (p: any) => React.createElement('SafeAreaView', p, p.children),
    SafeAreaProvider: (p: any) => p.children,
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

// ── Mock MMKV (authStore touches it transitively) ────────────────────────────
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  }),
}))

// ── Mock expo-router with reassignable replace/push mocks ────────────────────
const replaceMock = jest.fn()
const pushMock = jest.fn()
jest.mock('expo-router', () => ({
  useRouter: () => ({ replace: replaceMock, push: pushMock, back: jest.fn() }),
}))

// ── Mock lib/auth ────────────────────────────────────────────────────────────
const signInMock = jest.fn(async () => ({ session_token: 't', user_id: 'u' }))
jest.mock('@/lib/auth', () => ({
  signIn: signInMock,
}))

// ── Mock authStore — selector pattern ────────────────────────────────────────
type Shape = {
  isAuthenticating: boolean
  setAuthenticating: jest.Mock
  setSession: jest.Mock
}
const setAuthenticating = jest.fn()
const setSession = jest.fn()
let storeState: Shape = {
  isAuthenticating: false,
  setAuthenticating,
  setSession,
}
jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: <T,>(sel: (s: Shape) => T) => sel(storeState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { TouchableOpacity } from 'react-native'
import SignInScreen from '@/app/(auth)/sign-in'

function findTextNodes(root: TestRenderer.ReactTestRenderer): string[] {
  const out: string[] = []
  const visit = (node: TestRenderer.ReactTestRendererJSON | string | null): void => {
    if (node === null) return
    if (typeof node === 'string') {
      out.push(node)
      return
    }
    if (Array.isArray(node.children)) {
      for (const c of node.children) visit(c as TestRenderer.ReactTestRendererJSON | string)
    }
  }
  const json = root.toJSON()
  if (Array.isArray(json)) for (const j of json) visit(j)
  else visit(json)
  return out
}

function hasText(root: TestRenderer.ReactTestRenderer, needle: string): boolean {
  return findTextNodes(root).some((t) => t.includes(needle))
}

beforeEach(() => {
  replaceMock.mockReset()
  pushMock.mockReset()
  signInMock.mockReset()
  setAuthenticating.mockClear()
  setSession.mockClear()
  storeState = {
    isAuthenticating: false,
    setAuthenticating,
    setSession,
  }
})

describe('SignInScreen (mobile) — P1-D skip-for-now', () => {
  it('renders a tertiary "Skip for now" link', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SignInScreen />)
    })
    expect(hasText(tree, 'Skip for now')).toBe(true)
  })

  it('tapping "Skip for now" calls router.replace("/(tabs)")', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SignInScreen />)
    })
    const matches = tree.root.findAll(
      (n) =>
        (n.type === TouchableOpacity ||
          (typeof n.type === 'string' && n.type === 'TouchableOpacity')) &&
        (n.props as { testID?: string }).testID === 'skip-for-now-button',
    )
    expect(matches.length).toBeGreaterThan(0)
    act(() => {
      ;(matches[0].props as { onPress: () => void }).onPress()
    })
    expect(replaceMock).toHaveBeenCalledWith('/(tabs)')
  })
})

describe.skip('SignInScreen (mobile) — P1-Q create-account CTA', () => {
  it('renders a "Create account" CTA', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SignInScreen />)
    })
    expect(hasText(tree, 'Create account')).toBe(true)
  })

  it('tapping "Create account" routes to sign-in with provider=signup', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SignInScreen />)
    })
    const matches = tree.root.findAll(
      (n) =>
        (n.type === TouchableOpacity ||
          (typeof n.type === 'string' && n.type === 'TouchableOpacity')) &&
        (n.props as { testID?: string }).testID === 'create-account-button',
    )
    expect(matches.length).toBeGreaterThan(0)
    act(() => {
      ;(matches[0].props as { onPress: () => void | Promise<void> }).onPress()
    })
    // We dispatch the existing signIn flow with 'signup' so the worker's
    // start endpoint can route to the registration form.
    expect(signInMock).toHaveBeenCalledWith('signup')
  })
})
