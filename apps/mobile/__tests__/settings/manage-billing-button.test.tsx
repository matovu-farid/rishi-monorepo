/**
 * T-P2.4 — BILLING-003 mobile audit / red test.
 *
 * Asserts the mobile Settings screen has a Manage-billing row that:
 *   - POSTs `/api/billing/portal` via `apiClient`.
 *   - On success ({ url }), opens the URL with `WebBrowser.openBrowserAsync`.
 *   - On error response (non-2xx OR thrown), surfaces an error toast or
 *     keeps internal `error` state — we accept either path (the existing
 *     mobile error UX is a setState-driven inline error; see SPEC §4.0b's
 *     electron canonical at `routes/settings/account.tsx`).
 *
 * The current worktree's `apps/mobile/app/(tabs)/settings/index.tsx`
 * has no Manage-billing row — the test is therefore RED and pins the
 * acceptance shape per PLAN T-P2.4.
 *
 * (If a follow-up moves the Manage-billing CTA into a separate component,
 * this test must still be satisfied by the SettingsScreen tree containing
 * a node with testID `settings-manage-billing` and a wired onPress.)
 */

// ── MMKV in-memory backend ───────────────────────────────────────────────
type StoreBackend = Map<string, string>
let backingStore: StoreBackend

function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => {
      store.set(key, String(value))
    },
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

// ── lib/auth signOut — used by the existing Sign-out row.
const mockSignOut = jest.fn().mockResolvedValue(undefined)
jest.mock('@/lib/auth', () => ({
  signOut: () => mockSignOut(),
}))

// ── apiClient — observe the POST to /api/billing/portal.
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

// ── WebBrowser — observe the openBrowserAsync call.
const openBrowserAsync = jest.fn().mockResolvedValue({ type: 'opened' })
jest.mock('expo-web-browser', () => ({
  openBrowserAsync: (...args: unknown[]) => openBrowserAsync(...args),
}))

// ── expo-constants for the version row.
jest.mock('expo-constants', () => ({
  __esModule: true,
  default: { expoConfig: { version: '1.0.0' } },
}))

// ── react-native primitives.
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((props: Record<string, unknown>, ref: unknown) =>
      React.createElement(name, { ...props, ref }),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Switch: mk('Switch'),
    ScrollView: mk('ScrollView'),
    ActivityIndicator: (p: Record<string, unknown>) =>
      React.createElement('ActivityIndicator', p),
    StyleSheet: { create: (s: Record<string, unknown>) => s, flatten: (s: unknown) => s },
    Platform: { OS: 'ios', select: (m: Record<string, unknown>) => m.ios ?? m.default },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: React.forwardRef(
      (props: Record<string, unknown>, ref: unknown) =>
        React.createElement('SafeAreaView', { ...props, ref }),
    ),
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (props: Record<string, unknown>) =>
      React.createElement('IconSymbol', props),
  }
})

jest.mock('@/components/settings/LanguagePicker', () => {
  const React = require('react')
  return {
    LanguagePicker: (p: Record<string, unknown>) =>
      React.createElement('LanguagePicker', p),
  }
})

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
  mockApiClient.mockReset()
  openBrowserAsync.mockClear()
  mockSignOut.mockClear()
})

/**
 * Seed the authStore so the Account-section Manage-billing row renders
 * (the production component gates the button on `user != null`).
 *
 * `jest.resetModules()` runs in `beforeEach`, so we must re-require the
 * store inside each test after the reset — calling `setState` on the
 * pre-reset module wouldn't reach the freshly-loaded copy used by the
 * SettingsScreen import below.
 */
function seedSignedInUser() {
  const { useAuthStore } = require('@/lib/stores/authStore')
  useAuthStore.setState({
    user: { id: 'u-mb', email: 'mb@example.com' },
    isAuthenticated: true,
    sessionToken: 'tok',
  })
}

import React from 'react'

/**
 * Mount under `TestRenderer.act` so React 19's renderer keeps `.root`
 * accessible after `create()`. Matches the convention used by the
 * existing `apps/mobile/__tests__/settings/settings.test.tsx`.
 */
function mount(node: unknown) {
  const TestRenderer = require('react-test-renderer')
  let tree: ReturnType<typeof TestRenderer.create> | null = null
  TestRenderer.act(() => {
    tree = TestRenderer.create(node)
  })
  return {
    tree: tree!,
    findByTestID(id: string) {
      try {
        return tree!.root.findByProps({ testID: id })
      } catch {
        return null
      }
    },
    unmount() {
      TestRenderer.act(() => {
        tree!.unmount()
      })
    },
  }
}

describe('Settings — Manage Subscription row (T-P2.4)', () => {
  it('renders a Manage-billing row with testID="settings-manage-billing"', () => {
    seedSignedInUser()
    const SettingsScreen = require('@/app/(tabs)/settings/index').default
    const m = mount(React.createElement(SettingsScreen))
    try {
      expect(m.findByTestID('settings-manage-billing')).not.toBeNull()
    } finally {
      m.unmount()
    }
  })

  it('press → POST /api/billing/portal → WebBrowser.openBrowserAsync(url)', async () => {
    seedSignedInUser()
    const TestRenderer = require('react-test-renderer')
    mockApiClient.mockResolvedValueOnce(
      new Response(JSON.stringify({ url: 'https://billing.stripe.com/test' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )

    const SettingsScreen = require('@/app/(tabs)/settings/index').default
    const m = mount(React.createElement(SettingsScreen))
    try {
      const row = m.findByTestID('settings-manage-billing')
      expect(row).not.toBeNull()

      await TestRenderer.act(async () => {
        const onPress = (row?.props as { onPress?: (...a: unknown[]) => unknown })
          .onPress
        expect(typeof onPress).toBe('function')
        await onPress?.()
      })

      expect(mockApiClient).toHaveBeenCalledWith(
        '/api/billing/portal',
        expect.objectContaining({ method: 'POST' }),
      )
      expect(openBrowserAsync).toHaveBeenCalledWith(
        'https://billing.stripe.com/test',
      )
    } finally {
      m.unmount()
    }
  })

  it('on error response, does NOT open the browser and surfaces an error', async () => {
    seedSignedInUser()
    const TestRenderer = require('react-test-renderer')
    mockApiClient.mockResolvedValueOnce(
      new Response(JSON.stringify({ error: 'server down' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )

    const SettingsScreen = require('@/app/(tabs)/settings/index').default
    const m = mount(React.createElement(SettingsScreen))
    try {
      const row = m.findByTestID('settings-manage-billing')
      expect(row).not.toBeNull()

      await TestRenderer.act(async () => {
        const onPress = (row?.props as { onPress?: (...a: unknown[]) => unknown })
          .onPress
        await onPress?.()
      })

      expect(openBrowserAsync).not.toHaveBeenCalled()
      const inline = m.findByTestID('settings-manage-billing-error')
      expect(inline).not.toBeNull()
    } finally {
      m.unmount()
    }
  })
})
