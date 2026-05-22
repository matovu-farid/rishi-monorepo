/**
 * Phase 4 — GlobalMiniPlayer (mobile).
 *
 * A thin wrapper around MiniPlayer mounted at the root layout. Per ARCH §6:
 *   - Returns null when on a `/reader/...` route (reader-mounted instance
 *     takes priority).
 *   - Returns null when `playerStore.playingState === 'idle'`.
 *   - Otherwise renders MiniPlayer with `variant='global'`, default
 *     `tabBarHeight=49`, and `testID='global-mini-player'`.
 *
 * Pinned behaviour (6 tests):
 *   1. `pathname='/reader/abc'` → returns null.
 *   2. `pathname='/reader/some/nested'` → returns null.
 *   3. `pathname='/(tabs)/index'` but `playingState='idle'` → returns null.
 *   4. `pathname='/(tabs)/index'` + `playingState='playing'` → renders MiniPlayer.
 *   5. The mounted MiniPlayer gets `testID='global-mini-player'`.
 *   6. The mounted MiniPlayer gets `variant='global'`.
 *
 * Mock strategy:
 *   - MiniPlayer is stubbed to a host node so we can read the props
 *     GlobalMiniPlayer passed to it.
 *   - expo-router's `usePathname` is mocked with a reassignable module
 *     variable.
 *   - playerStore selector is mocked with a reassignable shape.
 *
 * Red signal: `@/components/player/GlobalMiniPlayer` does not exist yet.
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
// Virtual so the mock path resolves even before MiniPlayer lands.
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

// expo-router pathname — reassignable per test.
let pathnameValue: string = '/(tabs)/index'
jest.mock('expo-router', () => ({
  __esModule: true,
  usePathname: () => pathnameValue,
  useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
  Slot: ({ children }: { children: React.ReactNode }) => children,
  Stack: Object.assign(
    ({ children }: { children: React.ReactNode }) => children,
    { Screen: ({ children }: { children: React.ReactNode }) => children ?? null },
  ),
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
  pathnameValue = '/(tabs)/index'
  playerState = {
    playingState: 'idle',
    send: () => undefined,
    repeatMode: 'off',
  }
})

describe('GlobalMiniPlayer (mobile)', () => {
  it('returns null when pathname starts with /reader (basic /reader/abc)', () => {
    pathnameValue = '/reader/abc'
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('returns null when pathname is /reader/some/nested', () => {
    pathnameValue = '/reader/some/nested'
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('returns null when off-reader but playingState="idle"', () => {
    pathnameValue = '/(tabs)/index'
    playerState.playingState = 'idle'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('renders MiniPlayer when off-reader and playingState="playing"', () => {
    pathnameValue = '/(tabs)/index'
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    expect(findByTestID(tree, 'global-mini-player')).not.toBeNull()
  })

  it('passes testID="global-mini-player" to MiniPlayer', () => {
    pathnameValue = '/(tabs)/index'
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
    pathnameValue = '/(tabs)/index'
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlobalMiniPlayer />)
    })
    const node = findByTestID(tree, 'global-mini-player')
    expect(node).not.toBeNull()
    expect((node!.props as { variant?: string }).variant).toBe('global')
  })
})
