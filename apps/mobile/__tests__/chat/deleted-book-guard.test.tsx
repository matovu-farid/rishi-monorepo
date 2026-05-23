/**
 * DAT-018 (#130) — Chat embedding must verify the book row still exists
 * in the local DB before firing `embedBook`. If the book was deleted
 * (e.g. via the library bulk-delete path) the screen should render a
 * "Book was deleted" error screen instead of trying to chunk a stale
 * file path.
 *
 * Red signal:
 *   1. Mock `getBookForReading` to resolve null (book missing).
 *   2. Mount the chat detail screen.
 *   3. `embedBook` MUST NOT have been called.
 *   4. The screen MUST render an error message containing
 *      "Book was deleted" (testID `chat-deleted-book-error`).
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const {
      data = [],
      renderItem,
      keyExtractor,
      ListHeaderComponent,
      ListFooterComponent,
      ListEmptyComponent,
    } = p
    const items = (data as unknown[]).map((item, index) => {
      const key = keyExtractor ? keyExtractor(item, index) : String(index)
      const rendered = renderItem ? renderItem({ item, index }) : null
      return React.createElement(React.Fragment, { key }, rendered)
    })
    return React.createElement(
      'FlatList',
      { ...p, ref: r },
      ListHeaderComponent ?? null,
      items.length === 0 ? ListEmptyComponent ?? null : items,
      ListFooterComponent ?? null,
    )
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
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(() => new Promise(() => {})),
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

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: Object.assign(
    <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
      selector({ isAuthenticated: true }),
    {
      getState: () => ({
        isAuthenticated: true,
        authHydrated: true,
        openPremiumGate: jest.fn(),
      }),
    },
  ),
}))

jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => [],
  getConversationsForBook: (bookId: string) => [
    { id: `conv-${bookId}`, bookId, title: 'T', createdAt: 1, updatedAt: 2 },
  ],
  getMessages: () => [],
  addMessage: jest.fn(),
  softDeleteConversation: jest.fn(),
  createConversation: jest.fn(),
}))

// Book is missing — both lookup paths return null.
const getBookByIdSpy = jest.fn((_id: string) => null)
const getBookForReadingSpy = jest.fn(async (_id: string) => null)
jest.mock('@/lib/book-storage', () => ({
  getBookById: (id: string) => getBookByIdSpy(id),
  getBooks: () => [],
  getBookForReading: (id: string) => getBookForReadingSpy(id),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  isBookEmbedded: () => false,
  searchSimilarChunks: jest.fn(),
}))

const embedBookSpy = jest.fn(async (..._args: unknown[]) => undefined)
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: (bookId: string, filePath: string, format: string, onProgress?: (p: number) => void) =>
    embedBookSpy(bookId, filePath, format, onProgress),
}))

jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({
    askQuestion: jest.fn(async () => ({ answer: '', sources: [] })),
    isLoading: false,
  }),
}))
jest.mock('@/hooks/useEmbeddingModel', () => ({
  useEmbeddingModel: () => ({ isReady: true, downloadProgress: 1 }),
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

jest.mock('@/components/ChatMessage', () => {
  const React = require('react')
  return { ChatMessage: (p: any) => React.createElement('ChatMessage', p) }
})

jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) => React.createElement('ChatInput', { testID: 'chat-input', ...p }),
  }
})
jest.mock('@/components/ModelDownloadCard', () => {
  const React = require('react')
  return {
    ModelDownloadCard: (p: any) => React.createElement('ModelDownloadCard', p),
  }
})
jest.mock('@/components/EmbeddingProgress', () => {
  const React = require('react')
  return {
    EmbeddingProgress: (p: any) => React.createElement('EmbeddingProgress', p),
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

describe('DAT-018 — chat embed guards against deleted books (#130)', () => {
  beforeEach(() => {
    embedBookSpy.mockClear()
    getBookByIdSpy.mockClear()
    getBookForReadingSpy.mockClear()
    getBookByIdSpy.mockReturnValue(null)
    getBookForReadingSpy.mockResolvedValue(null)
    localParams.current = { bookId: 'gone-book' }
  })

  it('does not fire embedBook and renders a deleted-book error when the row is missing', async () => {
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    // Drain async getBookForReading.
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(embedBookSpy).not.toHaveBeenCalled()

    const errScreen = findByTestID(tree, 'chat-deleted-book-error')
    expect(errScreen).not.toBeNull()
  })
})
