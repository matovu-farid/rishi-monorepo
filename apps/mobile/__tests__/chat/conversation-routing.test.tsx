/**
 * Conversation routing — defect P0-N.
 *
 * The conversations list and chat detail screens both assumed a single
 * conversation per book, which dropped users into the wrong conversation
 * when a book had more than one. We:
 *   1. Route conversation taps through a `cid` query param:
 *        /chat/${bookId}?cid=${conversationId}
 *   2. On chat detail mount, prefer the conversation matching the `cid`
 *      param; only fall back to "first existing" when no cid is given.
 *      Only create a NEW conversation when no cid and no existing.
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
    TextInput: mk('TextInput'),
    Image: mk('Image'),
    ActivityIndicator: mk('ActivityIndicator'),
    KeyboardAvoidingView: mk('KeyboardAvoidingView'),
    ScrollView: mk('ScrollView'),
    FlatList,
    Alert: { alert: jest.fn() },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(() => new Promise(() => {})),
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
    FadeIn: { duration: () => ({ withInitialValues: () => ({}) }) },
    FadeOut: { duration: () => ({}) },
    SlideInLeft: { duration: () => ({}) },
    SlideInRight: { duration: () => ({}) },
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    withTiming: (v: unknown) => v,
    withSpring: (v: unknown) => v,
    Easing: { out: () => null, quad: null, inOut: () => null },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  const SafeAreaView = (p: any) =>
    React.createElement('SafeAreaView', p, p.children)
  return {
    SafeAreaView,
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

// ── expo-router (router.push captured for assertions) ────────────────────
const pushSpy = jest.fn()
const localParams: { current: Record<string, string | undefined> } = {
  current: {},
}
jest.mock('expo-router', () => {
  const React = require('react')
  return {
    useRouter: () => ({ push: pushSpy, replace: jest.fn(), back: jest.fn() }),
    useLocalSearchParams: () => localParams.current,
    useFocusEffect: (cb: () => void) => {
      React.useEffect(() => {
        const cleanup = cb()
        return typeof cleanup === 'function' ? cleanup : undefined
      }, [cb])
    },
  }
})

// ── IconSymbol leaf stub ─────────────────────────────────────────────────
jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

// ── Premium auth gate: always run the action ────────────────────────────
jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

// ── authStore — chat tab reads isAuthenticated for the lock chip (P1-T)
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: true }),
}))

// LockChip stub — decouples this test from @expo/vector-icons.
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

// ── Conversation + book storage mocks ────────────────────────────────────
type ConvSeed = { id: string; bookId: string; title: string; createdAt: number; updatedAt: number }
const mockConversations: ConvSeed[] = []
const mockBooks: { id: string; title: string; format: string; coverPath: string | null }[] = []
const createConversationSpy = jest.fn()
const getMessagesSpy = jest.fn(() => [])

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => mockConversations.slice(),
  getConversationsForBook: (bookId: string) =>
    mockConversations.filter((c) => c.bookId === bookId),
  getMessages: (id: string) => getMessagesSpy(id),
  addMessage: jest.fn(),
  softDeleteConversation: jest.fn(),
  createConversation: (bookId: string) => {
    createConversationSpy(bookId)
    const conv = {
      id: `new-conv-${bookId}`,
      bookId,
      title: 'New conversation',
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }
    mockConversations.push(conv)
    return conv
  },
}))

jest.mock('@/lib/book-storage', () => ({
  getBookById: (id: string) => mockBooks.find((b) => b.id === id) ?? null,
  getBooks: () => mockBooks.slice(),
  getBookForReading: jest.fn(async (id: string) =>
    mockBooks.find((b) => b.id === id) ?? null,
  ),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  isBookEmbedded: () => true,
  searchSimilarChunks: jest.fn(),
}))
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: jest.fn(async () => undefined),
}))

// Hooks pulled in by chat detail screen.
jest.mock('@/hooks/useEmbeddingModel', () => ({
  useEmbeddingModel: () => ({ isReady: true, downloadProgress: 1 }),
}))
jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({ askQuestion: jest.fn(async () => ({ answer: '', sources: [] })), isLoading: false }),
}))
jest.mock('@/hooks/useVoiceInput', () => ({
  useVoiceInput: () => ({
    isRecording: false,
    isTranscribing: false,
    error: null,
    permissionDenied: false,
    startRecording: jest.fn(),
    stopAndTranscribe: jest.fn(),
  }),
}))

// Leaf components — keep them small.
jest.mock('@/components/ChatMessage', () => {
  const React = require('react')
  return { ChatMessage: (p: any) => React.createElement('ChatMessage', p) }
})
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return { ChatInput: (p: any) => React.createElement('ChatInput', p) }
})
jest.mock('@/components/ModelDownloadCard', () => {
  const React = require('react')
  return { ModelDownloadCard: (p: any) => React.createElement('ModelDownloadCard', p) }
})
jest.mock('@/components/EmbeddingProgress', () => {
  const React = require('react')
  return { EmbeddingProgress: (p: any) => React.createElement('EmbeddingProgress', p) }
})
// Track all rendered ConversationRow props by testID so the test can
// invoke `onPress` directly without going through a host-element prop
// (host elements drop function props in react-test-renderer).
const conversationRowRegistry = new Map<string, { onPress: () => void; onLongPress?: () => void }>()
jest.mock('@/components/ConversationRow', () => {
  const React = require('react')
  return {
    ConversationRow: (p: any) => {
      if (p.testID) {
        conversationRowRegistry.set(p.testID, {
          onPress: p.onPress,
          onLongPress: p.onLongPress,
        })
      }
      return React.createElement(
        'ConversationRow',
        { testID: p.testID },
        p.bookTitle,
      )
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

describe('Conversation list — routes by conversation id (P0-N)', () => {
  beforeEach(() => {
    mockConversations.length = 0
    mockBooks.length = 0
    pushSpy.mockClear()
    createConversationSpy.mockClear()
    conversationRowRegistry.clear()
    localParams.current = {}
  })

  it('passes ?cid=<convId> when tapping a row (does not assume first match)', () => {
    mockBooks.push({ id: 'book-1', title: 'Book One', format: 'epub', coverPath: null })
    mockConversations.push(
      { id: 'conv-A', bookId: 'book-1', title: 'A', createdAt: 1, updatedAt: 2 },
      { id: 'conv-B', bookId: 'book-1', title: 'B', createdAt: 3, updatedAt: 4 },
    )

    // Import after mocks are set up.
    const ConversationsScreen = require('@/app/(tabs)/chat').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ConversationsScreen />)
    })

    const rowB = findByTestID(tree, 'conversation-row-conv-B')
    expect(rowB).not.toBeNull()
    const handlers = conversationRowRegistry.get('conversation-row-conv-B')
    expect(handlers).toBeDefined()
    act(() => {
      handlers!.onPress()
    })

    expect(pushSpy).toHaveBeenCalledTimes(1)
    const arg = pushSpy.mock.calls[0][0] as string
    expect(arg).toContain('/chat/book-1')
    expect(arg).toContain('cid=conv-B')
  })
})

describe('Chat detail — loads conversation by ?cid (P0-N)', () => {
  beforeEach(() => {
    mockConversations.length = 0
    mockBooks.length = 0
    pushSpy.mockClear()
    createConversationSpy.mockClear()
    getMessagesSpy.mockClear()
    localParams.current = {}
  })

  it('loads conv-B (not conv-A) when ?cid=conv-B is in params', () => {
    mockBooks.push({ id: 'book-1', title: 'Book One', format: 'epub', coverPath: null })
    mockConversations.push(
      { id: 'conv-A', bookId: 'book-1', title: 'A', createdAt: 1, updatedAt: 4 },
      { id: 'conv-B', bookId: 'book-1', title: 'B', createdAt: 3, updatedAt: 2 },
    )
    localParams.current = { bookId: 'book-1', cid: 'conv-B' }

    const BookChatScreen = require('@/app/chat/[bookId]').default
    act(() => {
      TestRenderer.create(<BookChatScreen />)
    })

    // getMessages must have been called with conv-B's id (the requested
    // conversation), not conv-A (which is updatedAt-first).
    const calledIds = getMessagesSpy.mock.calls.map((c) => c[0] as string)
    expect(calledIds).toContain('conv-B')
    expect(calledIds).not.toContain('conv-A')
    // And we did NOT create a brand-new conversation.
    expect(createConversationSpy).not.toHaveBeenCalled()
  })

  it('creates a new conversation when no cid AND no existing conversations', () => {
    mockBooks.push({ id: 'book-1', title: 'Book One', format: 'epub', coverPath: null })
    localParams.current = { bookId: 'book-1' }

    const BookChatScreen = require('@/app/chat/[bookId]').default
    act(() => {
      TestRenderer.create(<BookChatScreen />)
    })

    expect(createConversationSpy).toHaveBeenCalledTimes(1)
    expect(createConversationSpy).toHaveBeenCalledWith('book-1')
  })

  it('falls back to first existing conversation when no cid is supplied', () => {
    mockBooks.push({ id: 'book-1', title: 'Book One', format: 'epub', coverPath: null })
    mockConversations.push(
      { id: 'conv-A', bookId: 'book-1', title: 'A', createdAt: 1, updatedAt: 4 },
    )
    localParams.current = { bookId: 'book-1' }

    const BookChatScreen = require('@/app/chat/[bookId]').default
    act(() => {
      TestRenderer.create(<BookChatScreen />)
    })

    const calledIds = getMessagesSpy.mock.calls.map((c) => c[0] as string)
    expect(calledIds).toContain('conv-A')
    expect(createConversationSpy).not.toHaveBeenCalled()
  })
})
