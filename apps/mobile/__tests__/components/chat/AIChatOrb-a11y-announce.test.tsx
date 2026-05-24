/**
 * AIChatOrb — critic-sweep fix #102 / A11Y-005.
 *
 * `accessibilityValue={{ text }}` alone isn't enough: a VoiceOver user
 * focused on the orb won't hear updates when state changes because the
 * Pressable element itself doesn't refocus. The acceptance from
 * VALIDATED.md#A11Y-005 is:
 *
 *   "When orb is focused and `chatStatus` changes, call
 *    AccessibilityInfo.announceForAccessibility with the new state."
 *
 * The orb tracks the previously-rendered status in a ref and fires
 * `AccessibilityInfo.announceForAccessibility(A11Y_LABELS[chatStatus])`
 * on transitions only (initial mount is silent). This pins all four
 * directions of the status graph plus the "no-announce on same-status
 * re-render" invariant.
 *
 * This sits alongside `AIChatOrb.test.tsx` so the A11Y-005 acceptance
 * survives any refactor of the broader orb suite.
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
      announceForAccessibility: jest.fn(),
    },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

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
    useSharedValue: (v: unknown) => ({ value: v }),
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
    FadeIn: { duration: () => ({ build: () => ({}) }) },
    FadeOut: { duration: () => ({ build: () => ({}) }) },
  }
})

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

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

jest.mock('@rishi/shared/tokens/orb-colors', () => ({
  __esModule: true,
  ORB_COLORS: {
    idle: 'rgba(88, 86, 214, 0.70)',
    connecting: 'rgba(59, 130, 246, 0.80)',
    thinking: 'rgba(251, 191, 36, 0.80)',
    speaking: 'rgba(34, 197, 94, 0.80)',
  },
  ORB_DISK_TINTS: {
    idle: 'rgba(88, 86, 214, 0.24)',
    connecting: 'rgba(59, 130, 246, 0.24)',
    thinking: 'rgba(251, 191, 36, 0.24)',
    speaking: 'rgba(34, 197, 94, 0.24)',
  },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { AccessibilityInfo } from 'react-native'
import { AIChatOrb } from '@/components/chat/AIChatOrb'
import type { AIChatOrbStatus } from '@rishi/shared/tokens/orb-colors'

const A11Y_LABELS: Record<AIChatOrbStatus, string> = {
  idle: 'AI chat',
  connecting: 'AI chat — connecting',
  thinking: 'AI chat — thinking',
  speaking: 'AI chat — speaking',
}

const TRANSITIONS: Array<[AIChatOrbStatus, AIChatOrbStatus]> = [
  ['idle', 'connecting'],
  ['connecting', 'thinking'],
  ['thinking', 'speaking'],
  ['speaking', 'idle'],
  ['idle', 'thinking'],
  ['speaking', 'connecting'],
]

describe('AIChatOrb — A11Y-005 #102: announces status on transition', () => {
  beforeEach(() => {
    ;(AccessibilityInfo.announceForAccessibility as jest.Mock).mockClear()
  })

  it.each(TRANSITIONS)(
    'announces the new label for the %s -> %s transition',
    (from, to) => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus={from} onPress={() => undefined} />,
        )
      })
      // Initial mount is silent — guarantees we are observing a true
      // transition, not the first paint.
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).not.toHaveBeenCalled()
      act(() => {
        tree.update(
          <AIChatOrb chatStatus={to} onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenCalledTimes(1)
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenLastCalledWith(A11Y_LABELS[to])
    },
  )

  it('does NOT announce when the same status renders twice', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AIChatOrb chatStatus="speaking" onPress={() => undefined} />,
      )
    })
    ;(AccessibilityInfo.announceForAccessibility as jest.Mock).mockClear()
    act(() => {
      tree.update(
        <AIChatOrb chatStatus="speaking" onPress={() => undefined} />,
      )
    })
    expect(
      AccessibilityInfo.announceForAccessibility,
    ).not.toHaveBeenCalled()
  })
})
