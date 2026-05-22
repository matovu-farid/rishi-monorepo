/**
 * Phase 4 — VoiceChatLauncher (mobile).
 *
 * 52pt glass disk with a mic icon. Per ARCH §3:
 *   - `isActive=false` → Ionicons name `'mic-outline'`
 *   - `isActive=true`  → Ionicons name `'mic-off-outline'`
 *   - Tap with isActive=false → onStart()
 *   - Tap with isActive=true  → onStop()
 *   - Default testID = 'voice-chat-launcher'
 *   - `breathScale` shared value pattern is present (idle breathing).
 *
 * Pinned behaviour (6 tests).
 *
 * Mocks: GlassDisk stub, expo-blur/haptics, reanimated stub that captures
 * shared-value initial values via a module-scoped array (so we can verify
 * that the component allocated at least one shared value — the
 * "breathScale shared-value pattern present" check).
 *
 * Red signal: `@/components/chat/VoiceChatLauncher` does not exist yet.
 */

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
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      absoluteFillObject: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// Reanimated — capture shared-value initial values into a module-scoped
// array so tests can verify the breathScale shared-value pattern.
const sharedValueInits: unknown[] = []
jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  const passthrough = (v: unknown) => v
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => {
      sharedValueInits.push(v)
      return { value: v }
    },
    useAnimatedStyle: () => ({}),
    useReducedMotion: () => false,
    withTiming: passthrough,
    withSpring: passthrough,
    withDelay: (_d: number, v: unknown) => v,
    withSequence: (...vs: unknown[]) => vs,
    withRepeat: (v: unknown) => v,
    cancelAnimation: jest.fn(),
    Easing: {
      out: () => null,
      quad: null,
      inOut: () => null,
      linear: null,
    },
    interpolate: (v: number) => v,
    Extrapolation: { CLAMP: 'clamp' },
  }
})

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

const selectionAsync = jest.fn()
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync,
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

jest.mock('@expo/vector-icons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, Ionicons, default: { Ionicons } }
})

jest.mock(
  '@/components/ui/GlassDisk',
  () => {
    const React = require('react')
    const GlassDisk = (p: any) =>
      React.createElement('GlassDisk', { testID: 'glass-disk', ...p }, p.children)
    return { __esModule: true, GlassDisk }
  },
  { virtual: true },
)

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import { VoiceChatLauncher } from '@/components/chat/VoiceChatLauncher'

function findFirstPressable(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance {
  return tree.root.findAll((n) => n.type === Pressable)[0]
}

beforeEach(() => {
  selectionAsync.mockClear()
  sharedValueInits.length = 0
})

describe('VoiceChatLauncher (mobile)', () => {
  it('renders the `mic-outline` icon when isActive=false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={false}
          onStart={() => undefined}
          onStop={() => undefined}
        />,
      )
    })
    const mic = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'ion-mic-outline',
    )
    expect(mic.length).toBeGreaterThan(0)
    const micOff = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'ion-mic-off-outline',
    )
    expect(micOff.length).toBe(0)
  })

  it('renders the `mic-off-outline` icon when isActive=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={true}
          onStart={() => undefined}
          onStop={() => undefined}
        />,
      )
    })
    const micOff = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'ion-mic-off-outline',
    )
    expect(micOff.length).toBeGreaterThan(0)
    const mic = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'ion-mic-outline',
    )
    expect(mic.length).toBe(0)
  })

  it('calls onStart when pressed with isActive=false', () => {
    const onStart = jest.fn()
    const onStop = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={false}
          onStart={onStart}
          onStop={onStop}
        />,
      )
    })
    const pressable = findFirstPressable(tree)
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(onStart).toHaveBeenCalledTimes(1)
    expect(onStop).not.toHaveBeenCalled()
  })

  it('calls onStop when pressed with isActive=true', () => {
    const onStart = jest.fn()
    const onStop = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={true}
          onStart={onStart}
          onStop={onStop}
        />,
      )
    })
    const pressable = findFirstPressable(tree)
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(onStop).toHaveBeenCalledTimes(1)
    expect(onStart).not.toHaveBeenCalled()
  })

  it('uses default testID="voice-chat-launcher"', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={false}
          onStart={() => undefined}
          onStop={() => undefined}
        />,
      )
    })
    const tagged = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'voice-chat-launcher',
    )
    expect(tagged.length).toBeGreaterThan(0)
  })

  it('allocates at least one shared value (breathScale pattern present)', () => {
    let _tree!: TestRenderer.ReactTestRenderer
    act(() => {
      _tree = TestRenderer.create(
        <VoiceChatLauncher
          isActive={false}
          onStart={() => undefined}
          onStop={() => undefined}
        />,
      )
    })
    // Loose check (per ARCH §11) — VoiceChatLauncher must call
    // useSharedValue(1) for breathScale. We don't assert how many or what
    // animation chain wraps it; only that the shared-value pattern is in use.
    expect(sharedValueInits.length).toBeGreaterThan(0)
    expect(sharedValueInits).toContain(1)
  })
})
