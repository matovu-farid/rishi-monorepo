/**
 * RAG history must include the just-typed user turn (P0-P).
 *
 * Pre-fix, `handleSend` in `app/chat/[bookId].tsx` built the history
 * passed to `askQuestion` from the stale `messageList` closure — i.e.
 * the new user message was appended via `setMessageList((prev) => [...])`
 * but the call to `askQuestion(text, history)` still saw the previous
 * snapshot. As a result the LLM was always one message behind.
 *
 * Red signal: `history` captured by `askQuestion` must contain the
 * just-typed user turn AND every prior message.
 */

// ── react-native primitives (mirror the conversation-routing test) ────────
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

jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

// ── Storage mocks — track addMessage so we can return shaped messages ────
type StoredMsg = {
  id: string
  conversationId: string
  role: 'user' | 'assistant'
  content: string
  createdAt: number
}
const messagesByConv = new Map<string, StoredMsg[]>()
let msgCounter = 0
function pushMessage(
  conversationId: string,
  role: 'user' | 'assistant',
  content: string,
): StoredMsg {
  const msg: StoredMsg = {
    id: `msg-${++msgCounter}`,
    conversationId,
    role,
    content,
    createdAt: Date.now(),
  }
  const list = messagesByConv.get(conversationId) ?? []
  list.push(msg)
  messagesByConv.set(conversationId, list)
  return msg
}

jest.mock('@/lib/conversation-storage', () => ({
  getAllConversations: () => [],
  getConversationsForBook: (bookId: string) => [
    { id: `conv-${bookId}`, bookId, title: 'T', createdAt: 1, updatedAt: 2 },
  ],
  // Return a copy so the consumer's setState reference doesn't get
  // mutated when addMessage pushes new rows into the backing array.
  getMessages: (id: string) => (messagesByConv.get(id) ?? []).slice(),
  addMessage: (
    conversationId: string,
    role: 'user' | 'assistant',
    content: string,
  ) => pushMessage(conversationId, role, content),
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

// `askQuestion` spy captures the (text, history) it was called with.
const askQuestionSpy = jest.fn(async () => ({ answer: 'ok', sources: [] }))
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
  return { ChatMessage: (p: any) => React.createElement('ChatMessage', p) }
})

// ChatInput stub — exposes its `onSend` via a registry keyed by render
// order so the test can trigger sends imperatively (host elements drop
// function props in react-test-renderer).
const chatInputRegistry: { onSend: ((text: string) => void) | null } = {
  onSend: null,
}
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
    ModelDownloadCard: (p: any) =>
      React.createElement('ModelDownloadCard', p),
  }
})
jest.mock('@/components/EmbeddingProgress', () => {
  const React = require('react')
  return {
    EmbeddingProgress: (p: any) =>
      React.createElement('EmbeddingProgress', p),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

describe('RAG history includes the current user turn (P0-P)', () => {
  beforeEach(() => {
    messagesByConv.clear()
    msgCounter = 0
    askQuestionSpy.mockClear()
    chatInputRegistry.onSend = null
    pushSpy.mockClear()
    localParams.current = { bookId: 'book-1' }
  })

  it('captured history contains every prior message AND the just-typed turn', async () => {
    // Seed prior conversation so messageList is non-empty when typing.
    pushMessage('conv-book-1', 'user', 'hello')
    pushMessage('conv-book-1', 'assistant', 'hi')

    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })

    // Drain effects so the useEffect that hydrates messageList from
    // getMessages has run.
    await act(async () => {
      await Promise.resolve()
    })

    expect(chatInputRegistry.onSend).toBeTruthy()

    // Send the new turn.
    await act(async () => {
      chatInputRegistry.onSend!('world')
      await Promise.resolve()
    })

    expect(askQuestionSpy).toHaveBeenCalledTimes(1)
    const [text, history] = askQuestionSpy.mock.calls[0] as [
      string,
      Array<{ role: string; content: string }>,
    ]
    expect(text).toBe('world')
    const contents = history.map((m) => m.content)
    // Prior turns must be present.
    expect(contents).toContain('hello')
    expect(contents).toContain('hi')
    // The just-typed user turn must ALSO be in the history (P0-P).
    expect(contents).toContain('world')
    // The last entry should be the current user turn.
    expect(history[history.length - 1]).toEqual({
      role: 'user',
      content: 'world',
    })

    // Silence unused-tree lint.
    expect(tree).toBeDefined()
  })
})
