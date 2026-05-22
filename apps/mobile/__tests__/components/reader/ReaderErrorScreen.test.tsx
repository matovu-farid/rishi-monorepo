/**
 * ReaderErrorScreen — defect P0-L.
 *
 * The four reader screens (EPUB, PDF, MOBI, DJVU) currently render
 *
 *   <View testID="reader-error"><Text>Book file not available</Text></View>
 *
 * when the load fails. No Back, no Retry, no way for the user to tell
 * whether the cloud download failed or the local file is gone. This is
 * a dead end.
 *
 * The shared `ReaderErrorScreen` must:
 *   1. Render Back and Retry affordances (testIDs:
 *      `reader-error-back-btn`, `reader-error-retry-btn`).
 *   2. Wire `onBack` and `onRetry` to the corresponding presses.
 *   3. Pick its body copy from `cause`:
 *        - 'local-missing'         ➜ "Book file is missing on this device."
 *        - 'cloud-download-failed' ➜ "Couldn't download from the cloud."
 *        - 'unknown' / default     ➜ "Book file not available"
 *   4. Use the EmptyState primitive so it inherits design-token typography,
 *      accent color, and the 44pt pill button.
 *   5. Preserve the existing `reader-error` testID for the four reader
 *      integration tests (and for the e2e suite).
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
    TouchableOpacity: mk('TouchableOpacity'),
    ActivityIndicator: mk('ActivityIndicator'),
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ReaderErrorScreen } from '@/components/reader/ReaderErrorScreen'
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

describe('ReaderErrorScreen (P0-L: shared dead-end fix)', () => {
  it('renders the EmptyState primitive (design-system anchored)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="unknown" onBack={() => {}} onRetry={() => {}} />,
      )
    })
    expect(tree.root.findAllByType(EmptyState).length).toBe(1)
  })

  it('preserves the reader-error testID so the e2e suite keeps working', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="unknown" onBack={() => {}} onRetry={() => {}} />,
      )
    })
    const container = tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === 'reader-error',
    )
    expect(container.length).toBeGreaterThan(0)
  })

  it('renders a Back button (reader-error-back-btn) wired to onBack', () => {
    const onBack = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="unknown" onBack={onBack} onRetry={() => {}} />,
      )
    })
    const backHandlers = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'reader-error-back-btn' &&
        typeof (n.props as { onPress?: () => void }).onPress === 'function',
    )
    expect(backHandlers.length).toBeGreaterThan(0)
    act(() => {
      ;(backHandlers[0].props as { onPress: () => void }).onPress()
    })
    expect(onBack).toHaveBeenCalledTimes(1)
  })

  it('renders a Retry button (reader-error-retry-btn) wired to onRetry', () => {
    const onRetry = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="unknown" onBack={() => {}} onRetry={onRetry} />,
      )
    })
    const retryHandlers = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'reader-error-retry-btn' &&
        typeof (n.props as { onPress?: () => void }).onPress === 'function',
    )
    expect(retryHandlers.length).toBeGreaterThan(0)
    act(() => {
      ;(retryHandlers[0].props as { onPress: () => void }).onPress()
    })
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('uses cause-specific copy for local-missing', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="local-missing" onBack={() => {}} onRetry={() => {}} />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts.some((t) => /missing on this device/i.test(t))).toBe(true)
  })

  it('uses cause-specific copy for cloud-download-failed', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen
          cause="cloud-download-failed"
          onBack={() => {}}
          onRetry={() => {}}
        />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts.some((t) => /couldn'?t download from the cloud/i.test(t))).toBe(
      true,
    )
  })

  it('falls back to generic copy when cause is unknown', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderErrorScreen cause="unknown" onBack={() => {}} onRetry={() => {}} />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts.some((t) => /book file not available/i.test(t))).toBe(true)
  })
})
