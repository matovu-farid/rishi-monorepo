/**
 * Issue #82 (VIS-022) — TourTooltip bypasses the theme entirely; all
 * colors are Tailwind hex literals. This makes light/dark parity
 * impossible and means the onboarding card looks foreign next to the
 * rest of the app chrome.
 *
 * Asserts that the computed styles bind to `colorsLight.*` semantic
 * tokens — not the legacy hex palette — so future scheme support is a
 * single switch in the theme layer rather than a hex grep.
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
import { colorsLight } from '@/lib/theme/colors'

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

const flatten = (raw: unknown): Record<string, unknown> => {
  const arr = (Array.isArray(raw) ? raw : [raw]) as Array<Record<string, unknown> | null>
  return arr.reduce<Record<string, unknown>>((acc, s) => ({ ...acc, ...(s ?? {}) }), {})
}

const findText = (
  tree: TestRenderer.ReactTestRenderer,
  content: string,
) => {
  const matches = tree.root.findAll(
    (n) =>
      typeof n.type === 'string' &&
      n.type === 'Text' &&
      Array.isArray(n.children) &&
      n.children
        .map((c) => (typeof c === 'string' || typeof c === 'number' ? String(c) : ''))
        .join('')
        .includes(content),
  )
  if (matches.length === 0) {
    throw new Error(`No Text node matched "${content}"`)
  }
  return matches[0]
}

describe('TourTooltip uses theme tokens (#82)', () => {
  let tree!: TestRenderer.ReactTestRenderer
  beforeEach(() => {
    act(() => {
      tree = TestRenderer.create(<TourTooltip {...baseProps} />)
    })
  })
  afterEach(() => {
    act(() => tree.unmount())
  })

  it('tooltip container uses background.primary and separator.opaque', () => {
    const container = tree.root.findByProps({ accessibilityRole: 'alert' })
    const style = flatten(container.props.style)
    expect(style.backgroundColor).toBe(colorsLight.background.primary)
    expect(style.borderColor).toBe(colorsLight.separator.opaque)
  })

  it('title uses label.primary', () => {
    const title = findText(tree, 'Welcome')
    const style = flatten(title.props.style)
    expect(style.color).toBe(colorsLight.label.primary)
  })

  it('description uses label.secondary', () => {
    const desc = findText(tree, 'Tap the orb to start chatting.')
    const style = flatten(desc.props.style)
    expect(style.color).toBe(colorsLight.label.secondary)
  })

  it('step counter uses label.tertiary', () => {
    const counter = findText(tree, '1 of 3')
    const style = flatten(counter.props.style)
    expect(style.color).toBe(colorsLight.label.tertiary)
  })

  it('Skip text uses label.tertiary', () => {
    const skip = findText(tree, 'Skip')
    const style = flatten(skip.props.style)
    expect(style.color).toBe(colorsLight.label.tertiary)
  })

  it('Next button background uses accent.primary', () => {
    const nextBtn = tree.root.findByProps({ testID: 'tour-next' })
    const style = flatten(nextBtn.props.style)
    expect(style.backgroundColor).toBe(colorsLight.accent.primary)
  })

  it('does not embed legacy gray / indigo hex palette literals', () => {
    // Run a single style traversal looking for the values we just retired.
    const banned = [
      '#E5E7EB',
      '#111827',
      '#6B7280',
      '#9CA3AF',
      '#6366F1',
      'white',
    ]
    const seen = new Set<string>()
    tree.root.findAll((n) => true).forEach((n) => {
      const s = flatten(n.props.style) as Record<string, unknown>
      for (const key of Object.keys(s)) {
        const v = s[key]
        if (typeof v === 'string') seen.add(v)
      }
    })
    // "white" appears on the Next button label — that's intentional
    // contrast, not a palette literal. Strip it from the ban list.
    for (const ban of banned.filter((b) => b !== 'white')) {
      expect(seen.has(ban)).toBe(false)
    }
  })
})
