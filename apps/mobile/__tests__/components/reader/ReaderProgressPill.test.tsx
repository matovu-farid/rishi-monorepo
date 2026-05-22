/**
 * Phase 3 — ReaderProgressPill (mobile).
 *
 * The pill is a tiny visual primitive that renders different label text
 * depending on the `progress` discriminant. ARCH §1 (Section 1):
 *
 *   - { kind: 'page', current, total }    → "${current} / ${total}"
 *   - { kind: 'chapter', current, total } → "Ch ${current}/${total}"
 *   - { kind: 'cfi', label }              → label (verbatim, e.g. "42%")
 *   - { kind: 'none' }                    → "—"
 *
 * Red signal: the module at `@/components/reader/ReaderProgressPill`
 * does not exist yet. All 4 tests must fail at import time.
 *
 * Mocks: react-native primitives, safe-area-context, Reanimated — same
 * shape as other Phase 2 primitive tests (see ui/IconButton.test.tsx).
 */

// ── react-native primitives ──────────────────────────────────────────────────
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
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      hairlineWidth: 0.5,
      absoluteFillObject: {},
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

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ReaderProgressPill } from '@/components/reader/ReaderProgressPill'

/** Walk the rendered tree, returning every string node concatenated. */
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

function hasExactText(
  root: TestRenderer.ReactTestRenderer,
  needle: string,
): boolean {
  return findTextNodes(root).some((t) => t === needle)
}

describe('ReaderProgressPill (mobile)', () => {
  it("renders '5 / 100' for progress kind='page'", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderProgressPill
          progress={{ kind: 'page', current: 5, total: 100 }}
        />,
      )
    })
    expect(hasExactText(tree, '5 / 100')).toBe(true)
  })

  it("renders 'Ch 3/10' for progress kind='chapter'", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderProgressPill
          progress={{ kind: 'chapter', current: 3, total: 10 }}
        />,
      )
    })
    expect(hasExactText(tree, 'Ch 3/10')).toBe(true)
  })

  it("renders the verbatim label for progress kind='cfi'", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderProgressPill progress={{ kind: 'cfi', label: '42%' }} />,
      )
    })
    expect(hasExactText(tree, '42%')).toBe(true)
  })

  it("renders '—' for progress kind='none'", () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderProgressPill progress={{ kind: 'none' }} />,
      )
    })
    expect(hasExactText(tree, '—')).toBe(true)
  })
})
