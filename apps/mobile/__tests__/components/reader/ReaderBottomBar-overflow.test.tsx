/**
 * P1-L — ReaderBottomBar overflows on small phones (< 380pt wide) when
 * all 9 icons are wired. Secondary icons (highlights, search, appearance,
 * settings) collapse into a "More" menu (ellipsis-horizontal) on narrow
 * viewports. On wider viewports (>= 380pt) the full row renders.
 */

const widthHolder = { value: 414 }

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
        title: { fontSize: 22, lineHeight: 28, fontWeight: '600' },
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

function findAllByTestIDPrefix(
  tree: TestRenderer.ReactTestRenderer,
  prefix: string,
): TestRenderer.ReactTestInstance[] {
  return tree.root.findAll((n) => {
    const id = (n.props as { testID?: string } | null)?.testID
    return typeof id === 'string' && id.startsWith(prefix)
  })
}

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
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

describe('ReaderBottomBar overflow menu (P1-L)', () => {
  afterEach(() => {
    widthHolder.value = 414
  })

  it('on narrow widths (< 380pt), renders a "More" overflow button and collapses secondary icons', () => {
    widthHolder.value = 320
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
      )
    })
    // The More button must be rendered.
    expect(findByTestID(tree, 'reader-bottom-more')).not.toBeNull()
    // Secondary icons should be hidden from the primary row.
    expect(findByTestID(tree, 'icon-pencil-outline')).toBeNull() // highlights
    expect(findByTestID(tree, 'icon-search-outline')).toBeNull() // search
    expect(findByTestID(tree, 'icon-text-outline')).toBeNull() // appearance
    expect(findByTestID(tree, 'icon-list-circle-outline')).toBeNull() // bookmarks list
    // Primary icons should still be present.
    expect(findByTestID(tree, 'icon-list-outline')).not.toBeNull() // toc
    expect(findByTestID(tree, 'icon-volume-high-outline')).not.toBeNull() // tts
    expect(findByTestID(tree, 'icon-mic-outline')).not.toBeNull() // realtime
    expect(findByTestID(tree, 'icon-chatbubble-outline')).not.toBeNull() // chat
    expect(findByTestID(tree, 'icon-bookmark-outline')).not.toBeNull() // bookmark toggle
  })

  it('on wide widths (>= 380pt), renders the full row with no More button', () => {
    widthHolder.value = 414
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
      )
    })
    expect(findByTestID(tree, 'reader-bottom-more')).toBeNull()
    // All 9 icons present in the primary row.
    expect(findByTestID(tree, 'icon-list-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-pencil-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-list-circle-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-text-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-search-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-bookmark-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-volume-high-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-mic-outline')).not.toBeNull()
    expect(findByTestID(tree, 'icon-chatbubble-outline')).not.toBeNull()
  })

  it('tapping the More button opens the overflow menu with the secondary actions', () => {
    widthHolder.value = 320
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
      )
    })
    const moreBtn = findByTestID(tree, 'reader-bottom-more')
    expect(moreBtn).not.toBeNull()
    act(() => {
      ;(moreBtn!.props as { onPress?: () => void }).onPress?.()
    })
    // After opening, the overflow sheet should contain the secondary actions.
    const sheet = findByTestID(tree, 'reader-bottom-more-sheet')
    expect(sheet).not.toBeNull()
    // Secondary action entries appear inside the menu.
    expect(findByTestID(tree, 'reader-bottom-more-item-highlights')).not.toBeNull()
    expect(findByTestID(tree, 'reader-bottom-more-item-bookmarks')).not.toBeNull()
    expect(findByTestID(tree, 'reader-bottom-more-item-search')).not.toBeNull()
    expect(findByTestID(tree, 'reader-bottom-more-item-appearance')).not.toBeNull()
  })

  it('uses ellipsis-horizontal Ionicon for the More button', () => {
    widthHolder.value = 320
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
      )
    })
    // The More button should render the ellipsis-horizontal Ionicon. The
    // IconButton mock passes the `name` prop through, so we can read it
    // directly off the More button's props.
    const moreBtn = findByTestID(tree, 'reader-bottom-more')
    expect(moreBtn).not.toBeNull()
    expect((moreBtn!.props as { name?: string }).name).toBe(
      'ellipsis-horizontal',
    )
  })

  it('primary row contains at most 5 IconButtons + 1 More button on narrow widths', () => {
    widthHolder.value = 320
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar visible progress={baseProgress} {...allHandlers} />,
      )
    })
    // The primary cluster has TTS, realtime, AI-chat, bookmark, TOC = 5
    // primary icons + 1 More button (also an IconButton). Note: the
    // overflow sheet is rendered (closed) but its menu items only mount
    // when opened, so the icon count here is the primary row.
    const iconButtons = findAllByTestIDPrefix(tree, 'icon-')
    // 5 primary IconButtons (TOC, bookmark, TTS, realtime, chat). The
    // More button uses a separate testID prefix. The closed overflow
    // sheet must not contribute additional IconButtons.
    expect(iconButtons.length).toBeLessThanOrEqual(5)
  })
})
