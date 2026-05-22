/**
 * Phase 2 — SegmentedControl primitive (mobile).
 *
 * Apple-style three-up (or N-up) tab control. The pill behind the selected
 * segment animates on change; selection emits a haptic.
 *
 * Observable behaviour we pin:
 *   1. Renders every option's label
 *   2. Tapping a non-selected segment fires onChange with that value
 *   3. Active segment's accessibilityState reflects selected=true
 *   4. Non-selected segments report selected=false
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

const selectionAsync = jest.fn()
jest.mock('expo-haptics', () => ({
  selectionAsync,
  impactAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import { SegmentedControl } from '@/components/ui/SegmentedControl'

beforeEach(() => {
  selectionAsync.mockClear()
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

describe('SegmentedControl (mobile)', () => {
  it('renders every option label', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <SegmentedControl
          value="a"
          onChange={() => undefined}
          options={[
            { label: 'Sans', value: 'a' },
            { label: 'Serif', value: 'b' },
            { label: 'Mono', value: 'c' },
          ]}
        />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts).toEqual(expect.arrayContaining(['Sans', 'Serif', 'Mono']))
  })

  it('fires onChange with the new value when a non-selected segment is pressed', () => {
    const onChange = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <SegmentedControl
          value="a"
          onChange={onChange}
          options={[
            { label: 'Sans', value: 'a' },
            { label: 'Serif', value: 'b' },
          ]}
        />,
      )
    })
    // Find a Pressable whose accessibilityLabel matches the unselected option.
    const target = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Serif',
    )[0]
    expect(target).toBeTruthy()
    act(() => {
      ;(target.props as { onPress: () => void }).onPress()
    })
    expect(onChange).toHaveBeenCalledWith('b')
  })

  it("active segment carries accessibilityState.selected=true", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <SegmentedControl
          value="b"
          onChange={() => undefined}
          options={[
            { label: 'Sans', value: 'a' },
            { label: 'Serif', value: 'b' },
          ]}
        />,
      )
    })
    const active = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel === 'Serif',
    )[0]
    expect(
      (active.props as { accessibilityState?: { selected?: boolean } })
        .accessibilityState?.selected,
    ).toBe(true)
  })

  it('inner pill radius is fully capsular for the control height (VIS-016)', () => {
    // VIS-016: UISegmentedControl's inner pill is fully rounded — the
    // outer container has a 2pt inset, so the inner pill should be
    // `(height - 4) / 2`. The old `radius.lg - 2` (12pt) left visible
    // straight edges at typical 36pt heights.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <SegmentedControl
          value="a"
          onChange={() => undefined}
          options={[
            { label: 'A', value: 'a' },
            { label: 'B', value: 'b' },
          ]}
          size="md"
        />,
      )
    })
    // Find the indicator pill (Animated.View) and read its borderRadius.
    const pills = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'Animated.View',
    )
    const radii: number[] = []
    for (const p of pills) {
      const style = (p.props as { style?: unknown }).style
      const styles = Array.isArray(style) ? style : [style]
      for (const s of styles) {
        if (s && typeof (s as Record<string, unknown>).borderRadius === 'number') {
          radii.push((s as { borderRadius: number }).borderRadius)
        }
      }
    }
    // size="md" => height 36, inner pill should be (36 - 4) / 2 = 16.
    expect(radii).toContain(16)
  })

  it('non-selected segment carries accessibilityState.selected=false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <SegmentedControl
          value="b"
          onChange={() => undefined}
          options={[
            { label: 'Sans', value: 'a' },
            { label: 'Serif', value: 'b' },
          ]}
        />,
      )
    })
    const inactive = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel === 'Sans',
    )[0]
    expect(
      (inactive.props as { accessibilityState?: { selected?: boolean } })
        .accessibilityState?.selected,
    ).toBe(false)
  })
})
