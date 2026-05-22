/**
 * STA-018 (#94) — Failed sends MUST mark the offending message row.
 *
 * Pre-fix, the user's message was optimistically appended to the list
 * before the network call. When `askQuestion` rejected, only a global
 * inline-error banner appeared at the top of the list — the failed
 * user-message row itself looked indistinguishable from a successful
 * one. There was no per-row affordance to retry.
 *
 * Red signal: when `askQuestion` rejects, the user-message row that
 * triggered the failed send must render with a failure indicator (we
 * pin to a testID — `chat-message-failed-{messageId}`) and expose a
 * tappable retry control (`chat-message-failed-retry-{messageId}`).
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

let msgCounter = 0
jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => [],
  getConversationsForBook: (bookId: string) => [
    { id: `conv-${bookId}`, bookId, title: 'T', createdAt: 1, updatedAt: 2 },
  ],
  getMessages: () => [],
  addMessage: jest.fn(
    (conversationId: string, role: string, content: string) => {
      const msg = {
        id: `msg-${++msgCounter}`,
        conversationId,
        role: role as 'user' | 'assistant',
        content,
        sourceChunks: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      }
      return msg
    },
  ),
  softDeleteConversation: jest.fn(),
  createConversation: jest.fn(),
}))

jest.mock('@/lib/book-storage', () => ({
  getBookById: () => ({ id: 'book-1', title: 'Book', format: 'epub' }),
  getBooks: () => [],
  getBookForReading: jest.fn(async () => ({
    id: 'book-1',
    title: 'Book',
    format: 'epub',
    filePath: '/tmp/book.epub',
  })),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  isBookEmbedded: () => true,
  searchSimilarChunks: jest.fn(),
}))
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: jest.fn(async () => undefined),
}))

const askQuestionSpy = jest.fn()
jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({
    askQuestion: askQuestionSpy,
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
  return {
    ChatMessage: (p: any) =>
      React.createElement('ChatMessage', {
        testID: p.testID,
        content: p.message?.content,
      }),
  }
})

const chatInputRegistry: {
  onSend: ((text: string) => void) | null
} = { onSend: null }
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) => {
      chatInputRegistry.onSend = p.onSend
      return React.createElement('ChatInput', { testID: 'chat-input' })
    },
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

describe('STA-018 — failed message rows are marked + retryable (#94)', () => {
  beforeEach(() => {
    askQuestionSpy.mockReset()
    chatInputRegistry.onSend = null
    pushSpy.mockClear()
    msgCounter = 0
    localParams.current = { bookId: 'book-1' }
  })

  it('marks the user-message row when askQuestion rejects, and exposes a per-row retry', async () => {
    // First send rejects (network), second send (the retry) resolves.
    askQuestionSpy
      .mockImplementationOnce(async () => {
        throw new Error('network')
      })
      .mockImplementationOnce(async () => ({ answer: 'ok', sources: [] }))

    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(chatInputRegistry.onSend).toBeTruthy()

    // Send the message that will fail.
    await act(async () => {
      chatInputRegistry.onSend!('why does this break?')
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(askQuestionSpy).toHaveBeenCalledTimes(1)

    // The user message id is `msg-1` (counter increments inside addMessage).
    const failedMarker = findByTestID(tree, 'chat-message-failed-msg-1')
    expect(failedMarker).not.toBeNull()

    const retryBtn = findByTestID(tree, 'chat-message-failed-retry-msg-1')
    expect(retryBtn).not.toBeNull()

    // Tap retry — askQuestion is called again.
    await act(async () => {
      ;(retryBtn!.props as { onPress: () => void }).onPress()
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(askQuestionSpy).toHaveBeenCalledTimes(2)
    // After successful retry, the failed marker should no longer render.
    expect(findByTestID(tree, 'chat-message-failed-msg-1')).toBeNull()
  })
})
