/**
 * Phase 1 — PremiumFeatureSheet (mobile).
 *
 * The sheet is fully controlled by the auth store
 * (`premiumGateOpen`, `premiumGateFeature`, `isAuthenticating`,
 * `closePremiumGate`). The signed-out user taps a premium control →
 * a hook calls `openPremiumGate(feature)` → the sheet opens. The sheet
 * renders:
 *   - title + body from `FEATURE_COPY[feature]`
 *   - CTA labelled by platform (Apple on iOS, Google on Android)
 *   - "Not now" dismiss → calls `closePremiumGate`
 *   - while authenticating: ActivityIndicator in place of the label
 *   - on non-cancel sign-in error: an error row appears
 *
 * Test setup follows the established mobile convention:
 *   - Mock react-native primitives + Reanimated + bottom-sheet
 *   - Use react-test-renderer for the host
 *
 * @gorhom/bottom-sheet is stubbed to a passthrough wrapper so we don't
 * pull GestureHandler / Worklets into the node test VM.
 */

// ── Mock react-native primitives ─────────────────────────────────────────────
let __platformOS: 'ios' | 'android' = 'ios'

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) => React.createElement(name, { ...p, ref: r }))
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    ActivityIndicator: (p: any) => React.createElement('ActivityIndicator', p),
    StyleSheet: { create: (s: Record<string, unknown>) => s, absoluteFillObject: {} },
    Platform: {
      get OS() {
        return __platformOS
      },
      select: (specifics: Record<string, unknown>) =>
        specifics[__platformOS] ?? specifics.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
      setAccessibilityFocus: jest.fn(),
      announceForAccessibility: jest.fn(),
    },
  }
})

// ── Mock MMKV ────────────────────────────────────────────────────────────────
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  }),
}))

// ── Mock Reanimated (sheet uses withSequence for the error shake) ────────────
// `withTiming` is wrapped so tests can introspect that the caller passed an
// easing config — VIS-029 requires Easing.out(Easing.cubic), no longer the
// linear default.
const withTimingMock = jest.fn((v: unknown, cfg?: unknown) => ({ __value: v, __cfg: cfg }))
jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    withSequence: (...vs: unknown[]) => vs,
    withTiming: withTimingMock,
    withSpring: (v: unknown) => v,
    Easing: {
      out: (fn: unknown) => ({ __easing: 'out', inner: fn }),
      cubic: { __easing: 'cubic' },
      quad: { __easing: 'quad' },
      inOut: (fn: unknown) => ({ __easing: 'inOut', inner: fn }),
    },
  }
})

// ── Mock safe-area-context ───────────────────────────────────────────────────
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// ── Mock @gorhom/bottom-sheet — render children inline; we don't need
//    the real gesture stack for unit assertions. The sheet must still
//    "hide" content when premiumGateOpen is false; the component itself
//    is responsible for the early-return null branch.
jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef((p: any, _r: unknown) =>
    React.createElement('BottomSheet', p, p.children),
  )
  const BottomSheetView = (p: any) =>
    React.createElement('BottomSheetView', p, p.children)
  const BottomSheetBackdrop = (p: any) => React.createElement('BottomSheetBackdrop', p)
  return {
    __esModule: true,
    default: BottomSheet,
    BottomSheetView,
    BottomSheetBackdrop,
  }
})

// ── Mock @expo/vector-icons/Ionicons — render a Text node with the name ──────
jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

// ── Mock expo-haptics — noop ─────────────────────────────────────────────────
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: {
    Soft: 'soft',
    Light: 'light',
    Medium: 'medium',
    Heavy: 'heavy',
    Rigid: 'rigid',
  },
  NotificationFeedbackType: { Success: 'success', Error: 'error' },
}))

// ── Mock lib/auth — controllable signIn() ────────────────────────────────────
const signInMock = jest.fn(async () => ({ session_token: 't', user_id: 'u' }))
jest.mock('@/lib/auth', () => ({
  signIn: signInMock,
}))

// ── Mock expo-router — controllable router.push() ────────────────────────────
const routerPushMock = jest.fn()
jest.mock('expo-router', () => ({
  useRouter: () => ({
    push: routerPushMock,
    replace: jest.fn(),
    back: jest.fn(),
  }),
}))

// ── Mock authStore — selector-based ──────────────────────────────────────────
type StoreShape = {
  premiumGateOpen: boolean
  premiumGateFeature: 'tts' | 'voice-chat' | 'ai-chat' | 'voice-input' | 'sync' | 'ai-generic' | null
  isAuthenticating: boolean
  closePremiumGate: jest.Mock
  setAuthenticating: jest.Mock
}

const closePremiumGate = jest.fn()
const setAuthenticating = jest.fn()

let storeState: StoreShape = {
  premiumGateOpen: false,
  premiumGateFeature: null,
  isAuthenticating: false,
  closePremiumGate,
  setAuthenticating,
}

jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: <T,>(selector: (s: StoreShape) => T) => selector(storeState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import * as Haptics from 'expo-haptics'
import { PremiumFeatureSheet } from '@/components/auth/PremiumFeatureSheet'

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
  signInMock.mockReset()
  signInMock.mockResolvedValue({ session_token: 't', user_id: 'u' })
  closePremiumGate.mockClear()
  setAuthenticating.mockClear()
  routerPushMock.mockClear()
  ;(Haptics.selectionAsync as jest.Mock).mockClear()
  ;(Haptics.impactAsync as jest.Mock).mockClear()
  ;(Haptics.notificationAsync as jest.Mock).mockClear()
  withTimingMock.mockClear()
  __platformOS = 'ios'
  storeState = {
    premiumGateOpen: false,
    premiumGateFeature: null,
    isAuthenticating: false,
    closePremiumGate,
    setAuthenticating,
  }
})

describe('PremiumFeatureSheet (mobile)', () => {
  it('renders no visible feature copy when premiumGateOpen is false', () => {
    storeState.premiumGateOpen = false
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    // The shared FEATURE_COPY title for 'tts' must not be in the rendered
    // tree when the gate is closed.
    expect(hasText(tree, 'Sign in to listen')).toBe(false)
  })

  it('renders title + body from FEATURE_COPY when opened for tts', () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Sign in to listen')).toBe(true)
    expect(
      hasText(tree, 'Sign in to hear your books read aloud in expressive voices.'),
    ).toBe(true)
  })

  it("CTA label is 'Continue with Google' on iOS when Apple sign-in is disabled (P0-V)", () => {
    __platformOS = 'ios'
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Continue with Google')).toBe(true)
    expect(hasText(tree, 'Continue with Apple')).toBe(false)
  })

  it("renders a secondary 'Other sign-in options' link on iOS (P0-V)", () => {
    __platformOS = 'ios'
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Other sign-in options')).toBe(true)
  })

  it("tapping 'Other sign-in options' routes to /(auth)/sign-in and closes the gate (P0-V)", () => {
    __platformOS = 'ios'
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    const other = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Other sign-in options',
    )
    expect(other.length).toBeGreaterThan(0)
    act(() => {
      ;(other[0].props as { onPress: () => void }).onPress()
    })
    expect(routerPushMock).toHaveBeenCalledWith('/(auth)/sign-in')
    expect(closePremiumGate).toHaveBeenCalledTimes(1)
  })

  it("CTA label is 'Continue with Google' on Android", () => {
    __platformOS = 'android'
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Continue with Google')).toBe(true)
    expect(hasText(tree, 'Continue with Apple')).toBe(false)
  })

  it("renders a 'Create account' secondary link (P1-Q)", () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Create account')).toBe(true)
  })

  it("tapping 'Create account' routes to sign-in screen and closes the gate (P1-Q)", () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    const matches = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Create account',
    )
    expect(matches.length).toBeGreaterThan(0)
    act(() => {
      ;(matches[0].props as { onPress: () => void }).onPress()
    })
    expect(routerPushMock).toHaveBeenCalledWith('/(auth)/sign-in?signup=1')
    expect(closePremiumGate).toHaveBeenCalledTimes(1)
  })

  it("pressing 'Maybe later' calls closePremiumGate (P1-R renamed from 'Not now')", () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    // Locate the Pressable whose accessibilityLabel is 'Maybe later'.
    const maybeLater = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Maybe later',
    )
    expect(maybeLater.length).toBeGreaterThan(0)
    act(() => {
      ;(maybeLater[0].props as { onPress: () => void }).onPress()
    })
    expect(closePremiumGate).toHaveBeenCalledTimes(1)
  })

  it("renders a subline under 'Maybe later' explaining what dismiss does (P1-R)", () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    expect(hasText(tree, 'Maybe later')).toBe(true)
    // Subline copy must hint that the gate goes away for this session.
    expect(
      hasText(tree, 'You can sign in any time from Settings.'),
    ).toBe(true)
  })

  it('renders ActivityIndicator (not CTA label text) while isAuthenticating=true', () => {
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'
    storeState.isAuthenticating = true
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    const spinners = tree.root.findAllByType('ActivityIndicator' as never)
    expect(spinners.length).toBeGreaterThan(0)
    // The CTA label text must NOT be in the tree while the spinner is showing.
    expect(hasText(tree, 'Continue with Google')).toBe(false)
  })

  it('shows the inline error row when signIn rejects with a non-cancel message', async () => {
    // GAT-008 — unknown error shape falls through to the generic default.
    signInMock.mockRejectedValueOnce(new Error('something exploded'))
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'

    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    // Locate the primary CTA Pressable.
    const cta = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel === 'Continue with Google',
    )
    expect(cta.length).toBeGreaterThan(0)

    await act(async () => {
      await (cta[0].props as { onPress: () => Promise<void> | void }).onPress()
    })

    expect(hasText(tree, "Couldn't sign in. Try again.")).toBe(true)
  })

  it('does NOT show error row when signIn rejects with a cancel message', async () => {
    signInMock.mockRejectedValueOnce(new Error('User cancelled'))
    storeState.premiumGateOpen = true
    storeState.premiumGateFeature = 'tts'

    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<PremiumFeatureSheet />)
    })
    const cta = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel === 'Continue with Google',
    )
    await act(async () => {
      await (cta[0].props as { onPress: () => Promise<void> | void }).onPress()
    })

    expect(hasText(tree, "Couldn't sign in. Try again.")).toBe(false)
  })

  describe('error copy mapping (GAT-008)', () => {
    async function pressCtaWith(errMsg: string): Promise<TestRenderer.ReactTestRenderer> {
      signInMock.mockRejectedValueOnce(new Error(errMsg))
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'
      let tree!: TestRenderer.ReactTestRenderer
      await act(async () => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      const cta = tree.root.findAll(
        (n) =>
          n.type === Pressable &&
          (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
            'Continue with Google',
      )
      await act(async () => {
        await (cta[0].props as { onPress: () => Promise<void> | void }).onPress()
      })
      return tree
    }

    it('maps network/fetch failures to "Check your connection and try again."', async () => {
      const tree = await pressCtaWith('Network request failed')
      expect(hasText(tree, 'Check your connection and try again.')).toBe(true)
      expect(hasText(tree, "Couldn't sign in. Try again.")).toBe(false)
    })

    it('maps "fetch failed" wrapping (worker /mobile/start) to the network copy', async () => {
      const tree = await pressCtaWith('POST /mobile/start failed: fetch failed')
      expect(hasText(tree, 'Check your connection and try again.')).toBe(true)
    })

    it('maps PKCE 403 mismatch to "Sign-in expired, please try again."', async () => {
      const tree = await pressCtaWith('PKCE pkce_mismatch (403)')
      expect(hasText(tree, 'Sign-in expired, please try again.')).toBe(true)
      expect(hasText(tree, "Couldn't sign in. Try again.")).toBe(false)
    })

    it('maps 410 session-expired to "Sign-in expired, please try again."', async () => {
      const tree = await pressCtaWith('POST /mobile/start/verify failed: 410 session expired')
      expect(hasText(tree, 'Sign-in expired, please try again.')).toBe(true)
    })

    it('maps "Apple provider not configured" to the unavailable-provider copy (GAT-106)', async () => {
      // GAT-106 — provider-not-configured must be classified BEFORE the
      // 403/410 buckets, otherwise the user sees "Sign-in expired" copy
      // even though the worker rejected with provider misconfiguration.
      const tree = await pressCtaWith('Apple provider not configured')
      expect(hasText(tree, 'This sign-in method is not available yet.')).toBe(true)
      expect(hasText(tree, 'Sign-in expired, please try again.')).toBe(false)
      expect(hasText(tree, "Couldn't sign in. Try again.")).toBe(false)
    })

    it('still maps Apple provider error wrapped in a 403 response to the unavailable copy (GAT-106)', async () => {
      // The worker can return 403 alongside the provider-not-configured
      // text; the new bucket must win because the 403 reading would be
      // misleading.
      const tree = await pressCtaWith('POST /mobile/start failed: 403 provider not configured')
      expect(hasText(tree, 'This sign-in method is not available yet.')).toBe(true)
    })
  })

  describe('theme tint (VIS-021)', () => {
    function findCta(tree: TestRenderer.ReactTestRenderer): TestRenderer.ReactTestInstance | undefined {
      return tree.root.findAll(
        (n) =>
          n.type === Pressable &&
          (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
            'Continue with Google',
      )[0]
    }

    it('CTA backgroundColor uses colors.accent.primary (systemBlue light), not legacy #0a7ea4', () => {
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      const cta = findCta(tree)
      expect(cta).toBeDefined()
      // `style` is a function: ({pressed}) => ({...}). Invoke it to read the static bg color.
      const styleFn = (cta!.props as { style: (s: { pressed: boolean }) => Record<string, string> })
        .style
      const resolved = styleFn({ pressed: false })
      expect(resolved.backgroundColor).toBe('#007AFF')
      expect(resolved.backgroundColor).not.toBe('#0a7ea4')
    })

    it('every "Maybe later" / "Other sign-in options" / "Create account" link uses colors.accent.primary', () => {
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      // Locate every Text node whose stringified rendered children are one
      // of the link labels, then assert their `color` is the systemBlue
      // light token (#007AFF) rather than the legacy #0a7ea4 brand hex.
      const linkLabels = ['Other sign-in options', 'Create account', 'Maybe later']
      const json = tree.toJSON()
      let matched = 0
      const visit = (n: TestRenderer.ReactTestRendererJSON | string | null): void => {
        if (!n || typeof n === 'string') return
        if (n.type === 'Text' && Array.isArray(n.children)) {
          const direct = n.children.find((c): c is string => typeof c === 'string')
          if (direct && linkLabels.includes(direct)) {
            const style = (n.props as { style?: { color?: string } }).style
            expect(style?.color).toBe('#007AFF')
            expect(style?.color).not.toBe('#0a7ea4')
            matched += 1
          }
        }
        if (Array.isArray(n.children)) {
          for (const c of n.children) visit(c as TestRenderer.ReactTestRendererJSON | string)
        }
      }
      if (Array.isArray(json)) for (const j of json) visit(j)
      else visit(json)
      expect(matched).toBe(3)
    })
  })

  describe('theme tokens (VIS-028)', () => {
    it('handle indicator backgroundColor is sourced from colors.label.quaternary, not hardcoded', () => {
      // VIS-028 — the previous hardcoded {dark:#48484A, light:#C7C7CC}
      // pair bypassed design tokens. The semantic light token is
      // 'rgba(60,60,67,0.18)'.
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      const sheets = tree.root.findAllByType('BottomSheet' as never)
      expect(sheets.length).toBeGreaterThan(0)
      const handleStyle = (sheets[0].props as { handleIndicatorStyle?: { backgroundColor?: string } })
        .handleIndicatorStyle
      expect(handleStyle?.backgroundColor).toBe('rgba(60,60,67,0.18)')
      // Make sure we didn't regress to the legacy hex codes.
      expect(handleStyle?.backgroundColor).not.toBe('#48484A')
      expect(handleStyle?.backgroundColor).not.toBe('#C7C7CC')
    })
  })

  describe('shake animation easing (VIS-029)', () => {
    it('passes Easing.out(Easing.cubic) to every shake step instead of linear default', async () => {
      signInMock.mockRejectedValueOnce(new Error('something exploded'))
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'

      let tree!: TestRenderer.ReactTestRenderer
      await act(async () => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      const cta = tree.root.findAll(
        (n) =>
          n.type === Pressable &&
          (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
            'Continue with Google',
      )
      withTimingMock.mockClear()
      await act(async () => {
        await (cta[0].props as { onPress: () => Promise<void> | void }).onPress()
      })

      // Five steps in the shake sequence; every step must carry an easing
      // config — VIS-029 forbids the linear default.
      expect(withTimingMock).toHaveBeenCalledTimes(5)
      for (const call of withTimingMock.mock.calls) {
        const cfg = call[1] as { easing?: { __easing?: string; inner?: { __easing?: string } } }
        expect(cfg).toBeDefined()
        expect(cfg.easing).toBeDefined()
        expect(cfg.easing?.__easing).toBe('out')
        expect(cfg.easing?.inner?.__easing).toBe('cubic')
      }
    })
  })

  describe('dismiss haptic differentiation (GAT-014)', () => {
    function pressMaybeLater(): void {
      storeState.premiumGateOpen = true
      storeState.premiumGateFeature = 'tts'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<PremiumFeatureSheet />)
      })
      // Clear any open-sheet haptics so we only observe what `handleDismiss`
      // itself fires.
      ;(Haptics.selectionAsync as jest.Mock).mockClear()
      ;(Haptics.impactAsync as jest.Mock).mockClear()
      ;(Haptics.notificationAsync as jest.Mock).mockClear()

      const maybeLater = tree.root.findAll(
        (n) =>
          n.type === Pressable &&
          (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
            'Maybe later',
      )
      act(() => {
        ;(maybeLater[0].props as { onPress: () => void }).onPress()
      })
    }

    it('does not play a selection haptic on dismiss (was the same as sign-in)', () => {
      pressMaybeLater()
      // Dismiss must not trigger `selectionAsync` — that haptic is reserved
      // for the sign-in CTA tap, where it acknowledges progress towards
      // authentication. Confusing the two falsely tells the user they
      // succeeded at signing in.
      expect(Haptics.selectionAsync).not.toHaveBeenCalled()
    })

    it('does not play a Success notification haptic on dismiss', () => {
      pressMaybeLater()
      // Success notification is reserved for the post-sign-in confirmation.
      const calls = (Haptics.notificationAsync as jest.Mock).mock.calls
      for (const call of calls) {
        expect(call[0]).not.toBe('success')
      }
    })

    it('uses a Rigid (or Heavy) impact on dismiss — never Soft or Light (GAT-108)', () => {
      pressMaybeLater()
      // GAT-108 — Light still tested too close to Success on real devices,
      // so dismiss now uses Rigid (or Heavy) for a crisp, distinct tap.
      // Soft is reserved for the sheet-open feel.
      const calls = (Haptics.impactAsync as jest.Mock).mock.calls
      expect(calls.length).toBe(1)
      for (const call of calls) {
        expect(call[0]).not.toBe('soft')
        expect(call[0]).not.toBe('light')
        expect(['rigid', 'heavy']).toContain(call[0])
      }
    })
  })
})
