/**
 * Phase 4 — MiniPlayer (mobile).
 *
 * Single component with two visual states (orb / pill) that morph via a
 * shared spring-animated value. Replaces the old TTSControls.
 *
 * Per ARCH §4 and §9 the pinned behaviour (12 tests):
 *   1. Returns null when `playerStore.playingState === 'idle'`.
 *   2. Returns null when `playerStore.send === null`.
 *   3. Renders with `testID='mini-player'` when playing.
 *   4. `testID='mini-player-orb'` present in the tree initially (expanded=false).
 *   5. Tapping the orb expands to pill → `testID='mini-player-pill'` becomes visible.
 *   6. Press play-pause while playing → `send({type:'PAUSE'})`.
 *   7. Press play-pause while paused.clean → `send({type:'RESUME'})`.
 *   8. Press next → `send({type:'NEXT'})`.
 *   9. Press prev → `send({type:'PREV'})`.
 *  10. Press stop → `send({type:'STOP'})`.
 *  11. While `playingState='loading'`, an ActivityIndicator renders in
 *      the play-pause slot.
 *  12. Repeat button hidden when `repeatMode='off'`, shown when 'one'.
 *
 * Mock strategy:
 *   - playerStore selector is mocked at the import path with a reassignable
 *     module-scoped `playerState` object.
 *   - GlassDisk + IconButton + Ionicons are stubbed to host nodes that
 *     expose the press handler.
 *   - The morph animation uses Reanimated; we stub it as a passthrough so
 *     `useAnimatedStyle({...})` returns `{}` and `Animated.View` is just
 *     `<Animated.View>`. We don't drive the spring — we drive `expanded`
 *     by pressing the orb (the component owns its internal `expanded`
 *     state).
 *
 * Red signal: `@/components/player/MiniPlayer` does not exist yet.
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
    TouchableOpacity: mk('TouchableOpacity'),
    ActivityIndicator: (p: any) =>
      React.createElement('ActivityIndicator', { testID: 'activity-indicator', ...p }),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      absoluteFillObject: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useWindowDimensions: () => ({ width: 390, height: 844, scale: 3, fontScale: 1 }),
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

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  const passthrough = (v: unknown) => v
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    useReducedMotion: () => false,
    withTiming: passthrough,
    withSpring: passthrough,
    withDelay: (_d: number, v: unknown) => v,
    withSequence: (...vs: unknown[]) => vs,
    withRepeat: (v: unknown) => v,
    cancelAnimation: jest.fn(),
    Easing: {
      out: () => null,
      quad: null,
      inOut: () => null,
      linear: null,
    },
    interpolate: (v: number) => v,
    Extrapolation: { CLAMP: 'clamp' },
    // P1-O — pillInteractive gate uses these. In tests we keep them inert
    // so the gate never opens, which is the contract we want to pin
    // (touches blocked during the morph).
    useAnimatedReaction: jest.fn(),
    runOnJS: (fn: unknown) => fn,
    FadeIn: { duration: () => ({ build: () => ({}) }) },
    FadeOut: { duration: () => ({ build: () => ({}) }) },
    SlideInDown: { duration: () => ({ build: () => ({}) }) },
    SlideOutDown: { duration: () => ({ build: () => ({}) }) },
  }
})

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

jest.mock('@expo/vector-icons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, Ionicons, default: { Ionicons } }
})

jest.mock(
  '@/components/ui/GlassDisk',
  () => {
    const React = require('react')
    const GlassDisk = (p: any) =>
      React.createElement('GlassDisk', { testID: 'glass-disk', ...p }, p.children)
    return { __esModule: true, GlassDisk }
  },
  { virtual: true },
)

// ReaderShellContext — the real one lives in its own leaf module so that
// MiniPlayer can consume it without dragging in the full ReaderShell +
// sheet dependency chain (this also breaks a require cycle that crashed
// the EPUB reader on iOS — issue #33).
//
// Both stubs return the SAME context object so:
//   - production code (MiniPlayer) reading the leaf path
//   - test code (WGT-016 Provider wrapper) reading the legacy
//     `ReaderShell` re-export path
// see the same value.
const _sharedReaderShellContext = (() => {
  const React = require('react')
  return React.createContext({
    bottomBarVisible: false,
    toggleToolbar: () => undefined,
    interact: () => undefined,
  })
})()
jest.mock('@/components/reader/ReaderShellContext', () => ({
  __esModule: true,
  ReaderShellContext: _sharedReaderShellContext,
}))
jest.mock('@/components/reader/ReaderShell', () => ({
  __esModule: true,
  ReaderShellContext: _sharedReaderShellContext,
}))

// ── playerStore selector mock (reassignable per test) ────────────────────────
type Send = (event: { type: string }) => void
type PlayerShape = {
  playingState:
    | 'idle'
    | 'stopped'
    | 'loading'
    | 'playing'
    | 'paused.clean'
    | 'paused.stale'
    | 'waitingForParagraphs'
    | 'pageNavigating'
  send: Send | null
  activeParagraph: unknown | null
  currentParagraphs: unknown[]
  repeatMode: 'off' | 'one'
}

const sendMock = jest.fn() as jest.Mock<void, [{ type: string }]>
let playerState: PlayerShape = {
  playingState: 'idle',
  send: sendMock,
  activeParagraph: null,
  currentParagraphs: [],
  repeatMode: 'off',
}

jest.mock('@/lib/stores/playerStore', () => ({
  __esModule: true,
  usePlayerStore: <T,>(selector: (s: PlayerShape) => T) => selector(playerState),
}))

// useRequireAuth — pass through (no-op gate; MiniPlayer pause/resume is
// past the gate, but a few internal calls may still wrap requireAuth).
jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Pressable } from 'react-native'
import { MiniPlayer } from '@/components/player/MiniPlayer'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

function pressByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): boolean {
  const node = findByTestID(tree, testID)
  if (!node) return false
  const onPress = (node.props as { onPress?: () => void }).onPress
  if (typeof onPress !== 'function') return false
  act(() => {
    onPress()
  })
  return true
}

beforeEach(() => {
  sendMock.mockClear()
  playerState = {
    playingState: 'idle',
    send: sendMock,
    activeParagraph: null,
    currentParagraphs: [],
    repeatMode: 'off',
  }
})

describe('MiniPlayer (mobile)', () => {
  it('returns null when playingState="idle"', () => {
    playerState.playingState = 'idle'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('returns null when playerStore.send is null', () => {
    playerState.playingState = 'playing'
    playerState.send = null
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    expect(tree.toJSON()).toBeNull()
  })

  it('renders root with testID="mini-player" when playing', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    expect(findByTestID(tree, 'mini-player')).not.toBeNull()
  })

  it('starts collapsed — mini-player-orb present initially', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    expect(findByTestID(tree, 'mini-player-orb')).not.toBeNull()
  })

  it('tapping mini-player-orb expands to pill (mini-player-pill becomes visible)', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    // Pill not visible initially.
    // Note: implementation may conditionally render the pill node only
    // when expanded — so either no node OR a node whose visibility flag
    // is false. We assert the post-press positive case strictly: pill
    // visible after tapping.
    const orb = findByTestID(tree, 'mini-player-orb')
    expect(orb).not.toBeNull()
    const onPress = (orb!.props as { onPress?: () => void }).onPress
    expect(typeof onPress).toBe('function')
    act(() => {
      onPress!()
    })
    expect(findByTestID(tree, 'mini-player-pill')).not.toBeNull()
  })

  it('dispatches {type:"PAUSE"} when play-pause pressed while playing', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    // Expand to pill to expose controls.
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    expect(pressByTestID(tree, 'mini-player-play-pause')).toBe(true)
    expect(sendMock).toHaveBeenCalledWith({ type: 'PAUSE' })
  })

  it('dispatches {type:"RESUME"} when play-pause pressed while paused.clean', () => {
    playerState.playingState = 'paused.clean'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    expect(pressByTestID(tree, 'mini-player-play-pause')).toBe(true)
    expect(sendMock).toHaveBeenCalledWith({ type: 'RESUME' })
  })

  it('dispatches {type:"NEXT"} when next pressed', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    expect(pressByTestID(tree, 'mini-player-next')).toBe(true)
    expect(sendMock).toHaveBeenCalledWith({ type: 'NEXT' })
  })

  it('dispatches {type:"PREV"} when prev pressed', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    expect(pressByTestID(tree, 'mini-player-prev')).toBe(true)
    expect(sendMock).toHaveBeenCalledWith({ type: 'PREV' })
  })

  it('dispatches {type:"STOP"} when stop pressed', () => {
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    expect(pressByTestID(tree, 'mini-player-stop')).toBe(true)
    expect(sendMock).toHaveBeenCalledWith({ type: 'STOP' })
  })

  it('renders ActivityIndicator in play-pause slot when playingState="loading"', () => {
    playerState.playingState = 'loading'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    // Expand to expose pill controls.
    const orb = findByTestID(tree, 'mini-player-orb')
    if (orb) {
      act(() => {
        ;(orb!.props as { onPress: () => void }).onPress()
      })
    }
    const spinners = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'activity-indicator',
    )
    expect(spinners.length).toBeGreaterThan(0)
  })

  it('gates pill pointerEvents to "none" during the expand morph (P1-O)', () => {
    // P1-O: while the wrapper width is animating 52 → 240pt the pill
    // controls already exist in the tree but the surface they sit on
    // is still mid-morph. Allowing touches during that window means a
    // user dragging their finger across the orb can land a stray tap on
    // a pill button before the morph settles. The fix: keep the pill at
    // `pointerEvents="none"` until the shared expandedValue crosses
    // 0.85 (driven by `useAnimatedReaction`).
    //
    // Under the test renderer Reanimated is mocked, so the shared value
    // never advances — the pill stays gated, which is exactly what we
    // want to assert.
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    const orb = findByTestID(tree, 'mini-player-orb')
    act(() => {
      ;(orb!.props as { onPress: () => void }).onPress()
    })
    const pill = findByTestID(tree, 'mini-player-pill')
    expect(pill).not.toBeNull()
    expect(
      (pill!.props as { pointerEvents?: 'auto' | 'none' }).pointerEvents,
    ).toBe('none')
  })

  describe('WGT-016 — reader bottom-bar offset honors safe-area insets', () => {
    // The reader's Toolbar has `minHeight: 44` (the row floor) plus
    // `paddingBottom: insets.bottom` on the bottom variant. The previous
    // constant `BOTTOM_BAR_HEIGHT = 44` undercounted the bar's visual
    // height by ~insets.bottom (≈34pt on notched iPhones), so the
    // MiniPlayer floated INTO the bottom bar instead of above it.
    //
    // Test the surface that's safely observable: the MiniPlayer's
    // wrapper `style.bottom` when the reader bar is visible vs hidden.
    // The delta must equal `44 + insets.bottom`, not just `44`.
    function getMiniPlayerBottom(
      bottomBarVisible: boolean,
    ): number | undefined {
      // We must re-require ReaderShellContext so we can wrap the tree
      // in a Provider with the supplied bottomBarVisible — the same
      // pattern the ReaderOverlay test uses.
      const ReaderShell = require('@/components/reader/ReaderShell') as {
        ReaderShellContext: React.Context<{
          bottomBarVisible: boolean
          toggleToolbar: () => void
        }>
      }
      const Provider = ReaderShell.ReaderShellContext.Provider
      playerState.playingState = 'playing'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <Provider
            value={{
              bottomBarVisible,
              toggleToolbar: () => undefined,
            }}
          >
            <MiniPlayer bookId="b1" variant="reader" />
          </Provider>,
        )
      })
      const player = findByTestID(tree, 'mini-player')
      const style = (player!.props as { style?: unknown }).style
      // The wrapper has an array style: [shadow.medium, {...}, animatedStyle].
      // Walk it to find the bottom value.
      const items = Array.isArray(style) ? style : [style]
      for (const item of items) {
        if (item && typeof item === 'object' && 'bottom' in item) {
          return (item as { bottom?: number }).bottom
        }
      }
      return undefined
    }

    it('bottom offset increase when toolbar shows equals 44 + insets.bottom', () => {
      // useSafeAreaInsets is mocked to bottom: 34 above.
      const bottomHidden = getMiniPlayerBottom(false)
      const bottomVisible = getMiniPlayerBottom(true)
      expect(typeof bottomHidden).toBe('number')
      expect(typeof bottomVisible).toBe('number')
      const delta = (bottomVisible as number) - (bottomHidden as number)
      // Real bottom-bar visual height = Toolbar.minHeight + insets.bottom
      // = 44 + 34 = 78. The old code shifted by 44 only.
      expect(delta).toBe(44 + 34)
    })
  })

  it('hides repeat button when repeatMode="off", shows it when "one"', () => {
    playerState.playingState = 'playing'
    playerState.repeatMode = 'off'
    let treeOff!: TestRenderer.ReactTestRenderer
    act(() => {
      treeOff = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    // Expand to expose pill.
    act(() => {
      ;(findByTestID(treeOff, 'mini-player-orb')!.props as {
        onPress: () => void
      }).onPress()
    })
    expect(findByTestID(treeOff, 'mini-player-repeat')).toBeNull()

    playerState.repeatMode = 'one'
    let treeOn!: TestRenderer.ReactTestRenderer
    act(() => {
      treeOn = TestRenderer.create(<MiniPlayer bookId="b1" />)
    })
    act(() => {
      ;(findByTestID(treeOn, 'mini-player-orb')!.props as {
        onPress: () => void
      }).onPress()
    })
    expect(findByTestID(treeOn, 'mini-player-repeat')).not.toBeNull()
  })
})
