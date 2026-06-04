/**
 * T-P2.3 — BILLING-002 mobile BillingInactiveModal.
 *
 * Asserts the modal:
 *   - Renders nothing (or hidden) when `useBillingStore.billingInactive === false`.
 *   - Renders title "Subscription required" and a body referencing the
 *     subscription status when `billingInactive === true`.
 *   - "Manage Subscription" CTA fires the same `handleManageBilling` flow
 *     the settings screen uses (per SPEC §4.0b — POST `/api/billing/portal`
 *     → `WebBrowser.openBrowserAsync(url)`).
 *   - "Dismiss" CTA calls `useBillingStore.dismiss()`.
 *
 * RED until:
 *   - `apps/mobile/components/billing/BillingInactiveModal.tsx` exists
 *     with the real implementation (currently a placeholder).
 *   - `apps/mobile/lib/stores/billingStore.ts` exists (placeholder
 *     already provides the state surface).
 */

// ── Mock react-native primitives ────────────────────────────────────────────
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: Record<string, unknown>, r: unknown) =>
      React.createElement(name, { ...p, ref: r }),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Modal: mk('Modal'),
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
      (p: Record<string, unknown>, r: unknown) =>
        React.createElement('SafeAreaView', { ...p, ref: r }),
    ),
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
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

// ── Mock expo-web-browser so the Manage Subscription CTA's success path
//    is observable.
const openBrowserAsync = jest.fn().mockResolvedValue({ type: 'opened' })
jest.mock('expo-web-browser', () => ({
  openBrowserAsync: (...args: unknown[]) => openBrowserAsync(...args),
}))

// ── Mock apiClient — Manage Subscription POSTs to `/api/billing/portal`.
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

beforeEach(() => {
  jest.clearAllMocks()
  mockApiClient.mockResolvedValue(
    new Response(JSON.stringify({ url: 'https://billing.stripe.com/test' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
})

/**
 * Helper that mounts the component inside `TestRenderer.act`. React 19's
 * react-test-renderer requires `act` around `create()` or `.root` access
 * raises "Can't access .root on unmounted test renderer".
 */
function mount(node: unknown): {
  json: () => unknown
  unmount: () => void
} {
  const TestRenderer = require('react-test-renderer')
  let tree: ReturnType<typeof TestRenderer.create> | null = null
  TestRenderer.act(() => {
    tree = TestRenderer.create(node)
  })
  return {
    json: () => tree!.toJSON(),
    unmount: () => {
      TestRenderer.act(() => {
        tree!.unmount()
      })
    },
  }
}

/** Walk a JSON test renderer tree looking for a node whose children contain text. */
function findNodeByText(
  json: unknown,
  text: RegExp,
): {
  type: string
  props: Record<string, unknown>
  children: unknown[]
} | null {
  if (json == null || typeof json !== 'object') return null
  const node = json as {
    type?: string
    props?: Record<string, unknown>
    children?: unknown[]
  }
  const children = node.children ?? []
  for (const c of children) {
    if (typeof c === 'string' && text.test(c)) {
      return {
        type: node.type ?? '',
        props: node.props ?? {},
        children: children as unknown[],
      }
    }
  }
  for (const c of children) {
    if (typeof c !== 'string') {
      const deep = findNodeByText(c, text)
      if (deep) return deep
    }
  }
  return null
}

describe('BillingInactiveModal', () => {
  it('renders nothing visible when billingInactive is false', () => {
    const { useBillingStore } = require('@/lib/stores/billingStore')
    const { BillingInactiveModal } =
      require('@/components/billing/BillingInactiveModal') as {
        BillingInactiveModal: React.ComponentType
      }
    const React = require('react')

    useBillingStore.setState({
      billingInactive: false,
      subscriptionStatus: null,
    })

    const m = mount(React.createElement(BillingInactiveModal))
    try {
      expect(findNodeByText(m.json(), /subscription required/i)).toBeNull()
    } finally {
      m.unmount()
    }
  })

  it('renders title + subscription status + CTAs when billingInactive is true', () => {
    const { useBillingStore } = require('@/lib/stores/billingStore')
    const { BillingInactiveModal } =
      require('@/components/billing/BillingInactiveModal') as {
        BillingInactiveModal: React.ComponentType
      }
    const React = require('react')

    useBillingStore.setState({
      billingInactive: true,
      subscriptionStatus: 'canceled',
    })

    const m = mount(React.createElement(BillingInactiveModal))
    try {
      const json = m.json()
      expect(findNodeByText(json, /subscription required/i)).not.toBeNull()
      expect(findNodeByText(json, /canceled/i)).not.toBeNull()
      expect(findNodeByText(json, /manage subscription/i)).not.toBeNull()
      expect(findNodeByText(json, /dismiss/i)).not.toBeNull()
    } finally {
      m.unmount()
    }
  })

  it('"Manage Subscription" POSTs /api/billing/portal and opens the returned URL', async () => {
    const TestRenderer = require('react-test-renderer')
    const { useBillingStore } = require('@/lib/stores/billingStore')
    const { BillingInactiveModal } =
      require('@/components/billing/BillingInactiveModal') as {
        BillingInactiveModal: React.ComponentType
      }
    const React = require('react')

    useBillingStore.setState({
      billingInactive: true,
      subscriptionStatus: 'canceled',
    })

    const m = mount(React.createElement(BillingInactiveModal))
    try {
      const cta = findNodeByText(m.json(), /manage subscription/i)
      expect(cta).not.toBeNull()
      const onPress = (cta!.props as { onPress?: (...a: unknown[]) => unknown })
        .onPress
      expect(typeof onPress).toBe('function')

      await TestRenderer.act(async () => {
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

  it('"Dismiss" CTA calls useBillingStore.dismiss()', () => {
    const TestRenderer = require('react-test-renderer')
    const { useBillingStore } = require('@/lib/stores/billingStore')
    const { BillingInactiveModal } =
      require('@/components/billing/BillingInactiveModal') as {
        BillingInactiveModal: React.ComponentType
      }
    const React = require('react')

    useBillingStore.setState({
      billingInactive: true,
      subscriptionStatus: 'canceled',
    })

    const m = mount(React.createElement(BillingInactiveModal))
    try {
      const cta = findNodeByText(m.json(), /dismiss/i)
      expect(cta).not.toBeNull()
      const onPress = (cta!.props as { onPress?: () => void }).onPress

      TestRenderer.act(() => {
        onPress?.()
      })

      const s = useBillingStore.getState()
      expect(s.billingInactive).toBe(false)
    } finally {
      m.unmount()
    }
  })
})
