/**
 * Phase 3 — ReaderShell (mobile).
 *
 * ReaderShell owns:
 *   - chrome (top + bottom toolbar) visibility state
 *   - the 3s auto-hide timer (paused when TTS or realtime voice is active)
 *   - the 6 sheet-open booleans (toc, highlights, bookmarks, search,
 *     appearance, noteEditor)
 *   - the `ReaderShellContext` exposed to descendants (`bottomBarVisible`,
 *     `toggleToolbar`) — consumed by TTSControls (z-fix) and the EPUB
 *     `onSingleTap` callback
 *
 * The 8 pinned behaviours come from ARCH §7:
 *
 *   1. Toolbar hidden on initial render
 *   2. Calling `toggleToolbar` (via context) makes the toolbar visible
 *   3. Auto-hide fires after 3000ms (toolbar becomes hidden)
 *   4. Auto-hide is paused while `ttsActive=true`
 *   5. Auto-hide is paused while `realtimeActive=true`
 *   6. Pressing the TOC action opens the TOC sheet (sheet's `isOpen=true`)
 *   7. `bottomBarVisible` from context tracks `toolbarVisible`
 *   8. `initialToolbarVisible={true}` starts visible
 *
 * Red signal: `@/components/reader/ReaderShell` does not exist yet. All 8
 * tests fail at import time.
 *
 * Mock strategy:
 *   - `ReaderTopBar` and `ReaderBottomBar` are stubbed to inline `View`
 *     wrappers that capture the `visible` prop on a host node. This lets
 *     us assert visibility without depending on the real Toolbar/Reanimated
 *     implementation. The bottom bar mock also forwards `onTocPress` so we
 *     can simulate a press in test 6.
 *   - Each of the 6 sheets is stubbed at its exact import path. The mock
 *     returns `null` when `isOpen=false` and a tagged `View` when
 *     `isOpen=true` (so we can assert presence with `findAllByProps`).
 *   - The full-area Pressable that ReaderShell renders for tap-to-toggle
 *     is unused here; we exercise the context API directly via a
 *     Consumer-style component.
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
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
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

// react-native-mmkv is ESM — stub for the node test VM. ReaderShell now
// reads `isAuthenticated` from authStore (P1-T) which loads MMKV at
// module-init time.
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  }),
}))

// authStore is touched by ReaderShell for the `isAuthenticated` flag.
// Stub it with a static value — these tests assert ReaderShell wiring,
// not auth behavior.
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: false }),
}))

jest.mock('@expo/vector-icons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, Ionicons, default: { Ionicons } }
})

jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef((p: any, _r: unknown) =>
    React.createElement('BottomSheet', p, p.children),
  )
  const BottomSheetView = (p: any) =>
    React.createElement('BottomSheetView', p, p.children)
  const BottomSheetScrollView = (p: any) =>
    React.createElement('BottomSheetScrollView', p, p.children)
  const BottomSheetBackdrop = (p: any) =>
    React.createElement('BottomSheetBackdrop', p)
  return {
    __esModule: true,
    default: BottomSheet,
    BottomSheetView,
    BottomSheetScrollView,
    BottomSheetBackdrop,
  }
})

// ── Mock the two bar sub-components.
// We render them as host `<View>` nodes that carry a `data-visible` prop
// and forward `onTocPress` to a host node so tests can drive the press.
jest.mock(
  '@/components/reader/ReaderTopBar',
  () => {
    const React = require('react')
    const ReaderTopBar = (p: any) =>
      React.createElement('ReaderTopBar', {
        testID: 'reader-top-bar',
        'data-visible': p.visible,
        ...p,
      })
    return { __esModule: true, ReaderTopBar, default: ReaderTopBar }
  },
  { virtual: true },
)

jest.mock(
  '@/components/reader/ReaderBottomBar',
  () => {
    const React = require('react')
    const ReaderBottomBar = (p: any) =>
      React.createElement('ReaderBottomBar', {
        testID: 'reader-bottom-bar',
        'data-visible': p.visible,
        ...p,
      })
    return { __esModule: true, ReaderBottomBar, default: ReaderBottomBar }
  },
  { virtual: true },
)

// ── Mock each of the 6 sheets at their canonical import path.
// They render a tagged View only when `isOpen=true`, so the test can
// detect "this sheet is open" by finding the node with `testID="<x>-open"`.
function makeSheetMock(testID: string) {
  const React = require('react')
  return (p: any) =>
    p.isOpen
      ? React.createElement('Sheet', { testID, ...p })
      : null
}

jest.mock('@/components/AppearanceSheet', () => ({
  __esModule: true,
  AppearanceSheet: makeSheetMock('appearance-sheet-open'),
}))

jest.mock('@/components/TocSheet', () => ({
  __esModule: true,
  TocSheet: makeSheetMock('toc-sheet-open'),
}))

jest.mock('@/components/HighlightsSheet', () => ({
  __esModule: true,
  HighlightsSheet: makeSheetMock('highlights-sheet-open'),
}))

jest.mock('@/components/epub/BookmarksList', () => ({
  __esModule: true,
  BookmarksList: makeSheetMock('bookmarks-sheet-open'),
}))

jest.mock('@/components/epub/SearchPanel', () => ({
  __esModule: true,
  SearchPanel: makeSheetMock('search-sheet-open'),
}))

jest.mock('@/components/NoteEditor', () => ({
  __esModule: true,
  NoteEditor: makeSheetMock('note-editor-sheet-open'),
}))

// ReaderOverlay (Phase 4) — stub to a host node so the suite doesn't pull
// expo-blur / Reanimated / chatStore / playerStore into this test.
jest.mock('@/components/reader/ReaderOverlay', () => {
  const React = require('react')
  return {
    __esModule: true,
    ReaderOverlay: (p: { bookId?: string; onChatToggle?: () => void }) =>
      React.createElement('ReaderOverlayStub', {
        testID: 'reader-overlay-stub',
        ...p,
      }),
  }
})

import React, { act, useContext } from 'react'
import TestRenderer from 'react-test-renderer'
import {
  ReaderShell,
  ReaderShellContext,
} from '@/components/reader/ReaderShell'

/**
 * Find a host element with the given testID. Returns the first match or
 * `null`. We use the host instance API (props.testID) so this works for
 * both the bar wrappers and the sheet stubs.
 */
function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

/** Read the `visible` prop on the top or bottom bar stub. */
function isBarVisible(
  tree: TestRenderer.ReactTestRenderer,
  which: 'top' | 'bottom',
): boolean {
  const node = findByTestID(
    tree,
    which === 'top' ? 'reader-top-bar' : 'reader-bottom-bar',
  )
  if (!node) return false
  return Boolean((node.props as { visible?: boolean }).visible)
}

/**
 * A tiny consumer that lets a test grab the context value (or invoke
 * `toggleToolbar`). Mounted as a child of ReaderShell.
 */
const contextCapture: {
  bottomBarVisible: boolean
  toggleToolbar: () => void
} = {
  bottomBarVisible: false,
  toggleToolbar: () => undefined,
}

function ContextProbe() {
  const ctx = useContext(ReaderShellContext)
  contextCapture.bottomBarVisible = ctx.bottomBarVisible
  contextCapture.toggleToolbar = ctx.toggleToolbar
  return null
}

/** Default props that exercise the TOC handler in tests 6/7. */
const baseProps = {
  title: 'The Discourses',
  format: 'epub' as const,
  onBack: () => undefined,
  progress: { kind: 'none' as const },
  // Mount TOC handler so the bottom bar receives `onTocPress`.
  sheets: { toc: true },
  toc: [],
  currentHref: null,
  onSelectChapter: () => undefined,
}

beforeEach(() => {
  contextCapture.bottomBarVisible = false
  contextCapture.toggleToolbar = () => undefined
  jest.useRealTimers()
})

afterEach(() => {
  jest.useRealTimers()
})

describe('ReaderShell (mobile)', () => {
  it('shows the toolbar on initial render by default (P0-A — back button must be reachable)', () => {
    // Regression: previously the default was `false`, leaving the user
    // stranded with no Back-to-library button until they tapped the
    // page. Make the default visible; auto-hide still fires after the
    // first tap (see "auto-hides the toolbar after 3000ms").
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps}>
          <></>
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'top')).toBe(true)
    expect(isBarVisible(tree, 'bottom')).toBe(true)
  })

  it('shows the toolbar when `toggleToolbar` from context is invoked', () => {
    // Start from hidden so we can observe the toggle flip to visible.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps} initialToolbarVisible={false}>
          <ContextProbe />
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'bottom')).toBe(false)
    act(() => {
      contextCapture.toggleToolbar()
    })
    expect(isBarVisible(tree, 'top')).toBe(true)
    expect(isBarVisible(tree, 'bottom')).toBe(true)
  })

  it('auto-hides the toolbar after 3000ms', () => {
    jest.useFakeTimers()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps} initialToolbarVisible={true}>
          <ContextProbe />
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'bottom')).toBe(true)
    act(() => {
      jest.advanceTimersByTime(3000)
    })
    expect(isBarVisible(tree, 'bottom')).toBe(false)
  })

  it('does NOT auto-hide while `ttsActive=true`', () => {
    jest.useFakeTimers()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell
          {...baseProps}
          initialToolbarVisible={true}
          ttsActive={true}
        >
          <ContextProbe />
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'bottom')).toBe(true)
    act(() => {
      jest.advanceTimersByTime(3000)
    })
    expect(isBarVisible(tree, 'bottom')).toBe(true)
  })

  it('does NOT auto-hide while `realtimeActive=true`', () => {
    jest.useFakeTimers()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell
          {...baseProps}
          initialToolbarVisible={true}
          realtimeActive={true}
        >
          <ContextProbe />
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'bottom')).toBe(true)
    act(() => {
      jest.advanceTimersByTime(3000)
    })
    expect(isBarVisible(tree, 'bottom')).toBe(true)
  })

  it('opens the TOC sheet when the bottom bar fires `onTocPress`', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps} initialToolbarVisible={true}>
          <></>
        </ReaderShell>,
      )
    })
    // The TOC sheet stub renders nothing while isOpen=false.
    expect(findByTestID(tree, 'toc-sheet-open')).toBeNull()
    // Fire `onTocPress` on the bottom bar stub.
    const bottomBar = findByTestID(tree, 'reader-bottom-bar')
    expect(bottomBar).not.toBeNull()
    const onTocPress = (bottomBar?.props as { onTocPress?: () => void })
      .onTocPress
    expect(typeof onTocPress).toBe('function')
    act(() => {
      onTocPress?.()
    })
    // After the press, the TocSheet stub renders its tagged node.
    expect(findByTestID(tree, 'toc-sheet-open')).not.toBeNull()
  })

  it('exposes `bottomBarVisible` via context that mirrors toolbar visibility', () => {
    // Start from hidden so the toggle exercises the false→true transition.
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps} initialToolbarVisible={false}>
          <ContextProbe />
        </ReaderShell>,
      )
    })
    // Closed initially.
    expect(contextCapture.bottomBarVisible).toBe(false)
    // Toggle on; context should reflect.
    act(() => {
      contextCapture.toggleToolbar()
    })
    expect(contextCapture.bottomBarVisible).toBe(true)
  })

  it('starts visible when `initialToolbarVisible={true}` is passed', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderShell {...baseProps} initialToolbarVisible={true}>
          <></>
        </ReaderShell>,
      )
    })
    expect(isBarVisible(tree, 'top')).toBe(true)
    expect(isBarVisible(tree, 'bottom')).toBe(true)
  })
})
