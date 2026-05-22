/**
 * Phase 2 — useTheme() hook (mobile).
 *
 * The hook resolves the active palette from `useColorScheme()` and tracks
 * `AccessibilityInfo.isReduceMotionEnabled` so primitives can swap springs
 * for timings under "Reduce Motion".
 *
 * Observable behaviour we pin:
 *   1. Scheme drives palette selection (light/dark) — verified via the
 *      `accent.primary` sentinel from UI-SPEC §1.1/§1.2 (`#0a7ea4` vs
 *      `#3AB4D6`).
 *   2. `reduceMotion` is a boolean (defaults false) — sourced from
 *      `AccessibilityInfo.isReduceMotionEnabled` async + change listener.
 *   3. Hook memoizes its return value across re-renders when neither
 *      scheme nor reduceMotion changed — consumers may safely use the
 *      returned theme in dependency arrays.
 *
 * `react-native` is fully mocked at module level so the hook runs under
 * the Node test VM. The mocks are mutable so tests can flip the scheme /
 * fire the reduce-motion listener.
 */

// ── Mock react-native primitives + AccessibilityInfo ─────────────────────────
let __scheme: 'light' | 'dark' = 'light'
let __reduceMotionInitial = false
const __reduceMotionListeners: Array<(v: boolean) => void> = []
const __reduceMotionListenerRemove = jest.fn(() => {
  /* removed */
})

jest.mock('react-native', () => ({
  Platform: {
    OS: 'ios',
    select: <T,>(spec: Record<string, T>): T | undefined =>
      spec.ios ?? spec.default,
  },
  useColorScheme: () => __scheme,
  AccessibilityInfo: {
    isReduceMotionEnabled: jest.fn(async () => __reduceMotionInitial),
    addEventListener: jest.fn((event: string, cb: (v: boolean) => void) => {
      if (event === 'reduceMotionChanged') {
        __reduceMotionListeners.push(cb)
      }
      return { remove: __reduceMotionListenerRemove }
    }),
  },
  StyleSheet: { hairlineWidth: 0.5 },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { useTheme, type Theme } from '@/lib/theme/useTheme'

/**
 * Harness — invokes useTheme() and reports each rendered theme value
 * upward. Render-only side effect, no DOM.
 */
function Harness(props: { onTheme: (theme: Theme) => void }) {
  const theme = useTheme()
  props.onTheme(theme)
  return null
}

beforeEach(() => {
  __scheme = 'light'
  __reduceMotionInitial = false
  __reduceMotionListeners.length = 0
  __reduceMotionListenerRemove.mockClear()
})

describe('useTheme (mobile)', () => {
  it('returns the light palette when system scheme is light', async () => {
    __scheme = 'light'
    const themes: Theme[] = []
    await act(async () => {
      TestRenderer.create(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    const theme = themes[themes.length - 1]
    expect(theme.scheme).toBe('light')
    // Sentinel: `#0a7ea4` is the light-mode brand accent (UI-SPEC §1.1).
    expect(theme.colors.accent.primary).toBe('#0a7ea4')
  })

  it('returns the dark palette when system scheme is dark', async () => {
    __scheme = 'dark'
    const themes: Theme[] = []
    await act(async () => {
      TestRenderer.create(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    const theme = themes[themes.length - 1]
    expect(theme.scheme).toBe('dark')
    // Sentinel: `#3AB4D6` is the dark-mode lifted brand accent (UI-SPEC §1.2).
    expect(theme.colors.accent.primary).toBe('#3AB4D6')
  })

  it('exposes reduceMotion as a boolean, default false', async () => {
    __reduceMotionInitial = false
    const themes: Theme[] = []
    await act(async () => {
      TestRenderer.create(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    const theme = themes[themes.length - 1]
    expect(typeof theme.reduceMotion).toBe('boolean')
    expect(theme.reduceMotion).toBe(false)
  })

  it('flips reduceMotion to true when AccessibilityInfo emits a change', async () => {
    const themes: Theme[] = []
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    // Simulate the OS toggling Reduce Motion ON.
    expect(__reduceMotionListeners.length).toBeGreaterThan(0)
    await act(async () => {
      for (const cb of __reduceMotionListeners) cb(true)
    })
    // Force a render pass to capture the new theme.
    await act(async () => {
      tree.update(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    expect(themes[themes.length - 1].reduceMotion).toBe(true)
  })

  it('returns a stable reference across renders when neither scheme nor reduceMotion changed', async () => {
    const themes: Theme[] = []
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    await act(async () => {
      tree.update(
        React.createElement(Harness, { onTheme: (t) => themes.push(t) }),
      )
    })
    expect(themes.length).toBeGreaterThanOrEqual(2)
    // useMemo on [scheme, reduceMotion] should keep identity stable.
    expect(themes[0]).toBe(themes[themes.length - 1])
  })
})
