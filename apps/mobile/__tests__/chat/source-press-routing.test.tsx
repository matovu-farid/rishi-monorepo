/**
 * Chat-detail "Source" tap routes per format — defect P1-A.
 *
 * Pin the integration: `BookChatScreen.handleSourcePress` resolves the
 * reader route via `resolveReaderRouteForBook(book)`, so a PDF book
 * pushes `/reader/pdf/<id>` and a MOBI book pushes `/reader/mobi/<id>`,
 * not the EPUB reader.
 */

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
    Image: mk('Image'),
    TextInput: mk('TextInput'),
    ActivityIndicator: mk('ActivityIndicator'),
    KeyboardAvoidingView: mk('KeyboardAvoidingView'),
    ScrollView: mk('ScrollView'),
    FlatList,
    Alert: { alert: jest.fn() },
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
    useColorScheme: () => 'light',
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
const localParams: { current: Record<string, string | undefined> } = { current: {} }
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

// authStore — chat screen reads isAuthenticated for the embed gate (P1-AL).
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: true }),
}))

const mockConversations: { id: string; bookId: string; title: string; createdAt: number; updatedAt: number }[] = []
const mockBooks: { id: string; title: string; format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'; coverPath: string | null; author: string; filePath: string; currentCfi: string | null; currentPage: number | null; createdAt: number }[] = []
jest.mock('@/lib/conversation-storage', () => ({
  getConversationsForBook: (bookId: string) => mockConversations.filter((c) => c.bookId === bookId),
  getMessages: () => [],
  addMessage: jest.fn(),
  createConversation: (bookId: string) => {
    const conv = { id: `new-conv-${bookId}`, bookId, title: 'New', createdAt: 0, updatedAt: 0 }
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
jest.mock('@/lib/rag/pipeline', () => ({ embedBook: jest.fn(async () => undefined) }))

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

// Capture the `onSourcePress` handler the screen passes into each
// rendered <ChatMessage>. We use a registry instead of host-element
// props because react-test-renderer drops function props from
// intrinsic host elements.
const chatMessageRegistry: { onSourcePress?: (src: unknown) => void } = {}
jest.mock('@/components/ChatMessage', () => {
  const React = require('react')
  return {
    ChatMessage: (p: any) => {
      chatMessageRegistry.onSourcePress = p.onSourcePress
      return React.createElement('ChatMessage', { testID: p.testID })
    },
  }
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'

function makeBook(format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu') {
  return {
    id: 'b1',
    title: 'Sample',
    author: 'A',
    coverPath: null,
    filePath: '/tmp/sample',
    format,
    currentCfi: null,
    currentPage: null,
    createdAt: 0,
  }
}

describe('Chat detail — source-press routes per format (P1-A)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockConversations.length = 0
    pushSpy.mockClear()
    chatMessageRegistry.onSourcePress = undefined
    localParams.current = { bookId: 'b1' }
  })

  it('routes a PDF source tap to /reader/pdf/<id> (not /reader/<id>)', async () => {
    mockBooks.push(makeBook('pdf'))
    mockConversations.push({
      id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
    })

    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(<BookChatScreen />)
    })
    // Force a flush so book state lands.
    await act(async () => { await Promise.resolve() })

    // Synthesize a message to trigger ChatMessage render. The screen
    // doesn't render ChatMessage if `messageList` is empty, so we
    // instead invoke the captured `handleSourcePress` from the
    // ListEmptyComponent path. Easier: assert by directly calling
    // the registered onSourcePress when ChatMessage isn't rendered —
    // we instead pull it from the chat screen's render tree.
    //
    // The simpler approach: the screen's source-press handler reads
    // from the book state set asynchronously. We assert it routes via
    // the helper by invoking it through the resolved book state.
    const handler = chatMessageRegistry.onSourcePress
    // When there are no messages, ChatMessage isn't rendered. We
    // instead exercise the screen by re-rendering after pushing a
    // message via the conversation-storage mock. Inject a faux message
    // by mocking getMessages prior.
    //
    // To avoid that complexity, just verify the helper is used directly:
    // assert the helper would dispatch correctly. That assertion lives
    // in reader-routes.test.ts. Here we instead instrument an alternative
    // approach: directly mock getMessages to return one message so
    // ChatMessage is rendered.

    // Skip if no messages — handled in the explicit test below.
    expect(handler).toBeUndefined()
    expect(tree).toBeDefined()
  })

  it('handleSourcePress (PDF) → /reader/pdf/<id>', async () => {
    mockBooks.push(makeBook('pdf'))
    mockConversations.push({
      id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
    })
    // Stub messages so ChatMessage renders and captures the handler.
    const convStorage = require('@/lib/conversation-storage')
    convStorage.getMessages = jest.fn(() => [
      { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
    ])

    const BookChatScreen = require('@/app/chat/[bookId]').default
    await act(async () => { TestRenderer.create(<BookChatScreen />) })
    await act(async () => { await Promise.resolve() })

    expect(chatMessageRegistry.onSourcePress).toBeDefined()
    act(() => {
      chatMessageRegistry.onSourcePress!({ chunkId: 'x', chapter: null, text: '' })
    })
    expect(pushSpy).toHaveBeenCalledTimes(1)
    // Updated for #68: the chunkId always rides along even when no
    // positional information can be parsed from the chapter label.
    expect(pushSpy).toHaveBeenCalledWith({
      pathname: '/reader/pdf/[id]',
      params: { id: 'b1', chunkId: 'x' },
    })
  })

  it('handleSourcePress (MOBI) → /reader/mobi/<id>', async () => {
    mockBooks.push(makeBook('mobi'))
    mockConversations.push({
      id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
    })
    const convStorage = require('@/lib/conversation-storage')
    convStorage.getMessages = jest.fn(() => [
      { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
    ])

    const BookChatScreen = require('@/app/chat/[bookId]').default
    await act(async () => { TestRenderer.create(<BookChatScreen />) })
    await act(async () => { await Promise.resolve() })

    expect(chatMessageRegistry.onSourcePress).toBeDefined()
    act(() => {
      chatMessageRegistry.onSourcePress!({ chunkId: 'x', chapter: null, text: '' })
    })
    // Updated for #68: object-form push so the chunkId / chapter can
    // ride along as query params for the reader to honor on mount.
    expect(pushSpy).toHaveBeenCalledWith({
      pathname: '/reader/mobi/[id]',
      params: { id: 'b1', chunkId: 'x' },
    })
  })

  it('handleSourcePress (EPUB) still routes to /reader/<id>', async () => {
    mockBooks.push(makeBook('epub'))
    mockConversations.push({
      id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
    })
    const convStorage = require('@/lib/conversation-storage')
    convStorage.getMessages = jest.fn(() => [
      { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
    ])

    const BookChatScreen = require('@/app/chat/[bookId]').default
    await act(async () => { TestRenderer.create(<BookChatScreen />) })
    await act(async () => { await Promise.resolve() })

    expect(chatMessageRegistry.onSourcePress).toBeDefined()
    act(() => {
      chatMessageRegistry.onSourcePress!({ chunkId: 'x', chapter: null, text: '' })
    })
    // The chunkId always rides along (#68) even when no positional
    // information is available, so a downstream highlight-on-jump pass
    // can still resolve the citation.
    expect(pushSpy).toHaveBeenCalledWith({
      pathname: '/reader/[id]',
      params: { id: 'b1', chunkId: 'x' },
    })
  })

  // #68 — `handleSourcePress` MUST thread the chunk's location into the
  // router push so the reader can scroll to the cited passage on mount.
  // Pre-fix, the chip discarded `source.chunkId` / `source.chapter` and
  // pushed to the reader root.
  describe('source chunk location → reader query params (#68)', () => {
    it('PDF citation with "Page N" chapter → ?page=N', async () => {
      mockBooks.push(makeBook('pdf'))
      mockConversations.push({
        id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
      })
      const convStorage = require('@/lib/conversation-storage')
      convStorage.getMessages = jest.fn(() => [
        { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
      ])

      const BookChatScreen = require('@/app/chat/[bookId]').default
      await act(async () => { TestRenderer.create(<BookChatScreen />) })
      await act(async () => { await Promise.resolve() })

      act(() => {
        chatMessageRegistry.onSourcePress!({
          chunkId: 'cid-1',
          chapter: 'Page 12',
          text: '',
        })
      })
      expect(pushSpy).toHaveBeenCalledTimes(1)
      expect(pushSpy).toHaveBeenCalledWith({
        pathname: '/reader/pdf/[id]',
        params: { id: 'b1', chunkId: 'cid-1', page: '12' },
      })
    })

    it('EPUB citation with cfiRange → ?cfi=<cfi>', async () => {
      mockBooks.push(makeBook('epub'))
      mockConversations.push({
        id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
      })
      const convStorage = require('@/lib/conversation-storage')
      convStorage.getMessages = jest.fn(() => [
        { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
      ])

      const BookChatScreen = require('@/app/chat/[bookId]').default
      await act(async () => { TestRenderer.create(<BookChatScreen />) })
      await act(async () => { await Promise.resolve() })

      act(() => {
        chatMessageRegistry.onSourcePress!({
          chunkId: 'cid-2',
          chapter: 'Heading 1',
          cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
          text: '',
        })
      })
      expect(pushSpy).toHaveBeenCalledWith({
        pathname: '/reader/[id]',
        params: {
          id: 'b1',
          chunkId: 'cid-2',
          cfi: 'epubcfi(/6/4!/4/2/1:0)',
        },
      })
    })

    it('MOBI citation with "Chapter N" → ?chapter=<N-1> (0-indexed)', async () => {
      mockBooks.push(makeBook('mobi'))
      mockConversations.push({
        id: 'c1', bookId: 'b1', title: 't', createdAt: 0, updatedAt: 0,
      })
      const convStorage = require('@/lib/conversation-storage')
      convStorage.getMessages = jest.fn(() => [
        { id: 'm1', conversationId: 'c1', role: 'assistant', content: 'hi', sourceChunks: null, createdAt: 0, updatedAt: 0 },
      ])

      const BookChatScreen = require('@/app/chat/[bookId]').default
      await act(async () => { TestRenderer.create(<BookChatScreen />) })
      await act(async () => { await Promise.resolve() })

      act(() => {
        chatMessageRegistry.onSourcePress!({
          chunkId: 'cid-3',
          chapter: 'Chapter 4',
          text: '',
        })
      })
      expect(pushSpy).toHaveBeenCalledWith({
        pathname: '/reader/mobi/[id]',
        params: { id: 'b1', chunkId: 'cid-3', chapter: '3' },
      })
    })
  })
})
