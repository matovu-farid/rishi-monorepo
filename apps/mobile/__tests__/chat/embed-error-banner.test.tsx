/**
 * P1-AA — Embedding failure leaves chat input permanently disabled.
 *
 * Pre-fix, the chat detail screen's `embedBook` effect only logged the
 * rejection and flipped `isEmbedding` to false. With `isBookEmbedded`
 * still returning false, `chatDisabled` stayed true forever and the
 * user had no surface to retry. There was no inline banner either.
 *
 * Red signal: when `embedBook` rejects, an inline banner with copy
 * "Could not prepare this book" must appear above ChatInput, expose a
 * Retry control wired back to `embedBook`, and keep the input disabled
 * while the error is active.
 */

// ── react-native primitives (mirror existing chat tests) ─────────────────
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

// Authenticated by default; per-test override via setAuthState below.
const authState: { isAuthenticated: boolean } = { isAuthenticated: true }
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector(authState),
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
  isBookEmbedded: () => false,
  searchSimilarChunks: jest.fn(),
}))

// `embedBook` is the unit under test — first call rejects, second
// call resolves. The screen must call it twice (initial + retry).
const embedBookSpy = jest.fn()
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: (...args: unknown[]) => embedBookSpy(...args),
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

// Capture the latest `disabled` prop ChatInput receives so the test can
// assert chat is locked while the error is active.
const chatInputRegistry: { disabled: boolean | null } = { disabled: null }
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) => {
      chatInputRegistry.disabled = !!p.disabled
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

describe('P1-AA — embed-error banner with retry', () => {
  beforeEach(() => {
    pushSpy.mockClear()
    embedBookSpy.mockReset()
    chatInputRegistry.disabled = null
    authState.isAuthenticated = true
    localParams.current = { bookId: 'book-1' }
  })

  it('renders a banner when embedBook rejects and Retry re-runs embedBook', async () => {
    embedBookSpy
      .mockImplementationOnce(async () => {
        throw new Error('boom')
      })
      .mockImplementationOnce(async () => undefined)

    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    // Drain the async getBookForReading + the rejected embedBook promise.
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(embedBookSpy).toHaveBeenCalledTimes(1)

    // Banner must be visible.
    const banner = findByTestID(tree, 'chat-embed-error-banner')
    expect(banner).not.toBeNull()
    const retry = findByTestID(tree, 'chat-embed-error-retry')
    expect(retry).not.toBeNull()

    // Send must be disabled while the error is active.
    expect(chatInputRegistry.disabled).toBe(true)

    // Tap retry — embedBook must be invoked again.
    await act(async () => {
      ;(retry!.props as { onPress: () => void }).onPress()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(embedBookSpy).toHaveBeenCalledTimes(2)
    // After a successful retry the banner is cleared.
    expect(findByTestID(tree, 'chat-embed-error-banner')).toBeNull()
  })
})
