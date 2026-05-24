/**
 * Conversation delete affordance — issue #60.
 *
 * The chat tab previously wired `handleDelete` only through the row's
 * `onLongPress`. That gesture is invisible — users don't discover it.
 *
 * Acceptance criterion: a visible affordance that, when activated,
 * triggers the same `Alert.alert` confirm flow → `softDeleteConversation`
 * → list reloads.
 *
 * This test asserts the screen-level wiring of the new `onSwipeDelete`
 * prop end-to-end:
 *   1. The chat screen passes `onSwipeDelete` to ConversationRow.
 *   2. Invoking that callback opens the destructive Alert.
 *   3. Tapping the "Delete" button in the Alert calls
 *      `softDeleteConversation` with the row's id.
 *
 * The Detox acceptance line in the original issue body is substituted
 * with this jest-level test: Detox is NOT installed in this repo (see
 * `apps/mobile/package.json`). This test exercises the same surface via
 * testID + handler invocation.
 */

const alertMock = jest.fn()

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
    Alert: { alert: alertMock },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
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

jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef(
    (
      p: {
        children?: React.ReactNode
        index?: number
      },
      _ref: unknown,
    ) => {
      const open = (p.index ?? -1) >= 0
      return React.createElement('BottomSheet', p, open ? p.children : null)
    },
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
    SafeAreaView: (p: any) =>
      React.createElement('SafeAreaView', p, p.children),
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

const softDeleteMock = jest.fn()

const mockConversations: {
  id: string
  bookId: string
  title: string
  createdAt: number
  updatedAt: number
}[] = []
const mockBooks: {
  id: string
  title: string
  format: string
  coverPath: string | null
}[] = []

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => mockConversations.slice(),
  getConversationsForBook: (bookId: string) =>
    mockConversations.filter((c) => c.bookId === bookId),
  getMessages: () => [],
  softDeleteConversation: (...args: unknown[]) => softDeleteMock(...args),
}))
jest.mock('@/lib/book-storage', () => ({
  getBookById: (id: string) => mockBooks.find((b) => b.id === id) ?? null,
  getBooks: () => mockBooks.slice(),
}))
jest.mock('@/lib/rag/vector-store', () => ({ isBookEmbedded: () => true }))

// Capture the props that the chat screen passes to ConversationRow so we
// can drive `onSwipeDelete` from the test. The real ConversationRow is
// covered by `conversation-row-delete-action.test.tsx` — here we only need
// to assert that the screen wires the new prop.
const conversationRowProps: Record<string, unknown>[] = []
jest.mock('@/components/ConversationRow', () => {
  const React = require('react')
  return {
    ConversationRow: (p: any) => {
      conversationRowProps.push(p)
      return React.createElement('ConversationRow', { testID: p.testID })
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

describe('Conversation list — visible delete affordance (#60)', () => {
  beforeEach(() => {
    mockConversations.length = 0
    mockBooks.length = 0
    conversationRowProps.length = 0
    alertMock.mockReset()
    softDeleteMock.mockReset()
  })

  it('passes onSwipeDelete to ConversationRow', () => {
    mockBooks.push({
      id: 'b1',
      title: 'War and Peace',
      format: 'epub',
      coverPath: null,
    })
    mockConversations.push({
      id: 'conv-1',
      bookId: 'b1',
      title: 'A',
      createdAt: 1,
      updatedAt: 1,
    })

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    act(() => {
      TestRenderer.create(<ConversationsScreen />)
    })

    expect(conversationRowProps.length).toBe(1)
    const props = conversationRowProps[0] as { onSwipeDelete?: () => void }
    expect(typeof props.onSwipeDelete).toBe('function')
  })

  it('opens the destructive Alert confirm when onSwipeDelete is invoked', () => {
    mockBooks.push({
      id: 'b1',
      title: 'War and Peace',
      format: 'epub',
      coverPath: null,
    })
    mockConversations.push({
      id: 'conv-1',
      bookId: 'b1',
      title: 'A',
      createdAt: 1,
      updatedAt: 1,
    })

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    act(() => {
      TestRenderer.create(<ConversationsScreen />)
    })

    const props = conversationRowProps[0] as { onSwipeDelete?: () => void }
    act(() => {
      props.onSwipeDelete?.()
    })

    expect(alertMock).toHaveBeenCalledTimes(1)
    const [title, message, buttons] = alertMock.mock.calls[0] as [
      string,
      string,
      Array<{ text: string; style?: string; onPress?: () => void }>,
    ]
    expect(title).toBe('Delete Conversation')
    expect(typeof message).toBe('string')
    expect(buttons.find((b) => b.style === 'destructive')?.text).toBe('Delete')
    expect(buttons.find((b) => b.style === 'cancel')?.text).toBe('Cancel')
  })

  it('calls softDeleteConversation with the row id when the destructive button is tapped', () => {
    mockBooks.push({
      id: 'b1',
      title: 'War and Peace',
      format: 'epub',
      coverPath: null,
    })
    mockConversations.push({
      id: 'conv-99',
      bookId: 'b1',
      title: 'A',
      createdAt: 1,
      updatedAt: 1,
    })

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    act(() => {
      TestRenderer.create(<ConversationsScreen />)
    })

    const props = conversationRowProps[0] as { onSwipeDelete?: () => void }
    act(() => {
      props.onSwipeDelete?.()
    })

    const buttons = alertMock.mock.calls[0][2] as Array<{
      text: string
      style?: string
      onPress?: () => void
    }>
    const destructive = buttons.find((b) => b.style === 'destructive')
    expect(destructive).toBeDefined()
    act(() => {
      destructive?.onPress?.()
    })

    expect(softDeleteMock).toHaveBeenCalledTimes(1)
    expect(softDeleteMock).toHaveBeenCalledWith('conv-99')
  })
})
