/**
 * P1-T — ReaderBottomBar renders LockChip overlays on TTS / voice / AI
 * buttons when `showLockChips=true`. No layout shift on the underlying
 * IconButton (chips are absolutely positioned).
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
      absoluteFill: {},
      hairlineWidth: 0.5,
    },
    Platform: { OS: 'ios', select: (s: any) => s.ios ?? s.default },
    useWindowDimensions: () => ({
      width: 414,
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

// Theme stub
jest.mock('@/lib/theme', () => ({
  useTheme: () => ({
    colors: {
      accent: { primary: '#0a7ea4', error: '#FF3B30' },
      label: { primary: '#000', secondary: '#444', quaternary: '#aaa' },
    },
    typography: {
      scale: {
        body: { fontSize: 17, lineHeight: 22, fontWeight: '400' },
        subhead: { fontSize: 15, lineHeight: 20, fontWeight: '400' },
      },
    },
    motion: { duration: { fast: 200 } },
    spacing: { sm: 8 },
    reduceMotion: false,
  }),
}))

// Toolbar / IconButton / ReaderProgressPill — simple passthroughs.
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
        React.createElement('IconButton', { testID: `icon-${p.name}`, ...p }),
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
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

const baseProgress = { current: 10, total: 100, percent: 0.1 }

describe('ReaderBottomBar lock chips (P1-T)', () => {
  it('renders TTS / realtime / chat lock chips when showLockChips=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar
          visible
          progress={baseProgress}
          onTTSPress={() => {}}
          onRealtimePress={() => {}}
          onChatPress={() => {}}
          showLockChips
        />,
      )
    })
    expect(findByTestID(tree, 'tts-lock-chip')).not.toBeNull()
    expect(findByTestID(tree, 'realtime-lock-chip')).not.toBeNull()
    expect(findByTestID(tree, 'ai-chat-lock-chip')).not.toBeNull()
  })

  it('does NOT render lock chips when showLockChips=false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderBottomBar
          visible
          progress={baseProgress}
          onTTSPress={() => {}}
          onRealtimePress={() => {}}
          onChatPress={() => {}}
          showLockChips={false}
        />,
      )
    })
    expect(findByTestID(tree, 'tts-lock-chip')).toBeNull()
    expect(findByTestID(tree, 'realtime-lock-chip')).toBeNull()
    expect(findByTestID(tree, 'ai-chat-lock-chip')).toBeNull()
  })
})
