/**
 * Phase 2 — PressableScale primitive (mobile).
 *
 * Renders children inside an Animated.View whose transform.scale is
 * driven by a Reanimated shared value. On press-in the value drops to
 * `props.scale ?? 0.95`; on press-out it returns to 1. When
 * `useTheme().reduceMotion === true` the primitive substitutes an opacity
 * fade for the transform.
 *
 * Observable behaviour we pin:
 *   1. Renders children
 *   2. onPress fires on press
 *   3. The transform shared value reaches 0.95 after a press-in
 *   4. reduceMotion=true skips the scale transform (sharedValue stays 1)
 *
 * The Reanimated mock captures every `useSharedValue` result so tests can
 * inspect `.value` directly after firing onPressIn / onPressOut. We also
 * lift `withSpring` / `withTiming` to write the target value through
 * synchronously — Reanimated's real implementation is async, but the
 * shared-value primitive itself updates `.value` immediately.
 */

// ── Capture every shared value created during a render ───────────────────────
type SharedValueLike = { value: unknown }
const __sharedValues: SharedValueLike[] = []

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  const useSharedValue = (v: unknown) => {
    const ref = { value: v }
    __sharedValues.push(ref)
    return ref
  }
  // withSpring / withTiming return the target value; the primitive
  // assigns it to `shared.value` synchronously.
  const withSpring = (v: unknown) => v
  const withTiming = (v: unknown) => v
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue,
    useAnimatedStyle: (cb: () => unknown) => {
      try {
        return cb()
      } catch {
        return {}
      }
    },
    withSpring,
    withTiming,
    Easing: { out: () => null, quad: null, inOut: () => null },
  }
})

// ── react-native primitives ──────────────────────────────────────────────────
let __reduceMotion = false
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
      isReduceMotionEnabled: jest.fn(async () => __reduceMotion),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { PressableScale } from '@/components/ui/PressableScale'

beforeEach(() => {
  __sharedValues.length = 0
  __reduceMotion = false
})

function findFirstPressable(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance {
  return tree.root.findAll(
    (n) => typeof n.type === 'string' && n.type === 'Pressable',
  )[0]
}

function findScaleSharedValue(): SharedValueLike | undefined {
  // The component is expected to initialise a numeric shared value at 1
  // (the resting scale). The first such shared value is the scale.
  return __sharedValues.find(
    (sv) => typeof sv.value === 'number' && sv.value === 1,
  )
}

describe('PressableScale (mobile)', () => {
  it('renders its children', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <PressableScale
          onPress={() => undefined}
          accessibilityLabel="Continue"
        >
          {React.createElement('Text' as never, null, 'tap me')}
        </PressableScale>,
      )
    })
    const json = tree.toJSON()
    const str = JSON.stringify(json)
    expect(str).toContain('tap me')
  })

  it('fires onPress when the underlying Pressable is pressed', () => {
    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <PressableScale onPress={onPress} accessibilityLabel="Continue">
          {React.createElement('Text' as never, null, 'x')}
        </PressableScale>,
      )
    })
    const pressable = findFirstPressable(tree)
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(onPress).toHaveBeenCalledTimes(1)
  })

  it('scale shared value reaches 0.95 on press-in', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <PressableScale onPress={() => undefined} accessibilityLabel="Continue">
          {React.createElement('Text' as never, null, 'x')}
        </PressableScale>,
      )
    })
    const pressable = findFirstPressable(tree)
    const scale = findScaleSharedValue()
    expect(scale).toBeDefined()
    act(() => {
      ;(pressable.props as { onPressIn: () => void }).onPressIn()
    })
    expect(scale!.value).toBe(0.95)
  })

  it('scale shared value returns to 1 on press-out', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <PressableScale onPress={() => undefined} accessibilityLabel="Continue">
          {React.createElement('Text' as never, null, 'x')}
        </PressableScale>,
      )
    })
    const pressable = findFirstPressable(tree)
    const scale = findScaleSharedValue()
    act(() => {
      ;(pressable.props as { onPressIn: () => void }).onPressIn()
      ;(pressable.props as { onPressOut: () => void }).onPressOut()
    })
    expect(scale!.value).toBe(1)
  })

  it('skips the scale transform when reduceMotion is true', async () => {
    __reduceMotion = true
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(
        <PressableScale onPress={() => undefined} accessibilityLabel="Continue">
          {React.createElement('Text' as never, null, 'x')}
        </PressableScale>,
      )
    })
    // Allow the effect that reads AccessibilityInfo to flush.
    await act(async () => {
      await Promise.resolve()
    })
    const pressable = findFirstPressable(tree)
    const scale = findScaleSharedValue()
    act(() => {
      ;(pressable.props as { onPressIn: () => void }).onPressIn()
    })
    // Reduce-motion: scale stays put — primitive uses opacity instead.
    expect(scale!.value).toBe(1)
  })
})
