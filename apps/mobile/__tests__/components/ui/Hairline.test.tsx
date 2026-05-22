/**
 * Phase 2 — Hairline primitive (mobile).
 *
 * A 1-physical-pixel divider matching iOS native separators. Pure View;
 * no animation, no interaction. The horizontal default uses
 * `StyleSheet.hairlineWidth` on `height`, the vertical orientation puts
 * the hairline on `width` instead.
 *
 * Observable behaviour we pin:
 *   1. Horizontal: height === StyleSheet.hairlineWidth, full width.
 *   2. Vertical: width === StyleSheet.hairlineWidth.
 *   3. Custom `color` overrides the theme default.
 *   4. `accessible={false}` because the hairline is decorative.
 */

const __HAIRLINE = 0.5

jest.mock('react-native', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('View', { ...p, ref: r }, p.children),
  )
  return {
    View,
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      hairlineWidth: __HAIRLINE,
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Hairline } from '@/components/ui/Hairline'

function flattenStyle(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) {
    return Object.assign({}, ...style.map((s) => flattenStyle(s)))
  }
  return style as Record<string, unknown>
}

describe('Hairline (mobile)', () => {
  it('horizontal orientation puts hairlineWidth on height', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Hairline />)
    })
    const view = tree.root.findByType('View' as never)
    const style = flattenStyle(
      (view.props as { style?: unknown }).style,
    )
    expect(style.height).toBe(__HAIRLINE)
  })

  it("vertical orientation puts hairlineWidth on width", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Hairline orientation="vertical" />)
    })
    const view = tree.root.findByType('View' as never)
    const style = flattenStyle(
      (view.props as { style?: unknown }).style,
    )
    expect(style.width).toBe(__HAIRLINE)
  })

  it('custom color prop overrides the theme default', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Hairline color="#FF00FF" />)
    })
    const view = tree.root.findByType('View' as never)
    const style = flattenStyle(
      (view.props as { style?: unknown }).style,
    )
    expect(style.backgroundColor).toBe('#FF00FF')
  })

  it('is marked accessible={false} (decorative)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Hairline />)
    })
    const view = tree.root.findByType('View' as never)
    expect((view.props as { accessible?: boolean }).accessible).toBe(false)
  })
})
