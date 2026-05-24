/**
 * A11Y-009 (#106) — ReaderBottomBar overflow menu ARIA consistency.
 *
 * Children currently declare `accessibilityRole="menuitem"` and a
 * `accessibilityLabel` but no `accessibilityHint`. VoiceOver / TalkBack
 * announce the role + label but the affordance ("opens highlights",
 * "opens search", ...) is missing. We also re-pin that the wrapper
 * carries `accessibilityRole="menu"` (already true) and that the
 * overlay declares `accessibilityViewIsModal` so the rest of the screen
 * is silenced while the menu is open.
 *
 * Behaviour pinned here:
 *   1. Each menu item has accessibilityRole === 'menuitem'.
 *   2. Each menu item has a non-empty accessibilityLabel.
 *   3. Each menu item has a non-empty accessibilityHint.
 *   4. The menu wrapper has accessibilityRole === 'menu'.
 *   5. The overlay declares accessibilityViewIsModal === true.
 */

const widthHolder = { value: 320 }

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
      absoluteFill: {},
      absoluteFillObject: {},
      hairlineWidth: 0.5,
    },
    Platform: { OS: 'ios', select: (s: any) => s.ios ?? s.default },
    useWindowDimensions: () => ({
      width: widthHolder.value,
      height: 844,
      scale: 3,
      fontScale: 1,
    }),
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

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
    withSequence: (...vs: unknown[]) => vs,
    cancelAnimation: jest.fn(),
    Easing: { out: () => null, quad: null, inOut: () => null, linear: null },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Error: 'error' },
}))

jest.mock('@/lib/theme', () => ({
  useTheme: () => ({
    colors: {
      accent: { primary: '#0a7ea4', error: '#FF3B30' },
      label: { primary: '#000', secondary: '#444', quaternary: '#aaa' },
      fill: { tertiary: '#ddd' },
      background: { primary: '#fff', secondary: '#f7f7f7' },
    },
    typography: {
      scale: {
        body: { fontSize: 17, lineHeight: 22, fontWeight: '400' },
        subhead: { fontSize: 15, lineHeight: 20, fontWeight: '400' },
      },
    },
    motion: { duration: { fast: 200 } },
    spacing: { sm: 8, md: 12, lg: 16 },
    reduceMotion: false,
  }),
}))

jest.mock(
  '@/components/ui/Toolbar',
  () => {
    const React = require('react')
    return {
      __esModule: true,
      Toolbar: (p: any) =>
        React.createElement(
          'Toolbar',
          p,
          p.left,
          p.center,
          p.right,
        ),
    }
  },
  { virtual: true },
)

jest.mock(
  '@/components/ui/IconButton',
  () => {
    const React = require('react')
    return {
      __esModule: true,
      IconButton: (p: any) =>
        React.createElement('IconButton', {
          testID: p.testID ?? `icon-${p.name}`,
          ...p,
        }),
    }
  },
  { virtual: true },
)

jest.mock('@/components/reader/ReaderProgressPill', () => {
  const React = require('react')
  return {
    __esModule: true,
    ReaderProgressPill: (p: any) =>
      React.createElement('ReaderProgressPill', { ...p }),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ReaderBottomBar } from '@/components/reader/ReaderBottomBar'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  // Match host (string-typed) elements only — otherwise the `testID`
  // prop on a wrapper React component would match before the actual
  // rendered host that carries the a11y props.
  const matches = tree.root.findAll(
    (n) =>
      typeof n.type === 'string' &&
      (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

const baseProgress = { kind: 'page' as const, current: 10, total: 100 }
const allHandlers = {
  onTocPress: () => {},
  onHighlightsPress: () => {},
  onBookmarksPress: () => {},
  onSearchPress: () => {},
  onAppearancePress: () => {},
  onBookmarkTogglePress: () => {},
  onTTSPress: () => {},
  onRealtimePress: () => {},
  onChatPress: () => {},
}

function openMenu(): TestRenderer.ReactTestRenderer {
  widthHolder.value = 320
  let tree!: TestRenderer.ReactTestRenderer
  act(() => {
    tree = TestRenderer.create(
      <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
    )
  })
  const moreBtn = findByTestID(tree, 'reader-bottom-more')!
  act(() => {
    ;(moreBtn.props as { onPress?: () => void }).onPress?.()
  })
  return tree
}

const itemKeys = ['highlights', 'bookmarks', 'search', 'appearance'] as const

describe('ReaderBottomBar overflow ARIA (A11Y-009 / #106)', () => {
  it('every menu item has consistent role/label/hint', () => {
    const tree = openMenu()
    for (const k of itemKeys) {
      const item = findByTestID(tree, `reader-bottom-more-item-${k}`)
      expect(item).not.toBeNull()
      const props = item!.props as {
        accessibilityRole?: string
        accessibilityLabel?: string
        accessibilityHint?: string
      }
      expect(props.accessibilityRole).toBe('menuitem')
      expect(typeof props.accessibilityLabel).toBe('string')
      expect(props.accessibilityLabel!.length).toBeGreaterThan(0)
      // The fix: every item now carries a non-empty hint that
      // describes the action it performs.
      expect(typeof props.accessibilityHint).toBe('string')
      expect(props.accessibilityHint!.length).toBeGreaterThan(0)
    }
  })

  it('the wrapping menu sheet has accessibilityRole="menu"', () => {
    const tree = openMenu()
    // The sheet is a sibling of the backdrop inside the overlay; the
    // overlay itself sets accessibilityViewIsModal. Find any View with
    // role === 'menu'.
    const menus = tree.root.findAll(
      (n) =>
        (n.props as { accessibilityRole?: string } | null)?.accessibilityRole ===
        'menu',
    )
    expect(menus.length).toBeGreaterThanOrEqual(1)
  })

  it('the overlay sets accessibilityViewIsModal so background is silenced', () => {
    const tree = openMenu()
    const sheet = findByTestID(tree, 'reader-bottom-more-sheet')
    expect(sheet).not.toBeNull()
    expect(
      (sheet!.props as { accessibilityViewIsModal?: boolean })
        .accessibilityViewIsModal,
    ).toBe(true)
  })

  it('the backdrop is a button with a Dismiss label + hint', () => {
    const tree = openMenu()
    const backdrop = findByTestID(tree, 'reader-bottom-more-backdrop')
    expect(backdrop).not.toBeNull()
    const props = backdrop!.props as {
      accessibilityRole?: string
      accessibilityLabel?: string
      accessibilityHint?: string
    }
    expect(props.accessibilityRole).toBe('button')
    expect(typeof props.accessibilityLabel).toBe('string')
    expect(props.accessibilityLabel!.length).toBeGreaterThan(0)
    expect(typeof props.accessibilityHint).toBe('string')
    expect(props.accessibilityHint!.length).toBeGreaterThan(0)
  })
})
