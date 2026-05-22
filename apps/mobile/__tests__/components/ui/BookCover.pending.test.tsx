/**
 * STA-021 — distinguish "no cover yet" (pending) from "letter fallback"
 * on the BookCover primitive.
 *
 * PDF/DJVU covers are extracted lazily (the import path returns null —
 * see `lib/book-import/adapters.ts:407-410`). With the library "Reading
 * Now" card surfacing the same letter tile for both genuine letter
 * fallback AND not-yet-extracted PDF covers, the user can't tell the
 * difference between "this book has no cover" and "the cover is still
 * coming."
 *
 * Fix: BookCover accepts a `pending` prop. When true (and `uri` is
 * absent), it renders a dotted-border placeholder with a "skeleton" feel
 * instead of the hash-tinted letter tile. The accessibility label
 * announces the loading state so VoiceOver users get parity.
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

describe('BookCover pending state (STA-021)', () => {
  it('renders a pending-placeholder testID when pending is true and uri is missing', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" pending />,
      )
    })
    const placeholders = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'book-cover-pending',
    )
    expect(placeholders.length).toBeGreaterThanOrEqual(1)
  })

  it('does NOT render the letter when pending', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" pending />,
      )
    })
    const texts = findTextNodes(tree)
    // The single-letter sentinel "D" must NOT appear when we're explicit
    // that the cover hasn't been extracted yet.
    expect(texts.includes('D')).toBe(false)
  })

  it('uses a dashed border instead of the solid hairline on pending', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" pending />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const dashed = views.some((v) => {
      const style = flattenStyle((v.props as { style?: unknown }).style)
      return style.borderStyle === 'dashed' && typeof style.borderWidth === 'number' && style.borderWidth > 0
    })
    expect(dashed).toBe(true)
  })

  it('announces the pending state via accessibilityLabel', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" pending />,
      )
    })
    const labelled = tree.root.findAll((n) => {
      const props = n.props as {
        accessibilityRole?: string
        accessibilityLabel?: string
      } | null
      return (
        props?.accessibilityRole === 'image' &&
        typeof props.accessibilityLabel === 'string' &&
        /preparing|loading|cover/i.test(props.accessibilityLabel)
      )
    })
    expect(labelled.length).toBeGreaterThan(0)
  })

  it('falls back to the letter tile when pending is false and uri is missing', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" />,
      )
    })
    const placeholders = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'book-cover-pending',
    )
    expect(placeholders.length).toBe(0)
    const texts = findTextNodes(tree)
    expect(texts.includes('D')).toBe(true)
  })

  it('still renders the real image when uri is provided even with pending=true (safety)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri="file:///tmp/c.png" title="Dune" size="sm" pending />,
      )
    })
    const images = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'ExpoImage',
    )
    expect(images.length).toBe(1)
    // No pending placeholder when we have a real uri.
    const placeholders = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'book-cover-pending',
    )
    expect(placeholders.length).toBe(0)
  })
})
