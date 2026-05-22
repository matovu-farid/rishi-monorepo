/**
 * Orphan conversation rows — defect P0-M.
 *
 * The conversation list rendered "Unknown Book" rows for conversations
 * whose underlying book had been deleted, and still navigated on tap.
 * Behaviour we pin: orphaned rows are filtered out of the rendered list
 * entirely (the conversation row is NOT mounted).
 */

// ── react-native primitives ──────────────────────────────────────────────
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

// `@gorhom/bottom-sheet` pulls in `react-native-gesture-handler` which uses
// untransformed TS in node_modules. Stub the surface used by `Sheet` and the
// downstream `NewConversationSheet`.
jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef(
    (
      p: {
        children?: React.ReactNode
        index?: number
        backdropComponent?: (props: unknown) => React.ReactElement
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

// authStore — chat tab now reads isAuthenticated for the lock chip (P1-T).
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: true }),
}))

// LockChip — stub so this test stays decoupled from @expo/vector-icons.
jest.mock('@/components/auth/LockChip', () => {
  const React = require('react')
  return {
    __esModule: true,
    LockChip: (p: any) =>
      React.createElement('LockChipStub', {
        testID: p.testID ?? 'lock-chip',
      }),
  }
})

const mockConversations: { id: string; bookId: string; title: string; createdAt: number; updatedAt: number }[] = []
const mockBooks: { id: string; title: string; format: string; coverPath: string | null }[] = []

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => mockConversations.slice(),
  getConversationsForBook: (bookId: string) =>
    mockConversations.filter((c) => c.bookId === bookId),
  getMessages: () => [],
  softDeleteConversation: jest.fn(),
}))
jest.mock('@/lib/book-storage', () => ({
  getBookById: (id: string) => mockBooks.find((b) => b.id === id) ?? null,
  getBooks: () => mockBooks.slice(),
}))
jest.mock('@/lib/rag/vector-store', () => ({ isBookEmbedded: () => true }))

jest.mock('@/components/ConversationRow', () => {
  const React = require('react')
  return {
    ConversationRow: (p: any) =>
      React.createElement('ConversationRow', { testID: p.testID }, p.bookTitle),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

function findAll(
  tree: TestRenderer.ReactTestRenderer,
  predicate: (n: TestRenderer.ReactTestInstance) => boolean,
) {
  return tree.root.findAll(predicate)
}

describe('Conversation list — orphans hidden when underlying book is gone (P0-M)', () => {
  beforeEach(() => {
    mockConversations.length = 0
    mockBooks.length = 0
  })

  it('does NOT render a row for a conversation whose book has been deleted', () => {
    mockBooks.push({ id: 'live-book', title: 'Live Book', format: 'epub', coverPath: null })
    mockConversations.push(
      { id: 'conv-live', bookId: 'live-book', title: 'Live', createdAt: 1, updatedAt: 1 },
      { id: 'conv-orphan', bookId: 'deleted-book', title: 'Orphan', createdAt: 2, updatedAt: 2 },
    )

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    const rows = findAll(
      tree,
      (n) =>
        typeof n.type === 'string' &&
        typeof (n.props as { testID?: string }).testID === 'string' &&
        (n.props as { testID: string }).testID.startsWith('conversation-row-'),
    )
    const testIDs = rows.map((r) => (r.props as { testID: string }).testID)
    expect(testIDs).toContain('conversation-row-conv-live')
    expect(testIDs).not.toContain('conversation-row-conv-orphan')
  })

  it('shows the empty-state when ALL conversations are orphans', () => {
    mockConversations.push(
      { id: 'orphan-1', bookId: 'gone-1', title: 'A', createdAt: 1, updatedAt: 1 },
      { id: 'orphan-2', bookId: 'gone-2', title: 'B', createdAt: 2, updatedAt: 2 },
    )

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    const empty = findAll(
      tree,
      (n) => (n.props as { testID?: string }).testID === 'chat-empty-state',
    )
    expect(empty.length).toBeGreaterThan(0)
  })
})
