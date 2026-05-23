/**
 * BookCover — critic-sweep fix #96 / STA-021.
 *
 * Last-read hero pill used to render the same hash-based letter
 * fallback as any row, which gave the user no "cover pending" signal
 * for books whose cover extraction was still in flight (or which had
 * been deferred). The fix surfaces a NEW `loading` prop on BookCover:
 *
 *   - `loading={true}`  ➜ dotted-border placeholder, NO letter glyph
 *   - `loading={false}` + uri missing ➜ existing letter-tile fallback
 *   - `loading={false}` + uri present ➜ real image
 *
 * The placeholder must be visually distinct from the letter fallback
 * (no first-letter Text, dotted/dashed border style applied) so that
 * screen-reader users + sighted users alike can tell "cover loading"
 * apart from "no cover available".
 *
 * Red signal: BookCover does not accept a `loading` prop.
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

jest.mock('expo-image', () => {
  const React = require('react')
  const Image = (p: any) =>
    React.createElement('ExpoImage', { testID: 'expo-image', ...p })
  return { __esModule: true, Image }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { BookCover } from '@/components/ui/BookCover'

function flattenStyle(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) {
    return Object.assign({}, ...style.map((s) => flattenStyle(s)))
  }
  return style as Record<string, unknown>
}

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

describe('BookCover (#96 / STA-021: loading placeholder)', () => {
  it('does NOT render the letter-tile glyph when loading=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" loading />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts).not.toContain('D')
  })

  it('exposes a `book-cover-loading` testID when loading=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" loading />,
      )
    })
    const placeholder = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === 'book-cover-loading',
    )
    expect(placeholder.length).toBeGreaterThan(0)
  })

  it('applies a dashed border style (visually distinct from letter tile)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" loading />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const borderStyles = views
      .map((v) => flattenStyle((v.props as { style?: unknown }).style).borderStyle)
      .filter((s): s is string => typeof s === 'string')
    // At least one wrapping view should request a dashed/dotted border.
    expect(borderStyles.some((s) => s === 'dashed' || s === 'dotted')).toBe(true)
  })

  it('exposes a loading-aware accessibilityLabel', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" loading />,
      )
    })
    // The label should communicate the "cover loading" intent rather
    // than just "Cover of Dune".
    const labelled = tree.root.findAll((n) => {
      const lbl = (n.props as { accessibilityLabel?: string } | null)
        ?.accessibilityLabel
      return (
        typeof lbl === 'string' &&
        /loading|extracting|pending/i.test(lbl) &&
        lbl.includes('Dune')
      )
    })
    expect(labelled.length).toBeGreaterThan(0)
  })

  it('falls back to the existing letter tile when loading=false and uri is missing', () => {
    // Inverse: when the cover is genuinely unavailable (no uri,
    // loading=false, extraction NOT in flight), the existing
    // hash-of-title letter fallback should still render. We don't want
    // the dotted placeholder to leak into the steady-state empty case.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
    })
    const texts = findTextNodes(tree)
    expect(texts.some((t) => t === 'D')).toBe(true)
    // And no `book-cover-loading` testID.
    const placeholder = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === 'book-cover-loading',
    )
    expect(placeholder.length).toBe(0)
  })

  it('does NOT render the real image when loading=true (even with a uri)', () => {
    // If somehow both a uri and loading=true are provided, the
    // placeholder wins so the user gets the "pending" signal until the
    // caller confirms cover availability.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover
          uri="file:///tmp/c.png"
          title="Dune"
          size="md"
          loading
        />,
      )
    })
    const images = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'ExpoImage',
    )
    expect(images.length).toBe(0)
  })
})
