/**
 * T-P2.6 — NAVHIST-001: mobile back-pill UI component.
 *
 * Source: `.parity-v2/SPEC.md` §3.11, `.parity-v2/PLAN.md` T-P2.6.
 *
 * Electron template:
 *   `apps/rishi-electron/src/renderer/src/components/navigation-history/
 *    NavigationHistoryFooter.tsx`
 *
 * Mobile component (to be created): `apps/mobile/components/reader/NavBackPill.tsx`.
 * The component subscribes to the navigation-history machine via three hooks:
 *
 *   - usePillVisible(): boolean — whether the pill should be rendered
 *   - useTopAnchor(): { label: string } | null — top-of-stack anchor for the label
 *   - useStackDepth(): number — when >1, append " (N)" to the label
 *
 * Behavior contract (mirrors electron):
 *   1. Renders nothing when the pill is hidden (machine state `pill.hidden`
 *      OR stack is empty).
 *   2. Renders the back label when visible — `← Back to {label}` and
 *      `← Back to {label} (N)` when stack depth > 1.
 *   3. Tap on the back label sends `POP_BACK` to the machine.
 *   4. Tap on the dismiss button sends `DISMISS_PILL`.
 *   5. After dwell timeout without further activity the pill is hidden
 *      (verified at the machine level — this test only checks that the
 *      component disappears when the hooks report visible=false).
 *
 * Until `apps/mobile/components/reader/NavBackPill.tsx` exists, this file
 * fails at import time (RED).
 */

// ── react-native stub (same pattern as SyncStatusIndicator.test.tsx) ─────────
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
    TouchableOpacity: mk('TouchableOpacity'),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

// ── reanimated stub (the pill uses Reanimated for fade-in/out) ──────────────
jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('View', { ...p, ref: r }, p.children),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: any) => c },
    useSharedValue: (v: number) => ({ value: v }),
    useAnimatedStyle: (fn: () => unknown) => fn(),
    withTiming: (v: unknown) => v,
    withRepeat: (v: unknown) => v,
    cancelAnimation: jest.fn(),
    FadeIn: { duration: () => ({}) },
    FadeOut: { duration: () => ({}) },
  }
})

// ── Mocked nav-history hooks ────────────────────────────────────────────────
let mockPillVisible = false
let mockTopAnchor: { label: string } | null = null
let mockStackDepth = 0
const mockSend = jest.fn()

jest.mock('@/hooks/useNavigationHistory', () => ({
  usePillVisible: () => mockPillVisible,
  useTopAnchor: () => mockTopAnchor,
  useStackDepth: () => mockStackDepth,
}))

jest.mock('@/lib/machines/navigationHistory', () => ({
  navigationHistoryActor: { send: (e: unknown) => mockSend(e) },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { NavBackPill } from '@/components/reader/NavBackPill'

const findByTestId = (tree: TestRenderer.ReactTestRenderer, id: string) =>
  tree.root.findAll((n) => (n.props as { testID?: string }).testID === id)[0]

const collectText = (tree: TestRenderer.ReactTestRenderer): string =>
  tree.toJSON ? JSON.stringify(tree.toJSON()) : ''

describe('NavBackPill (NAVHIST-001)', () => {
  beforeEach(() => {
    mockPillVisible = false
    mockTopAnchor = null
    mockStackDepth = 0
    mockSend.mockReset()
  })

  it('is NOT visible when navigation history is empty (pill hidden)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    // Pill should render nothing — either toJSON() is null or no children.
    expect(tree.toJSON()).toBeNull()
  })

  it('IS visible after a position jump (visible=true, top anchor present)', () => {
    mockPillVisible = true
    mockTopAnchor = { label: 'p. 142' }
    mockStackDepth = 1
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    expect(tree.toJSON()).not.toBeNull()
    expect(collectText(tree)).toContain('p. 142')
  })

  it('shows stack depth when more than one anchor is queued', () => {
    mockPillVisible = true
    mockTopAnchor = { label: 'p. 142' }
    mockStackDepth = 3
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    const text = collectText(tree)
    expect(text).toContain('p. 142')
    expect(text).toContain('(3)')
  })

  it('tap on back label sends POP_BACK to the machine', () => {
    mockPillVisible = true
    mockTopAnchor = { label: 'p. 142' }
    mockStackDepth = 1
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    const button = findByTestId(tree, 'nav-history-back-label')
    expect(button).toBeDefined()
    act(() => {
      ;(button.props as { onPress?: () => void }).onPress?.()
    })
    expect(mockSend).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('tap on dismiss button sends DISMISS_PILL to the machine', () => {
    mockPillVisible = true
    mockTopAnchor = { label: 'p. 142' }
    mockStackDepth = 1
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    const dismiss = findByTestId(tree, 'nav-history-dismiss')
    expect(dismiss).toBeDefined()
    act(() => {
      ;(dismiss.props as { onPress?: () => void }).onPress?.()
    })
    expect(mockSend).toHaveBeenCalledWith({ type: 'DISMISS_PILL' })
  })

  it('disappears after the pill becomes hidden (post-DWELL or post-pop)', () => {
    mockPillVisible = true
    mockTopAnchor = { label: 'p. 142' }
    mockStackDepth = 1
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<NavBackPill />)
    })
    expect(tree.toJSON()).not.toBeNull()

    // Simulate the machine flipping to hidden (DWELL elapsed OR stack drained).
    mockPillVisible = false
    mockTopAnchor = null
    mockStackDepth = 0
    act(() => {
      tree.update(<NavBackPill />)
    })
    expect(tree.toJSON()).toBeNull()
  })
})
