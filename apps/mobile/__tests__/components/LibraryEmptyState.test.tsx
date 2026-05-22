/**
 * LibraryEmptyState (mobile) — defect P1-U.
 *
 * The component must be implemented on top of the shared `EmptyState`
 * primitive (not bespoke layout). That guarantees it picks up the
 * design-token accent color, `radius.full` pill button, and 44pt iOS
 * button height for free. The bespoke implementation hardcoded
 * `bg-[#0a7ea4]` + `rounded-lg` which bypassed the design system.
 *
 * We pin:
 *   1. Renders the EmptyState primitive instance (proves we're not
 *      hand-rolling a bespoke layout that drifts from the design system).
 *   2. Preserves the existing testIDs so the Detox suite
 *      (`library-empty-state`, `library-empty-title`,
 *      `library-empty-import-btn`) keeps working.
 *   3. Preserves the user-visible strings the e2e tests grep for
 *      ("No books yet", "Import an EPUB or PDF…", "Import Book").
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
    ActivityIndicator: mk('ActivityIndicator'),
    TouchableOpacity: mk('TouchableOpacity'),
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
  selectionAsync: jest.fn(),
  impactAsync: jest.fn(),
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

// The IconSymbol module historically used in LibraryEmptyState; mocked so
// the legacy "book.fill" SF symbol doesn't blow up node-land jest.
jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { LibraryEmptyState } from '@/components/LibraryEmptyState'
import { EmptyState } from '@/components/ui/EmptyState'

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

describe('LibraryEmptyState (P1-U: uses EmptyState primitive)', () => {
  it('renders an EmptyState primitive instance (not bespoke layout)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <LibraryEmptyState onImport={() => {}} importing={false} />,
      )
    })
    const empties = tree.root.findAllByType(EmptyState)
    expect(empties.length).toBe(1)
  })

  it('preserves Detox testIDs (library-empty-state, library-empty-import-btn)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <LibraryEmptyState onImport={() => {}} importing={false} />,
      )
    })
    const container = tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === 'library-empty-state',
    )
    expect(container.length).toBeGreaterThan(0)
    const btn = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'library-empty-import-btn',
    )
    expect(btn.length).toBeGreaterThan(0)
  })

  it('preserves user-visible copy', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <LibraryEmptyState onImport={() => {}} importing={false} />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts).toContain('No books yet')
    expect(texts).toContain(
      'Import an EPUB or PDF from your device to start reading.',
    )
    expect(texts).toContain('Import Book')
  })

  it('fires onImport when the action is pressed', () => {
    const onImport = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <LibraryEmptyState onImport={onImport} importing={false} />,
      )
    })
    // EmptyState renders the action inside a PressableScale (Pressable host).
    // Find any node whose accessibilityLabel is "Import Book" and fire its
    // onPress.
    const handlers = tree.root.findAll(
      (n) =>
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Import Book' &&
        typeof (n.props as { onPress?: () => void }).onPress === 'function',
    )
    expect(handlers.length).toBeGreaterThan(0)
    act(() => {
      ;(handlers[0].props as { onPress: () => void }).onPress()
    })
    expect(onImport).toHaveBeenCalledTimes(1)
  })
})
