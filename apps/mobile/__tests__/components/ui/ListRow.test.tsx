/**
 * Phase 2 — ListRow primitive (mobile).
 *
 * Generic iOS-style list cell. Title + optional subtitle, leading icon,
 * trailing value text, and an accessory (chevron, check, switch, custom).
 * When `onPress` is provided the row wraps in a PressableScale; without
 * onPress it's a plain View.
 *
 * Observable behaviour we pin:
 *   1. Renders the title text
 *   2. Renders the subtitle when provided
 *   3. accessory='chevron' renders an Ionicons chevron-forward
 *   4. onPress provided ➜ tapping the row fires onPress
 *   5. Custom accessory node is rendered as-is
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
    Switch: mk('Switch'),
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

jest.mock('@expo/vector-icons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, Ionicons, default: { Ionicons } }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import { ListRow } from '@/components/ui/ListRow'

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

describe('ListRow (mobile)', () => {
  it('renders the title', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ListRow title="Appearance" />)
    })
    expect(findTextNodes(tree)).toContain('Appearance')
  })

  it('renders the subtitle when provided', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ListRow title="Appearance" subtitle="Light, dark, sepia" />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts).toContain('Appearance')
    expect(texts).toContain('Light, dark, sepia')
  })

  it("accessory='chevron' renders the Ionicons chevron-forward icon", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ListRow title="Appearance" accessory="chevron" />,
      )
    })
    const chevrons = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.type as string) === 'Ionicons' &&
        (n.props as { name?: string }).name === 'chevron-forward',
    )
    expect(chevrons.length).toBe(1)
  })

  it('when onPress is provided, the row is pressable and fires onPress', () => {
    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ListRow title="Appearance" onPress={onPress} />,
      )
    })
    const pressables = tree.root.findAll((n) => n.type === Pressable)
    expect(pressables.length).toBeGreaterThan(0)
    act(() => {
      ;(pressables[0].props as { onPress: () => void }).onPress()
    })
    expect(onPress).toHaveBeenCalledTimes(1)
  })

  it('renders a custom accessory node', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ListRow
          title="Wi-Fi"
          accessory={{
            kind: 'custom',
            node: React.createElement(
              'Text' as never,
              { testID: 'custom-acc' },
              'Custom!',
            ),
          }}
        />,
      )
    })
    expect(findTextNodes(tree)).toContain('Custom!')
  })
})
