/**
 * PRF-006 (#111) — AnnotationPopover swatch rendering must not
 * allocate a fresh swatch-element array on every render. The fix is
 * to memoise the rendered swatch row with `useMemo` keyed on the
 * inputs that actually change (the currently-selected color, the
 * theme border colour, and the change handler). When those inputs
 * are stable across re-renders the same React element array is
 * returned by reference.
 *
 * Behaviour pinned here:
 *   1. While the swatch row is open (`showColors=true`) a re-render
 *      with the SAME props returns the same swatch element list — i.e.
 *      the underlying React elements are reference-equal.
 *   2. All four palette colours are still rendered (yellow, green,
 *      blue, pink) so we don't accidentally drop a swatch when
 *      memoising.
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
    TouchableOpacity: mk('TouchableOpacity'),
    Alert: { alert: jest.fn() },
    Dimensions: { get: () => ({ width: 390, height: 844 }) },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
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
    FadeIn: { duration: () => ({}) },
    FadeOut: { duration: () => ({}) },
  }
})

jest.mock('@/lib/theme', () => ({
  useTheme: () => ({
    colors: {
      accent: { error: '#FF3B30' },
    },
  }),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { AnnotationPopover } from '@/components/AnnotationPopover'
import type { Highlight } from '@/types/highlight'

const highlight: Highlight = {
  id: 'h1',
  bookId: 'b1',
  cfiRange: 'epubcfi(/6/2!/4)',
  text: 'A snippet of text',
  color: 'yellow',
  note: null,
  chapter: null,
  createdAt: 1,
  updatedAt: 2,
}

const readerTheme = {
  toolbarBg: '#222',
  toolbarText: '#fff',
} as any

// Stable callbacks captured at module scope so re-renders pass the
// same function reference into the popover.
const stableOnEditNote = () => {}
const stableOnDelete = () => {}
const stableOnDismiss = () => {}
const stableOnChangeColor = () => {}
const stablePosition = { x: 100, y: 200 }

describe('AnnotationPopover swatch row (PRF-006 / #111)', () => {
  it('renders all four palette colours when the swatch row is open', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AnnotationPopover
          visible
          highlight={highlight}
          position={{ x: 100, y: 200 }}
          theme={readerTheme}
          onEditNote={() => {}}
          onChangeColor={() => {}}
          onDelete={() => {}}
          onDismiss={() => {}}
        />,
      )
    })
    // Open the swatch row by tapping the Color button.
    const colorBtn = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.type as string) === 'TouchableOpacity' &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Change Color',
    )[0]
    expect(colorBtn).not.toBeUndefined()
    act(() => {
      ;(colorBtn!.props as { onPress?: () => void }).onPress?.()
    })

    const paletteNames = ['yellow', 'green', 'blue', 'pink']
    const swatches = tree.root.findAll((n) => {
      if (typeof n.type !== 'string' || (n.type as string) !== 'TouchableOpacity') {
        return false
      }
      const label = (n.props as { accessibilityLabel?: string })
        .accessibilityLabel
      if (typeof label !== 'string') return false
      return paletteNames.some((p) => label === `${p} highlight`)
    })
    expect(swatches.length).toBe(4)
  })

  it('memoises the swatch element list across re-renders with stable inputs', () => {
    function renderPopover(): React.ReactElement {
      return (
        <AnnotationPopover
          visible
          highlight={highlight}
          position={stablePosition}
          theme={readerTheme}
          onEditNote={stableOnEditNote}
          onChangeColor={stableOnChangeColor}
          onDelete={stableOnDelete}
          onDismiss={stableOnDismiss}
        />
      )
    }
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(renderPopover())
    })
    // Open the swatch row.
    const colorBtn = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.type as string) === 'TouchableOpacity' &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Change Color',
    )[0]
    act(() => {
      ;(colorBtn!.props as { onPress?: () => void }).onPress?.()
    })

    const paletteNames = ['yellow', 'green', 'blue', 'pink']
    function captureSwatchList(): unknown {
      const swatches = tree.root.findAll((n) => {
        if (typeof n.type !== 'string' || (n.type as string) !== 'TouchableOpacity') {
          return false
        }
        const label = (n.props as { accessibilityLabel?: string })
          .accessibilityLabel
        return (
          typeof label === 'string' &&
          paletteNames.some((p) => label === `${p} highlight`)
        )
      })
      // Read the `children` of the wrapping swatch row — the parent
      // of any swatch. The memoised JSX array sits on that prop so
      // we can compare its identity across renders.
      const parent = swatches[0]!.parent!
      return (parent.props as { children?: unknown }).children
    }

    const before = captureSwatchList()
    // Trigger a re-render with the same stable inputs; the memoised
    // element array should be returned by reference.
    act(() => {
      tree.update(renderPopover())
    })
    const after = captureSwatchList()
    expect(after).toBe(before)
  })
})
