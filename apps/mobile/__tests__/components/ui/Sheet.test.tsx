/**
 * Phase 2 — Sheet primitive (mobile).
 *
 * Wraps `@gorhom/bottom-sheet`'s plain BottomSheet with:
 *   - imperative open/close from the `isOpen` prop (no provider needed)
 *   - a backdrop component with `pressBehavior="close"`
 *   - safe-area-aware bottom padding
 *   - optional title row (22pt) + Hairline divider
 *
 * Observable behaviour pinned:
 *   1. Closed (`isOpen=false`): no title text is rendered.
 *   2. Open (`isOpen=true`): title text is visible.
 *   3. The `onChange` callback firing index `-1` calls `onClose`.
 *
 * Mocks: @gorhom/bottom-sheet (passthrough — no gesture handler in node),
 * react-native primitives, react-native-safe-area-context, expo-haptics.
 */

// ── react-native primitives ──────────────────────────────────────────────────
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

// ── safe-area-context ────────────────────────────────────────────────────────
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// ── expo-haptics — noop ──────────────────────────────────────────────────────
jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

// ── Reanimated — sheet may pass animationConfigs; stub minimal surface ───────
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

// ── @gorhom/bottom-sheet — controllable stub.
// We expose the latest `onChange` callback on a captured ref so tests can
// simulate the sheet collapsing to index -1 and check that `onClose` fires.
let __lastOnChange: ((index: number) => void) | null = null
let __backdropPress: (() => void) | null = null

jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  // Captures the `onChange` prop so tests can drive the lifecycle.
  const BottomSheet = React.forwardRef(
    (
      p: {
        onChange?: (i: number) => void
        children?: React.ReactNode
        index?: number
        backdropComponent?: (props: unknown) => React.ReactElement
      },
      _ref: unknown,
    ) => {
      __lastOnChange = p.onChange ?? null
      const backdrop = p.backdropComponent
        ? p.backdropComponent({ animatedIndex: { value: 0 } })
        : null
      // Render children only when the sheet is "open".
      const open = (p.index ?? -1) >= 0
      return React.createElement(
        'BottomSheet',
        p,
        backdrop,
        open ? p.children : null,
      )
    },
  )
  const BottomSheetView = (p: any) =>
    React.createElement('BottomSheetView', p, p.children)
  const BottomSheetScrollView = (p: any) =>
    React.createElement('BottomSheetScrollView', p, p.children)
  // Backdrop stub — captures the close-on-press handler so we can fire it.
  const BottomSheetBackdrop = (p: {
    pressBehavior?: string
    onPress?: () => void
  }) => {
    __backdropPress = p.onPress ?? null
    return React.createElement('BottomSheetBackdrop', p)
  }
  return {
    __esModule: true,
    default: BottomSheet,
    BottomSheetView,
    BottomSheetScrollView,
    BottomSheetBackdrop,
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Sheet } from '@/components/ui/Sheet'

beforeEach(() => {
  __lastOnChange = null
  __backdropPress = null
})

function findTextNodes(root: TestRenderer.ReactTestRenderer): string[] {
  const out: string[] = []
  const visit = (
    node: TestRenderer.ReactTestRendererJSON | string | null,
  ): void => {
    if (node === null) return
    if (typeof node === 'string') {
      out.push(node)
      return
    }
    if (Array.isArray(node.children)) {
      for (const c of node.children)
        visit(c as TestRenderer.ReactTestRendererJSON | string)
    }
  }
  const json = root.toJSON()
  if (Array.isArray(json)) for (const j of json) visit(j)
  else visit(json)
  return out
}

function hasText(
  root: TestRenderer.ReactTestRenderer,
  needle: string,
): boolean {
  return findTextNodes(root).some((t) => t.includes(needle))
}

describe('Sheet (mobile)', () => {
  it('does not render title text when isOpen=false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <Sheet isOpen={false} onClose={() => undefined} title="Bookmarks">
          <></>
        </Sheet>,
      )
    })
    expect(hasText(tree, 'Bookmarks')).toBe(false)
  })

  it('renders the title text when isOpen=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <Sheet isOpen={true} onClose={() => undefined} title="Bookmarks">
          <></>
        </Sheet>,
      )
    })
    expect(hasText(tree, 'Bookmarks')).toBe(true)
  })

  it('calls onClose when the sheet collapses to index -1', () => {
    const onClose = jest.fn()
    act(() => {
      TestRenderer.create(
        <Sheet isOpen={true} onClose={onClose} title="Bookmarks">
          <></>
        </Sheet>,
      )
    })
    // Simulate the user dismissing the sheet (gorhom fires onChange(-1)).
    expect(__lastOnChange).toBeTruthy()
    act(() => {
      __lastOnChange?.(-1)
    })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('renders children inside the sheet body when open', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <Sheet isOpen={true} onClose={() => undefined}>
          {React.createElement(
            'Text' as never,
            { testID: 'sheet-child' },
            'inside the sheet',
          )}
        </Sheet>,
      )
    })
    expect(hasText(tree, 'inside the sheet')).toBe(true)
  })
})
