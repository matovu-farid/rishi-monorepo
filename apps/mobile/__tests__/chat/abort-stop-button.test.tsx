/**
 * CHT-006 (#56) / A11Y-006 (#103) — Stop button during LLM generation
 * MUST abort the in-flight request.
 *
 * Pre-fix, ChatInput accepted an `onAbort` prop but the chat detail screen
 * never passed one. When the user tapped the stop icon during generation,
 * the button no-op'd: the network call continued, `isQuerying` stayed
 * true, and the only way to "recover" was to wait it out.
 *
 * Red signal:
 *   1. `chat/[bookId].tsx` MUST pass an `onAbort` function to ChatInput.
 *   2. Invoking that `onAbort` MUST abort the AbortController whose
 *      signal is threaded into `askQuestion`.
 *   3. After abort, `isLoading` flips back to false (the hook's catch
 *      block resets state when fetch rejects with AbortError).
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const { data = [], renderItem, keyExtractor, ListHeaderComponent, ListFooterComponent, ListEmptyComponent } = p
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
    { getState: () => ({ isAuthenticated: true, authHydrated: true, openPremiumGate: jest.fn() }) },
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
  addMessage: jest.fn((conversationId: string, role: string, content: string) => ({
    id: `msg-${Math.random()}`,
    conversationId,
    role,
    content,
    sourceChunks: null,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  })),
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

// `askQuestion` returns a never-resolving promise so we can simulate an
// in-flight request. It captures the `signal` (3rd arg) so the test can
// inspect whether the screen aborted it.
let capturedSignal: AbortSignal | null = null
const askQuestionSpy = jest.fn(
  (_text: string, _history: unknown, signal?: AbortSignal) => {
    capturedSignal = signal ?? null
    return new Promise<{ answer: string; sources: unknown[] }>(() => {
      /* never resolves — represents an in-flight LLM call */
    })
  },
)
jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({
    askQuestion: askQuestionSpy,
    // `isLoading` is driven by the screen reading the hook; for this
    // test we don't need to flip it from inside the mock — the screen
    // passes `onAbort` whenever it has a controller, regardless.
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

// Capture both the `onSend` callback (to trigger a fake user send) and
// the `onAbort` callback (the unit under test).
const chatInputRegistry: {
  onSend: ((text: string) => void) | null
  onAbort: (() => void) | null
} = { onSend: null, onAbort: null }
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) => {
      chatInputRegistry.onSend = p.onSend
      chatInputRegistry.onAbort = p.onAbort ?? null
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

describe('CHT-006 / A11Y-006 — Stop button aborts in-flight LLM call (#56 #103)', () => {
  beforeEach(() => {
    askQuestionSpy.mockClear()
    chatInputRegistry.onSend = null
    chatInputRegistry.onAbort = null
    capturedSignal = null
    localParams.current = { bookId: 'book-1' }
  })

  it('passes an AbortSignal into askQuestion and invokes abort() when onAbort fires', async () => {
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

    // Send a question — askQuestion is called with (text, history, signal).
    await act(async () => {
      chatInputRegistry.onSend!('what is this book about?')
      await Promise.resolve()
    })

    expect(askQuestionSpy).toHaveBeenCalledTimes(1)

    // 1. The screen must thread an AbortSignal into askQuestion.
    expect(capturedSignal).not.toBeNull()
    expect(capturedSignal!.aborted).toBe(false)

    // 2. The screen must expose an onAbort callback on ChatInput.
    expect(chatInputRegistry.onAbort).toBeInstanceOf(Function)

    // 3. Invoking onAbort must abort the same signal.
    await act(async () => {
      chatInputRegistry.onAbort!()
      await Promise.resolve()
    })

    expect(capturedSignal!.aborted).toBe(true)

    // Silence unused-tree lint.
    expect(tree).toBeDefined()
  })
})
