/**
 * ReaderTopBar — P1-E (toolbar pinning).
 *
 * The top bar's Back chevron now serves dual duty:
 *   - short press → `onBack`
 *   - long press → `onLongPressBack` (pinned toggle, driven by ReaderShell)
 *
 * It also accepts a `pinned` flag so it can render a subtle visual cue.
 *
 * These tests pin only the wiring that the ReaderShell relies on. The
 * cue's exact rendering is a visual detail; we just assert that the
 * pinned prop is consumed.
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
      hairlineWidth: 0.5,
      absoluteFillObject: {},
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
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    withTiming: (v: unknown) => v,
    withSpring: (v: unknown) => v,
    Easing: { out: () => null, quad: null, inOut: () => null },
  }
})

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
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

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', p, p.children)
  return { __esModule: true, BlurView }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ReaderTopBar } from '@/components/reader/ReaderTopBar'

function findIconButtonForLabel(
  tree: TestRenderer.ReactTestRenderer,
  label: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) =>
      (n.props as { accessibilityLabel?: string } | null)
        ?.accessibilityLabel === label,
  )
  return matches[0] ?? null
}

describe('ReaderTopBar — long-press to toggle pinned (P1-E)', () => {
  it('fires `onLongPress` on the Back chevron', () => {
    const onLongPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderTopBar
          visible={true}
          title="The Discourses"
          onBack={() => undefined}
          onLongPressBack={onLongPress}
        />,
      )
    })
    const back = findIconButtonForLabel(tree, 'Back to library')
    expect(back).not.toBeNull()
    const longPress = (back?.props as { onLongPress?: () => void })
      .onLongPress
    expect(typeof longPress).toBe('function')
    act(() => {
      longPress?.()
    })
    expect(onLongPress).toHaveBeenCalledTimes(1)
  })

  it('renders a pin cue when `pinned={true}` (testID="reader-top-bar-pin-cue")', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderTopBar
          visible={true}
          title="The Discourses"
          onBack={() => undefined}
          pinned={true}
        />,
      )
    })
    const cue = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID ===
        'reader-top-bar-pin-cue',
    )
    expect(cue.length).toBeGreaterThan(0)
  })

  it('does NOT render the pin cue when `pinned={false}`', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderTopBar
          visible={true}
          title="The Discourses"
          onBack={() => undefined}
          pinned={false}
        />,
      )
    })
    const cue = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID ===
        'reader-top-bar-pin-cue',
    )
    expect(cue.length).toBe(0)
  })
})
