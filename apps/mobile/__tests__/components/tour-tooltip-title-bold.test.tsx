/**
 * Issue #91 (VIS-031) — TourTooltip title uses semibold (`600`) but the
 * onboarding spec calls for `bold` (`700`) so the heading is unambiguous
 * against the body copy.
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: Record<string, unknown>, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, (p as { children?: unknown }).children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    TouchableOpacity: mk('TouchableOpacity'),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      flatten: (s: unknown) => s,
    },
    Dimensions: {
      get: () => ({ width: 390, height: 844 }),
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { TourTooltip } from '@/components/onboarding/TourTooltip'

const baseProps = {
  step: {
    id: 's1',
    title: 'Welcome',
    description: 'Tap the orb to start chatting.',
    position: 'below' as const,
    target: 'orb' as const,
  },
  stepIndex: 0,
  totalSteps: 3,
  target: { x: 100, y: 100, width: 80, height: 80 },
  onNext: () => {},
  onSkip: () => {},
}

describe('TourTooltip title weight (#91)', () => {
  it('title text uses fontWeight 700 (bold)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TourTooltip {...baseProps} />)
    })
    const titleNodes = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        n.type === 'Text' &&
        Array.isArray(n.children) &&
        n.children.some((c) => c === 'Welcome'),
    )
    expect(titleNodes.length).toBeGreaterThan(0)
    const titleNode = titleNodes[0]
    const raw = titleNode.props.style as unknown
    const styles = (Array.isArray(raw) ? raw : [raw]) as Array<{
      fontWeight?: string
    }>
    const weight = styles
      .map((s) => s?.fontWeight)
      .find((w) => typeof w === 'string')
    expect(weight).toBe('700')
    act(() => tree.unmount())
  })
})
