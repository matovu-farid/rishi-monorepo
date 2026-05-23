/**
 * A11Y-008 (#105) — Reader Toolbar fallback adapts when the platform
 * reports high text contrast (Android `isHighTextContrastEnabled`).
 *
 * The translucent rgba fallback used behind the BlurView is fine for
 * default chrome, but users who have opted into high contrast need a
 * solid (opaque) surface so the toolbar reads cleanly against any
 * page background. We deepen the fallback to the themed
 * `colors.background.primary` (solid) when high contrast is on.
 *
 * Behaviour pinned here:
 *   1. With high contrast OFF (default), the fallback backgroundColor
 *      stays `rgba(...)` (translucent — same as before).
 *   2. With high contrast ON, the fallback backgroundColor switches to
 *      the SOLID themed `background.primary` token so contrast is
 *      maximised even with the BlurView present.
 *   3. Subscribes to `highTextContrastChanged` so the surface flips
 *      live when the user toggles the setting from system Settings.
 */

let mockScheme: 'light' | 'dark' = 'light'
let mockHighContrast = false
const listeners: Record<string, Array<(v: boolean) => void>> = {}

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
      isHighTextContrastEnabled: jest.fn(async () => mockHighContrast),
      addEventListener: jest.fn((event: string, cb: (v: boolean) => void) => {
        listeners[event] = listeners[event] ?? []
        listeners[event].push(cb)
        return {
          remove: () => {
            listeners[event] = (listeners[event] ?? []).filter((c) => c !== cb)
          },
        }
      }),
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

async function flushMicrotasks(): Promise<void> {
  await act(async () => {
    await Promise.resolve()
    await Promise.resolve()
  })
}

describe('Toolbar (mobile) — A11Y-008 high-contrast fallback', () => {
  beforeEach(() => {
    mockScheme = 'light'
    mockHighContrast = false
    for (const k of Object.keys(listeners)) delete listeners[k]
  })

  it('uses translucent rgba fallback when high contrast is OFF', async () => {
    mockHighContrast = false
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    await flushMicrotasks()
    const root = tree.root.findByType(Toolbar as any)
    const container = root.findAllByType('View' as any)[0]!
    const style = flattenStyle((container.props as { style?: unknown }).style)
    expect(style.backgroundColor).toBe('rgba(255,255,255,0.95)')
  })

  it('uses SOLID themed background.primary when high contrast is ON (light)', async () => {
    mockHighContrast = true
    mockScheme = 'light'
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    await flushMicrotasks()
    const root = tree.root.findByType(Toolbar as any)
    const container = root.findAllByType('View' as any)[0]!
    const style = flattenStyle((container.props as { style?: unknown }).style)
    // colorsLight.background.primary === '#FFFFFF' (solid).
    expect(style.backgroundColor).toBe('#FFFFFF')
  })

  it('uses SOLID themed background.primary when high contrast is ON (dark)', async () => {
    mockHighContrast = true
    mockScheme = 'dark'
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    await flushMicrotasks()
    const root = tree.root.findByType(Toolbar as any)
    const container = root.findAllByType('View' as any)[0]!
    const style = flattenStyle((container.props as { style?: unknown }).style)
    // colorsDark.background.primary === '#000000' (solid).
    expect(style.backgroundColor).toBe('#000000')
  })

  it('subscribes to highTextContrastChanged so the surface flips when toggled', async () => {
    mockHighContrast = false
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<Toolbar position="top" blur transparent />)
    })
    await flushMicrotasks()
    expect(listeners['highTextContrastChanged']).toBeDefined()
    expect(listeners['highTextContrastChanged']!.length).toBeGreaterThan(0)

    // Flip the flag on at runtime.
    await act(async () => {
      for (const cb of listeners['highTextContrastChanged']!) cb(true)
    })

    const root = tree.root.findByType(Toolbar as any)
    const container = root.findAllByType('View' as any)[0]!
    const style = flattenStyle((container.props as { style?: unknown }).style)
    expect(style.backgroundColor).toBe('#FFFFFF')
  })
})
