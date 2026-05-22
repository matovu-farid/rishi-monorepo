/**
 * Phase 4 — GlobalMiniPlayer (mobile).
 *
 * A thin wrapper around MiniPlayer rendered as a `screenLayout` overlay
 * inside the Tabs subtree (apps/mobile/app/(tabs)/_layout.tsx). Because it
 * only mounts when a tab screen is active, it cannot render on stack
 * routes outside Tabs (`/reader/[id]`, `/chat/[bookId]`) — fixing P0-R.
 *
 * For the same reason it reads the live tab-bar height via
 * `useBottomTabBarHeight()` from `@react-navigation/bottom-tabs` rather
 * than the legacy 49pt hardcode — fixing P0-Q for iPad, AX Large Text,
 * and iOS 26 Liquid Glass tab bars.
 *
 * Pinned behaviour (5 tests):
 *   1. `playingState='idle'` → returns null.
 *   2. `playingState='playing'` → renders MiniPlayer.
 *   3. The mounted MiniPlayer gets `testID='global-mini-player'`.
 *   4. The mounted MiniPlayer gets `variant='global'`.
 *   5. The mounted MiniPlayer gets `tabBarHeight` equal to whatever
 *      `useBottomTabBarHeight()` returns (varies by device — we mock 88).
 *
 * Mock strategy:
 *   - MiniPlayer is stubbed to a host node so we can read the props
 *     GlobalMiniPlayer passed to it.
 *   - `@react-navigation/bottom-tabs` is mocked with a reassignable
 *     `useBottomTabBarHeight()` return value.
 *   - playerStore selector is mocked with a reassignable shape.
 *
 * NB: route-based hide logic (`pathname.startsWith('/reader')`) is REMOVED.
 * The mount location (inside Tabs.screenLayout) already prevents render
 * on /reader/* and /chat/[bookId] because those are stack routes outside
 * the Tabs subtree. Asserting absence-of-pathname-check would be brittle;
 * we instead assert the positive case (renders when off-idle) and the
 * tab-bar-height plumbing.
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
    Pressable: mk('Pressable'),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      hairlineWidth: 0.5,
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
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// Stub MiniPlayer so we can read the props GlobalMiniPlayer passes.
jest.mock(
  '@/components/player/MiniPlayer',
  () => {
    const React = require('react')
    const MiniPlayer = (p: any) =>
      React.createElement('MiniPlayerStub', {
        testID: p.testID ?? 'mini-player-stub',
        ...p,
      })
    return { __esModule: true, MiniPlayer }
  },
  { virtual: true },
)

// useBottomTabBarHeight — reassignable per test.
let tabBarHeightValue: number = 49
jest.mock('@react-navigation/bottom-tabs', () => ({
  __esModule: true,
  useBottomTabBarHeight: () => tabBarHeightValue,
}))

// playerStore selector — reassignable shape.
type PlayerShape = {
  playingState: 'idle' | 'playing' | 'paused.clean' | 'loading'
  send: ((event: { type: string }) => void) | null
  repeatMode: 'off' | 'one'
}

let playerState: PlayerShape = {
  playingState: 'idle',
  send: () => undefined,
  repeatMode: 'off',
}

jest.mock('@/lib/stores/playerStore', () => ({
  __esModule: true,
  usePlayerStore: <T,>(selector: (s: PlayerShape) => T) => selector(playerState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { GlobalMiniPlayer } from '@/components/player/GlobalMiniPlayer'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

beforeEach(() => {
  tabBarHeightValue = 49
  playerState = {
    playingState: 'idle',
    send: () => undefined,
    repeatMode: 'off',
  }
})

describe('GlobalMiniPlayer (mobile)', () => {
  it('returns null when playingState="idle"', () => {
    playerState.playingState = 'idle'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('renders MiniPlayer when playingState="playing"', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(findByTestID(tree, 'global-mini-player')).not.toBeNull()
  })

  it('passes testID="global-mini-player" to MiniPlayer', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    const node = findByTestID(tree, 'global-mini-player')
    expect(node).not.toBeNull()
    expect((node!.props as { testID?: string }).testID).toBe('global-mini-player')
  })

  it('passes variant="global" to MiniPlayer', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    const node = findByTestID(tree, 'global-mini-player')
    expect(node).not.toBeNull()
    expect((node!.props as { variant?: string }).variant).toBe('global')
  })

  it('passes the measured tab-bar height from useBottomTabBarHeight() (P0-Q)', () => {
    // 88pt is a realistic iPad / AX Large Text tab-bar height; the legacy
    // 49pt hardcode would render the player floating well above the tab bar.
    tabBarHeightValue = 88
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    const node = findByTestID(tree, 'global-mini-player')
    expect(node).not.toBeNull()
    expect((node!.props as { tabBarHeight?: number }).tabBarHeight).toBe(88)
  })
})
