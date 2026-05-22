/**
 * CHT-009 — Empty conversation list hint must mention the in-screen
 * "New conversation" + button.
 *
 * Previously the copy said "Open a book and tap the AI icon to start a
 * conversation." — confusing because the conversations tab itself has a
 * visible "+" button (`chat-new-conversation-btn`) that creates a new
 * conversation. The hint must point users at the most direct affordance.
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const { data = [], renderItem, keyExtractor } = p
    const items = (data as unknown[]).map((item, index) => {
      const key = keyExtractor ? keyExtractor(item, index) : String(index)
      const rendered = renderItem ? renderItem({ item, index }) : null
      return React.createElement(React.Fragment, { key }, rendered)
    })
    return React.createElement('FlatList', { ...p, ref: r }, items)
  })
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Image: mk('Image'),
    FlatList,
    Alert: { alert: jest.fn() },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef(
    (p: any, _ref: unknown) => {
      const open = (p.index ?? -1) >= 0
      return React.createElement('BottomSheet', p, open ? p.children : null)
    },
  )
  return {
    __esModule: true,
    default: BottomSheet,
    BottomSheetView: (p: any) => require('react').createElement('BottomSheetView', p, p.children),
    BottomSheetScrollView: (p: any) =>
      require('react').createElement('BottomSheetScrollView', p, p.children),
    BottomSheetBackdrop: (p: any) =>
      require('react').createElement('BottomSheetBackdrop', p),
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
    Easing: { out: () => null, quad: null, inOut: () => null },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: (p: any) => React.createElement('SafeAreaView', p, p.children),
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

jest.mock('expo-router', () => {
  const React = require('react')
  return {
    useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
    useFocusEffect: (cb: () => void) => {
      React.useEffect(() => {
        const cleanup = cb()
        return typeof cleanup === 'function' ? cleanup : undefined
      }, [cb])
    },
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: true }),
}))

jest.mock('@/components/auth/LockChip', () => {
  const React = require('react')
  return {
    __esModule: true,
    LockChip: (p: any) =>
      React.createElement('LockChipStub', { testID: p.testID ?? 'lock-chip' }),
  }
})

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => [],
  getConversationsForBook: () => [],
  getMessages: () => [],
  softDeleteConversation: jest.fn(),
}))
jest.mock('@/lib/book-storage', () => ({
  getBookById: () => null,
  getBooks: () => [],
}))
jest.mock('@/lib/rag/vector-store', () => ({ isBookEmbedded: () => true }))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

describe('Conversations empty-state hint (CHT-009)', () => {
  it('mentions the in-screen + button rather than the reader AI icon', () => {
    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    const hint = tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === 'chat-empty-state-hint',
    )[0]
    expect(hint).toBeTruthy()
    const text = (hint.props as { children?: unknown }).children
    const flat = Array.isArray(text) ? text.join(' ') : String(text ?? '')
    // The new copy must reference the "+" affordance directly visible in
    // the header — NOT the reader's AI icon (which is on another screen).
    expect(flat).toMatch(/\+/)
    expect(flat).not.toMatch(/AI icon/i)
  })
})
