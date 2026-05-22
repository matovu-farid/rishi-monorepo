/**
 * Phase 2 — BookCover primitive (mobile).
 *
 * Wraps `expo-image`'s Image with rounded corners and an elevation shadow.
 * When `uri` is missing (or the image errored), renders a deterministic
 * letter fallback derived from the first character of `title`.
 *
 * Observable behaviour we pin:
 *   1. `uri` provided ➜ renders the expo-image Image
 *   2. `uri` missing ➜ renders the title's first letter as fallback
 *   3. Sizes follow the UI-SPEC §7f map (sm=48, md=96, lg=144)
 *   4. accessibilityLabel encodes the title
 *
 * The prompt mentions a "PDF tint" for fallback colors. UI-SPEC §7f /
 * ARCH §3f use a deterministic hash-of-title fallback palette, not a
 * per-format tint. We therefore verify that the fallback background is
 * a non-empty string and that two calls with the same title return the
 * same color (deterministic), rather than coupling to a specific PDF hue.
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

// expo-image's <Image> renders as a host node with testID we can find.
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

describe('BookCover (mobile)', () => {
  it('renders the expo-image Image when uri is provided', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri="file:///tmp/c.png" title="Dune" size="md" />,
      )
    })
    const images = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'ExpoImage',
    )
    expect(images.length).toBe(1)
  })

  it("renders the title's first letter as fallback when uri is missing", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
    })
    const texts = findTextNodes(tree)
    // Sentinel — first letter uppercased.
    expect(texts.some((t) => t === 'D')).toBe(true)
  })

  it('falls back to a deterministic color for the same title', () => {
    let treeA!: TestRenderer.ReactTestRenderer
    let treeB!: TestRenderer.ReactTestRenderer
    act(() => {
      treeA = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
      treeB = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
    })
    const grabBg = (
      tree: TestRenderer.ReactTestRenderer,
    ): unknown => {
      const views = tree.root.findAll(
        (n) => typeof n.type === 'string' && (n.type as string) === 'View',
      )
      // The fallback container's style.backgroundColor is the deterministic colour.
      for (const v of views) {
        const style = flattenStyle((v.props as { style?: unknown }).style)
        if (style.backgroundColor) return style.backgroundColor
      }
      return undefined
    }
    const bgA = grabBg(treeA)
    const bgB = grabBg(treeB)
    expect(typeof bgA).toBe('string')
    expect((bgA as string).length).toBeGreaterThan(0)
    expect(bgA).toBe(bgB)
  })

  it('size="sm" renders at 48pt wide (UI-SPEC §7f)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="sm" />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const widths = views
      .map((v) => flattenStyle((v.props as { style?: unknown }).style).width)
      .filter((w): w is number => typeof w === 'number')
    expect(widths).toContain(48)
  })

  it('size="md" renders at 96pt wide (UI-SPEC §7f)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const widths = views
      .map((v) => flattenStyle((v.props as { style?: unknown }).style).width)
      .filter((w): w is number => typeof w === 'number')
    expect(widths).toContain(96)
  })

  it('size="lg" renders at 144pt wide (UI-SPEC §7f)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="lg" />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const widths = views
      .map((v) => flattenStyle((v.props as { style?: unknown }).style).width)
      .filter((w): w is number => typeof w === 'number')
    expect(widths).toContain(144)
  })

  it('omits the hairline border when a real cover image is shown (VIS-008)', () => {
    // VIS-008: the unconditional hairline draws a visible line around full-bleed
    // covers. Apple Books only shows that border on placeholder / letter-tile
    // fallbacks, so when `uri` is provided the cover should float on the shadow
    // alone (no border).
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri="file:///tmp/c.png" title="Dune" size="md" />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    // No View in the tree should set a non-zero borderWidth when a real
    // cover is being displayed.
    for (const v of views) {
      const style = flattenStyle((v.props as { style?: unknown }).style)
      if (typeof style.borderWidth === 'number') {
        expect(style.borderWidth).toBe(0)
      }
    }
  })

  it('keeps the hairline border on letter-tile fallback (VIS-008 inverse)', () => {
    // VIS-008 inverse: when the cover is a generated fallback we still want a
    // crisp border so the tile reads as a "cover-shaped" surface.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri={undefined} title="Dune" size="md" />,
      )
    })
    const views = tree.root.findAll(
      (n) => typeof n.type === 'string' && (n.type as string) === 'View',
    )
    const borderWidths = views
      .map((v) => flattenStyle((v.props as { style?: unknown }).style).borderWidth)
      .filter((w): w is number => typeof w === 'number')
    // At least one wrapping view should request a hairline border in fallback.
    expect(borderWidths.some((w) => w > 0)).toBe(true)
  })

  it('exposes accessibilityRole="image" and label includes the title', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <BookCover uri="file:///tmp/c.png" title="Dune" size="md" />,
      )
    })
    const labelled = tree.root.findAll(
      (n) => {
        const props = n.props as {
          accessibilityRole?: string
          accessibilityLabel?: string
        } | null
        return (
          props?.accessibilityRole === 'image' &&
          typeof props.accessibilityLabel === 'string' &&
          props.accessibilityLabel.includes('Dune')
        )
      },
    )
    expect(labelled.length).toBeGreaterThan(0)
  })
})
