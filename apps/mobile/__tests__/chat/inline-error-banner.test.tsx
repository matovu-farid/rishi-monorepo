/**
 * CHT-019 — RAG inline-error banner must render as a sibling above
 * `ChatInput`, NOT inside the inverted FlatList's ListHeaderComponent.
 *
 * On an inverted FlatList the "header" renders at the bottom of the
 * data list, which is the bottom of the scroll content — so the error
 * was drawn underneath the messages rather than attached to the failed
 * turn. The banner is supposed to sit immediately above the input where
 * the user is looking for a Retry CTA.
 *
 * We pin: the error banner exists with testID `chat-inline-error-banner`
 * and is NOT a descendant of the FlatList (it's a sibling), so its
 * vertical placement is no longer entangled with the inverted layout.
 */

const mockEmbedBook = jest.fn(async () => undefined)
let mockIsBookEmbedded = true

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const { data = [], renderItem, keyExtractor, ListHeaderComponent, ListFooterComponent } = p
    const items = (data as unknown[]).map((item, index) => {
      const key = keyExtractor ? keyExtractor(item, index) : String(index)
      const rendered = renderItem ? renderItem({ item, index }) : null
      return React.createElement(React.Fragment, { key }, rendered)
    })
    return React.createElement(
      'FlatList',
      { ...p, ref: r },
      ListHeaderComponent ?? null,
      ...items,
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
    KeyboardAvoidingView: mk('KeyboardAvoidingView'),
    FlatList,
    Alert: { alert: jest.fn() },
    Linking: { openSettings: jest.fn() },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
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
    FadeIn: { duration: () => ({ withInitialValues: () => ({}) }) },
    FadeOut: { duration: () => ({}) },
    SlideInRight: { duration: () => ({}) },
    SlideInLeft: { duration: () => ({}) },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: (p: any) => React.createElement('SafeAreaView', p, p.children),
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

jest.mock('expo-router', () => ({
  useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn(), canGoBack: () => true }),
  useLocalSearchParams: () => ({ bookId: 'book-1' }),
}))

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
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

jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) =>
      React.createElement('ChatInput', { testID: 'chat-input-stub', ...p }),
  }
})

jest.mock('@/components/ChatMessage', () => {
  const React = require('react')
  return {
    ChatMessage: (p: any) =>
      React.createElement('ChatMessage', { testID: p.testID }),
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

const mockAskQuestion = jest.fn()
jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({
    askQuestion: mockAskQuestion,
    isLoading: false,
  }),
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

jest.mock('@/hooks/useEmbeddingModel', () => ({
  useEmbeddingModel: () => ({ isReady: true, downloadProgress: 1 }),
}))

jest.mock('@/lib/book-storage', () => ({
  getBookForReading: async () => ({
    id: 'book-1',
    title: 'Book',
    format: 'epub',
    filePath: '/tmp/book.epub',
  }),
  getBookById: () => null,
}))

jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: (...args: unknown[]) => mockEmbedBook(...args),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  isBookEmbedded: () => mockIsBookEmbedded,
}))

const mockMessages: { id: string; conversationId: string; role: string; content: string; createdAt: number }[] = []
jest.mock('@/lib/conversation-storage', () => ({
  createConversation: () => ({ id: 'conv-1', bookId: 'book-1' }),
  getConversationsForBook: () => [{ id: 'conv-1', bookId: 'book-1' }],
  getMessages: () => mockMessages.slice(),
  addMessage: (cid: string, role: string, content: string) => {
    const m = { id: `m-${mockMessages.length + 1}`, conversationId: cid, role, content, createdAt: Date.now() }
    mockMessages.push(m)
    return m
  },
}))

jest.mock('@/lib/navigation', () => ({ safeBack: jest.fn() }))
jest.mock('@/lib/reader-routes', () => ({ resolveReaderRouteForBook: () => '/reader/book-1' }))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

function flushAsync() {
  return new Promise<void>((res) => setImmediate(res))
}

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  id: string,
): TestRenderer.ReactTestInstance | null {
  const found = tree.root.findAll(
    (n) => (n.props as { testID?: string }).testID === id,
  )
  return found[0] ?? null
}

function isDescendantOf(
  candidate: TestRenderer.ReactTestInstance,
  ancestor: TestRenderer.ReactTestInstance,
): boolean {
  let cur: TestRenderer.ReactTestInstance | null = candidate.parent
  while (cur) {
    if (cur === ancestor) return true
    cur = cur.parent
  }
  return false
}

describe('Chat detail inline-error banner placement (CHT-019)', () => {
  beforeEach(() => {
    mockMessages.length = 0
    mockAskQuestion.mockReset()
    mockEmbedBook.mockReset()
    mockEmbedBook.mockResolvedValue(undefined)
    mockIsBookEmbedded = true
  })

  it('renders the inline-error banner as a sibling of the FlatList (not inside its header)', async () => {
    mockAskQuestion.mockRejectedValueOnce(new Error('network'))

    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
      await flushAsync()
    })
    await act(async () => {
      await flushAsync()
    })

    // Drive a send through ChatInput's onSend prop.
    const input = findByTestID(tree, 'chat-input-stub')
    expect(input).toBeTruthy()
    await act(async () => {
      ;(input!.props as { onSend: (t: string) => void | Promise<void> }).onSend(
        'why did the chicken cross the road',
      )
      await flushAsync()
    })

    const banner = findByTestID(tree, 'chat-inline-error-banner')
    expect(banner).toBeTruthy()

    // The banner must NOT live under the FlatList — it should be a
    // sibling above ChatInput so its vertical position is independent
    // of the inverted layout.
    const flatList = tree.root.findAll(
      (n) => (n.type as unknown) === 'FlatList',
    )[0]
    expect(flatList).toBeTruthy()
    expect(isDescendantOf(banner!, flatList)).toBe(false)
  })
})
