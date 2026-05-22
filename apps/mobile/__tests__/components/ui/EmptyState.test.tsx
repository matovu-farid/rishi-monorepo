/**
 * Phase 6 deferred — EmptyState primitive (VIS-013).
 *
 * The icon was rendered at 56pt on `label.tertiary` (~30% gray) which is
 * faded — Apple's empty-state glyphs are ~50pt on `label.secondary`
 * (~60%) with hierarchical rendering. We pin the new sizing/color so the
 * primitive matches HIG.
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { EmptyState } from '@/components/ui/EmptyState'
import { colorsLight } from '@/lib/theme/colors'

describe('EmptyState (mobile)', () => {
  it('renders the icon at 50pt on label.secondary by default (VIS-013)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <EmptyState icon="book-outline" title="No books" />,
      )
    })
    const icon = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'Ionicons',
    )[0]
    expect(icon).toBeTruthy()
    expect((icon.props as { size?: number }).size).toBe(50)
    expect((icon.props as { color?: string }).color).toBe(
      colorsLight.label.secondary,
    )
  })

  it('passes through a custom `tint` to the icon color (VIS-013)', () => {
    // Letting callers override the tint without forking the primitive
    // keeps Apple Books "tinted hierarchical" treatments cheap.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <EmptyState icon="book-outline" title="No books" tint="#FF3B30" />,
      )
    })
    const icon = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'Ionicons',
    )[0]
    expect((icon.props as { color?: string }).color).toBe('#FF3B30')
  })
})
