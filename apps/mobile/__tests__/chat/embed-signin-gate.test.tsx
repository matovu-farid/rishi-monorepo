/**
 * P1-AL — Chat embed runs even when signed out and never surfaces failure.
 *
 * Pre-fix, the embedBook effect fired unconditionally on mount, which
 * meant signed-out users hit the network for chunk uploads / server
 * fallback and got opaque rejections (or silent no-ops) with no path
 * to recover.
 *
 * Red signal: when `useAuthStore.isAuthenticated` is false, the chat
 * detail screen MUST NOT call `embedBook` and MUST render an inline
 * sign-in banner with a CTA that funnels through `requireAIChat`. The
 * input stays disabled while signed out.
 */

// ── react-native primitives ──────────────────────────────────────────────
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

// authStore — selector-aware mock so the screen can read both
// `isAuthenticated` and `authHydrated`.
const authState: { isAuthenticated: boolean; authHydrated: boolean } = {
  isAuthenticated: false,
  authHydrated: true,
}
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: typeof authState) => T) => selector(authState),
}))

// `useRequireAuth` returns a function that — when not authenticated —
// records the feature it was constructed with. Tapping the sign-in CTA
// must funnel through the 'ai-chat' gate.
const requireAuthCalls: Array<{ feature: string; ran: boolean }> = []
jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: (feature: string) => {
    return (action: () => void) => {
      const entry = { feature, ran: false }
      requireAuthCalls.push(entry)
      if (authState.isAuthenticated) {
        entry.ran = true
        action()
      }
    }
  },
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

const embedBookSpy = jest.fn(async () => undefined)
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

describe('P1-AL — sign-in gate for chat embedding', () => {
  beforeEach(() => {
    pushSpy.mockClear()
    embedBookSpy.mockClear()
    chatInputRegistry.disabled = null
    requireAuthCalls.length = 0
    authState.isAuthenticated = false
    authState.authHydrated = true
    localParams.current = { bookId: 'book-1' }
  })

  it('does not call embedBook when signed out and renders a sign-in banner', async () => {
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })

    // embedBook must NOT have been invoked.
    expect(embedBookSpy).not.toHaveBeenCalled()

    // Sign-in banner must be visible with a CTA.
    const banner = findByTestID(tree, 'chat-signin-gate-banner')
    expect(banner).not.toBeNull()
    const cta = findByTestID(tree, 'chat-signin-gate-cta')
    expect(cta).not.toBeNull()

    // Send must be disabled while signed out.
    expect(chatInputRegistry.disabled).toBe(true)

    // Tap the sign-in CTA — must route through the ai-chat gate.
    await act(async () => {
      ;(cta!.props as { onPress: () => void }).onPress()
    })
    expect(requireAuthCalls.some((c) => c.feature === 'ai-chat')).toBe(true)
  })
})
