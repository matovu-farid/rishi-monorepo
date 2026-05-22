/**
 * P1-AH — Conversations "New conversation" Alert hits iOS button limit and
 * surfaces book-not-embedded UX poorly.
 *
 * Replace `Alert.alert` with a bottom-sheet listing imported books and
 * their embed status, so the user can scroll past 10 books and clearly
 * see which titles are ready for chat.
 *
 * Behaviour pinned:
 *   1. Tapping the "+" button on the Conversations screen MUST NOT call
 *      `Alert.alert`. It must mount the NewConversationSheet (open).
 *   2. The sheet lists ALL imported books, regardless of embed status —
 *      not just the embedded subset.
 *   3. Each row exposes a stable testID and an "embed-status" badge:
 *      `book-row-<id>-status-ready` when isBookEmbedded(id) === true,
 *      `book-row-<id>-status-pending` otherwise.
 *   4. Tapping a book row routes to `/chat/<bookId>?from=Conversations`.
 */

// ── react-native primitives ──────────────────────────────────────────────
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const { data = [], renderItem, keyExtractor, ListEmptyComponent } = p
    const items = (data as unknown[]).map((item, index) => {
      const key = keyExtractor ? keyExtractor(item, index) : String(index)
      const rendered = renderItem ? renderItem({ item, index }) : null
      return React.createElement(React.Fragment, { key }, rendered)
    })
    return React.createElement(
      'FlatList',
      { ...p, ref: r },
      items.length === 0 ? ListEmptyComponent ?? null : items,
    )
  })
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Image: mk('Image'),
    FlatList,
    Alert: { alert: jest.fn() },
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

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: (p: any) => React.createElement('SafeAreaView', p, p.children),
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

const pushSpy = jest.fn()
jest.mock('expo-router', () => {
  const React = require('react')
  return {
    useRouter: () => ({ push: pushSpy, replace: jest.fn(), back: jest.fn() }),
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
  author?: string | null
}[] = []

const embeddedIds = new Set<string>()

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

jest.mock('@/lib/rag/vector-store', () => ({
  isBookEmbedded: (id: string) => embeddedIds.has(id),
}))

jest.mock('@/components/ConversationRow', () => {
  const React = require('react')
  return {
    ConversationRow: (p: any) =>
      React.createElement('ConversationRow', { testID: p.testID }, p.bookTitle),
  }
})

// ── @gorhom/bottom-sheet stub — mirrors the Sheet test's capture pattern ─
jest.mock('@gorhom/bottom-sheet', () => {
  const React = require('react')
  const BottomSheet = React.forwardRef(
    (
      p: {
        onChange?: (i: number) => void
        children?: React.ReactNode
        index?: number
        backdropComponent?: (props: unknown) => React.ReactElement
      },
      _ref: unknown,
    ) => {
      const backdrop = p.backdropComponent
        ? p.backdropComponent({ animatedIndex: { value: 0 } })
        : null
      const open = (p.index ?? -1) >= 0
      return React.createElement(
        'BottomSheet',
        p,
        backdrop,
        open ? p.children : null,
      )
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

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Alert } from 'react-native'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

function findAllByPrefix(
  tree: TestRenderer.ReactTestRenderer,
  prefix: string,
): TestRenderer.ReactTestInstance[] {
  // Filter for host nodes only — the rn mocks wrap every primitive in a
  // forwardRef, so both the component and host node carry the same testID
  // and findAll would otherwise double-count.
  return tree.root.findAll((n) => {
    if (typeof n.type !== 'string') return false
    const id = (n.props as { testID?: string } | null)?.testID
    return typeof id === 'string' && id.startsWith(prefix)
  })
}

describe('P1-AH — NewConversationSheet replaces Alert button-list', () => {
  beforeEach(() => {
    pushSpy.mockClear()
    mockConversations.length = 0
    mockBooks.length = 0
    embeddedIds.clear()
    ;(Alert.alert as jest.Mock).mockClear()
  })

  it('tapping "+" does not call Alert.alert; the sheet mounts instead', () => {
    // Seed enough books to exceed the legacy 10-button Alert limit.
    for (let i = 0; i < 14; i++) {
      mockBooks.push({
        id: `book-${i}`,
        title: `Book ${i}`,
        format: 'epub',
        coverPath: null,
      })
    }
    // Make a couple embedded so the badge branch is exercised.
    embeddedIds.add('book-2')
    embeddedIds.add('book-7')

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    const plus = findByTestID(tree, 'chat-new-conversation-btn')
    expect(plus).not.toBeNull()

    act(() => {
      ;(plus!.props as { onPress: () => void }).onPress()
    })

    // The legacy Alert.alert path must be gone.
    expect(Alert.alert).not.toHaveBeenCalled()

    // The sheet must be open and render a list of book rows.
    const sheet = findByTestID(tree, 'new-conversation-sheet')
    expect(sheet).not.toBeNull()

    const rows = findAllByPrefix(tree, 'new-conversation-book-row-')
    expect(rows.length).toBe(14)
  })

  it('shows embed-status badge per book and routes on tap', () => {
    mockBooks.push(
      { id: 'b-ready', title: 'Ready', format: 'epub', coverPath: null },
      { id: 'b-pending', title: 'Pending', format: 'pdf', coverPath: null },
    )
    embeddedIds.add('b-ready')

    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    act(() => {
      ;(
        findByTestID(tree, 'chat-new-conversation-btn')!
          .props as { onPress: () => void }
      ).onPress()
    })

    expect(findByTestID(tree, 'book-row-b-ready-status-ready')).not.toBeNull()
    expect(findByTestID(tree, 'book-row-b-pending-status-pending')).not.toBeNull()

    // Tapping the row routes to the chat with from=Conversations.
    const readyRow = findByTestID(tree, 'new-conversation-book-row-b-ready')
    expect(readyRow).not.toBeNull()
    act(() => {
      ;(readyRow!.props as { onPress: () => void }).onPress()
    })
    expect(pushSpy).toHaveBeenCalledWith('/chat/b-ready?from=Conversations')
  })
})
