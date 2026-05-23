/**
 * STA-026 (#99) — When the user is signed out, the chat input field
 * itself must be non-editable. ChatInput's send button is already
 * disabled via the `disabled` prop, but the TextInput remained editable
 * — letting the user tap into the field, get a keyboard, and type a
 * draft that they couldn't actually send. Worse, tapping the
 * still-editable field could re-fire the auth gate.
 *
 * Red signal: with `useAuthStore.isAuthenticated === false`, the
 * rendered TextInput inside the real ChatInput component MUST receive
 * `editable={false}`. We do NOT mock ChatInput here — we exercise the
 * full child tree so the assertion proves the chat detail screen
 * passes a `disabled` prop that ChatInput actually honors on the
 * underlying TextInput.
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
    Linking: { openSettings: jest.fn() },
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

// Signed-OUT auth state.
const authState: { isAuthenticated: boolean; authHydrated: boolean } = {
  isAuthenticated: false,
  authHydrated: true,
}
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: Object.assign(
    <T,>(selector: (s: typeof authState) => T) => selector(authState),
    {
      getState: () => ({ ...authState, openPremiumGate: jest.fn() }),
    },
  ),
}))

jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => {
    if (authState.isAuthenticated) action()
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
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: jest.fn(async () => undefined),
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

// VoiceMicButton is rendered inside the real ChatInput; stub it so the
// test doesn't have to satisfy its full prop surface.
jest.mock('@/components/VoiceMicButton', () => {
  const React = require('react')
  return {
    VoiceMicButton: (p: any) =>
      React.createElement('VoiceMicButton', { ...p, testID: 'voice-mic' }),
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

// NOTE: ChatInput is intentionally NOT mocked — the assertion below
// inspects the props of the TextInput that the real ChatInput renders.

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

describe('STA-026 — signed-out chat input is non-editable (#99)', () => {
  beforeEach(() => {
    pushSpy.mockClear()
    authState.isAuthenticated = false
    authState.authHydrated = true
    localParams.current = { bookId: 'book-1' }
  })

  it('renders the TextInput with editable=false while signed out', async () => {
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })

    const textInput = findByTestID(tree, 'chat-input')
    expect(textInput).not.toBeNull()
    expect((textInput!.props as { editable?: boolean }).editable).toBe(false)
  })
})
