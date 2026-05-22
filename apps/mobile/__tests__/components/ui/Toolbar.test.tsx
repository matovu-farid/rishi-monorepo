/**
 * Phase 3 — Toolbar BlurView wiring (P0-S).
 *
 * The reader chrome (ReaderTopBar / ReaderBottomBar) renders Toolbar with
 * `blur` + `transparent`. Prior to this fix Toolbar only applied an opaque
 * rgba fallback with a `// TODO Phase 3: replace with <BlurView>` comment,
 * so the iOS glass / vibrancy material was missing.
 *
 * Pinned observable behaviour:
 *   1. When `blur` is true, a BlurView element appears in the tree (light scheme).
 *   2. The BlurView's `tint` resolves to `systemChromeMaterial` in light scheme
 *      and `systemChromeMaterialDark` in dark scheme.
 *   3. The BlurView fills the toolbar via `StyleSheet.absoluteFill`.
 *   4. When `blur` is false, NO BlurView is rendered (the fallback chrome
 *      stays as the plain themed background).
 *
 * Mocks mirror GlassDisk.test.tsx so we get a stable host element named
 * "BlurView" we can search the tree for.
 */

let mockScheme: 'light' | 'dark' = 'light'

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
      absoluteFill: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
      },
      absoluteFillObject: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
      },
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => mockScheme,
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

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Toolbar } from '@/components/ui/Toolbar'

function flattenStyle(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) {
    return Object.assign({}, ...style.map((s) => flattenStyle(s)))
  }
  return style as Record<string, unknown>
}

function findHosts(
  tree: TestRenderer.ReactTestRenderer,
  tag: string,
): TestRenderer.ReactTestInstance[] {
  return tree.root.findAll(
    (n) => typeof n.type === 'string' && (n.type as string) === tag,
  )
}

describe('Toolbar (mobile) — BlurView wiring', () => {
  beforeEach(() => {
    mockScheme = 'light'
  })

  it('renders a BlurView when `blur` is true (light scheme uses systemChromeMaterial)', () => {
    mockScheme = 'light'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    const blurs = findHosts(tree, 'BlurView')
    expect(blurs.length).toBeGreaterThan(0)
    const props = blurs[0]!.props as { tint?: string; intensity?: number }
    expect(props.tint).toBe('systemChromeMaterial')
    expect(props.intensity).toBe(80)
  })

  it('uses systemChromeMaterialDark tint when the system scheme is dark', () => {
    mockScheme = 'dark'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Toolbar position="bottom" blur transparent />)
    })
    const blurs = findHosts(tree, 'BlurView')
    expect(blurs.length).toBeGreaterThan(0)
    const props = blurs[0]!.props as { tint?: string }
    expect(props.tint).toBe('systemChromeMaterialDark')
  })

  it('positions the BlurView with StyleSheet.absoluteFill so it covers the chrome', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    const blurs = findHosts(tree, 'BlurView')
    expect(blurs.length).toBeGreaterThan(0)
    const style = flattenStyle((blurs[0]!.props as { style?: unknown }).style)
    expect(style.position).toBe('absolute')
    expect(style.top).toBe(0)
    expect(style.left).toBe(0)
    expect(style.right).toBe(0)
    expect(style.bottom).toBe(0)
  })

  it('does NOT render a BlurView when `blur` is false (opaque chrome stays)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Toolbar position="top" />)
    })
    const blurs = findHosts(tree, 'BlurView')
    expect(blurs.length).toBe(0)
  })
})
