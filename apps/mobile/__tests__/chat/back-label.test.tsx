/**
 * Chat-detail contextual Back label — defect P1-C.
 *
 * Apple Books renders "‹ Library" or "‹ Conversations" next to the back
 * chevron so the user knows where they're going. The mobile chat detail
 * screen had a label-less chevron. We:
 *   - When the screen mounts with a `from` query param, render
 *     "‹ {From}" next to the chevron.
 *   - When `from` is absent, render no label (defaults safely; the
 *     chevron alone still works).
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

const localParams: { current: Record<string, string | undefined> } = { current: {} }
jest.mock('expo-router', () => {
  const React = require('react')
  return {
    useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
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

jest.mock('@/lib/conversation-storage', () => ({
  getConversationsForBook: () => [],
  getMessages: () => [],
  addMessage: jest.fn(),
  createConversation: (bookId: string) => ({
    id: `nc-${bookId}`, bookId, title: 't', createdAt: 0, updatedAt: 0,
  }),
}))
jest.mock('@/lib/book-storage', () => ({
  getBookById: () => null,
  getBookForReading: jest.fn(async () => null),
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
  useRAGQuery: () => ({ askQuestion: jest.fn(), isLoading: false }),
}))
jest.mock('@/hooks/useVoiceInput', () => ({
  useVoiceInput: () => ({
    isRecording: false, isTranscribing: false, error: null, permissionDenied: false,
    startRecording: jest.fn(), stopAndTranscribe: jest.fn(),
  }),
}))
jest.mock('@/components/ChatMessage', () => {
  const React = require('react')
  return { ChatMessage: (p: any) => React.createElement('ChatMessage', { testID: p.testID }) }
})
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return { ChatInput: (p: any) => React.createElement('ChatInput', p) }
})
jest.mock('@/components/ModelDownloadCard', () => {
  const React = require('react')
  return { ModelDownloadCard: () => React.createElement('ModelDownloadCard') }
})
jest.mock('@/components/EmbeddingProgress', () => {
  const React = require('react')
  return { EmbeddingProgress: () => React.createElement('EmbeddingProgress') }
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

function readTextChildren(node: TestRenderer.ReactTestInstance | null): string {
  if (!node) return ''
  const parts: string[] = []
  const visit = (n: TestRenderer.ReactTestInstance | string) => {
    if (typeof n === 'string') {
      parts.push(n)
      return
    }
    for (const c of n.children) visit(c as any)
  }
  visit(node)
  return parts.join('')
}

describe('Chat detail — contextual Back label (P1-C)', () => {
  beforeEach(() => {
    localParams.current = {}
  })

  it('renders "Library" next to the back chevron when ?from=Library', () => {
    localParams.current = { bookId: 'b1', from: 'Library' }
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => { tree = TestRenderer.create(<BookChatScreen />) })
    const label = findByTestID(tree, 'chat-detail-back-label')
    expect(label).not.toBeNull()
    expect(readTextChildren(label)).toBe('Library')
  })

  it('renders "Conversations" next to the back chevron when ?from=Conversations', () => {
    localParams.current = { bookId: 'b1', from: 'Conversations' }
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => { tree = TestRenderer.create(<BookChatScreen />) })
    const label = findByTestID(tree, 'chat-detail-back-label')
    expect(label).not.toBeNull()
    expect(readTextChildren(label)).toBe('Conversations')
  })

  it('omits the back label when `from` is absent', () => {
    localParams.current = { bookId: 'b1' }
    const BookChatScreen = require('@/app/chat/[bookId]').default
    let tree!: TestRenderer.ReactTestRenderer
    act(() => { tree = TestRenderer.create(<BookChatScreen />) })
    const label = findByTestID(tree, 'chat-detail-back-label')
    expect(label).toBeNull()
  })
})
