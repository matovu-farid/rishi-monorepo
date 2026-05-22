/**
 * Phase 2 — IconButton primitive (mobile).
 *
 * Wraps `PressableScale` + `@expo/vector-icons` Ionicons. Required behaviour:
 *   - `onPress` fires on press
 *   - `accessibilityLabel` reflects the `label` prop
 *   - haptic fires per the `haptic` prop (default `'selection'`)
 *   - default `hitSlop` inflates the touch target ≥ 44pt (UI-SPEC §10.3)
 *
 * Mocks: react-native primitives, Ionicons (returns a Text-ish stub),
 * expo-haptics (spies), Reanimated (stub), safe-area-context.
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
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
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

const impactAsync = jest.fn()
const selectionAsync = jest.fn()
jest.mock('expo-haptics', () => ({
  impactAsync,
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import { IconButton } from '@/components/ui/IconButton'

beforeEach(() => {
  impactAsync.mockClear()
  selectionAsync.mockClear()
})

/**
 * Find the outermost Pressable in the tree. PressableScale wraps a
 * react-native Pressable; the host element name from our mock is
 * `'Pressable'`.
 */
function findFirstPressable(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance {
  return tree.root.findAll((n) => n.type === Pressable)[0]
}

describe('IconButton (mobile)', () => {
  it('fires onPress when pressed', () => {
    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <IconButton name="bookmark" label="Bookmark page" onPress={onPress} />,
      )
    })
    const pressable = findFirstPressable(tree)
    expect(pressable).toBeTruthy()
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(onPress).toHaveBeenCalledTimes(1)
  })

  it('renders the accessibilityLabel from the `label` prop', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <IconButton
          name="bookmark"
          label="Bookmark page"
          onPress={() => undefined}
        />,
      )
    })
    // Find any node carrying our accessibility label.
    const labelled = tree.root.findAll(
      (n) =>
        (n.props as { accessibilityLabel?: string } | null)?.accessibilityLabel ===
        'Bookmark page',
    )
    expect(labelled.length).toBeGreaterThan(0)
  })

  it('fires Haptics.selectionAsync on press by default', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <IconButton
          name="bookmark"
          label="Bookmark page"
          onPress={() => undefined}
        />,
      )
    })
    const pressable = findFirstPressable(tree)
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(selectionAsync).toHaveBeenCalledTimes(1)
  })

  it("fires Haptics.selectionAsync when haptic='selection' is explicit", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <IconButton
          name="bookmark"
          label="Bookmark page"
          haptic="selection"
          onPress={() => undefined}
        />,
      )
    })
    const pressable = findFirstPressable(tree)
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(selectionAsync).toHaveBeenCalledTimes(1)
  })

  it('default hitSlop inflates the touch target to ≥ 44pt around a 22pt icon', () => {
    // 22pt icon + ≥ 11pt of hitSlop on each side = ≥ 44pt total. UI-SPEC §10.3.
    // Default hitSlop is documented as 8 on each side in ARCH §3c — that
    // takes a 22pt icon to 38pt total, which fails this rule. The test
    // pins the spec, not the architect's implementation hint. The coder
    // can raise the default to satisfy this; small visual change only.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <IconButton name="bookmark" label="Bookmark page" onPress={() => undefined} />,
      )
    })
    const pressable = findFirstPressable(tree)
    const hitSlop = (pressable.props as { hitSlop?: unknown }).hitSlop
    expect(hitSlop).toBeDefined()
    const inflate = (slop: unknown): number => {
      if (typeof slop === 'number') return slop
      const s = slop as { top?: number; bottom?: number; left?: number; right?: number }
      // Use the smallest pair (effective minimum target dimension).
      const horiz = (s.left ?? 0) + (s.right ?? 0)
      const vert = (s.top ?? 0) + (s.bottom ?? 0)
      return Math.min(horiz, vert)
    }
    // 22pt icon size + (2 × hitSlop) ≥ 44pt
    const slopValue = typeof hitSlop === 'number' ? hitSlop * 2 : inflate(hitSlop)
    expect(22 + slopValue).toBeGreaterThanOrEqual(44)
  })
})
