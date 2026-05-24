/**
 * CHT-010 / Issue #59 — PulsingDot interval leak.
 *
 * Bug: the PulsingDot effect (in apps/mobile/app/chat/[bookId].tsx) used to
 * `return () => clearInterval(interval)` from INSIDE its outer `setTimeout`
 * callback. That cleanup function was returned to the timeout callback (which
 * discards return values), NOT to React. Consequently, React's `useEffect`
 * cleanup only cleared the timeout — never the interval — so the interval
 * kept firing after the component unmounted, leaking timers and triggering
 * `setOpacity` updates on a torn-down tree.
 *
 * This test guards the fix: after mounting PulsingDot, advancing fake timers
 * past `delay` so the interval is created, and unmounting, EVERY id returned
 * by `setInterval` for the duration of the mount MUST have been passed to
 * `clearInterval`.
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
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
    FlatList: mk('FlatList'),
    Alert: { alert: jest.fn() },
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
  }
})

// Reanimated mock — PulsingDot itself does not use Reanimated APIs, but the
// host module (`[bookId].tsx`) imports `Animated, { FadeIn, FadeOut }` at
// top-level, so the mock must exist for the file to load.
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
    SafeAreaView: (p: any) =>
      React.createElement('SafeAreaView', p, p.children),
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  }
})

// The chat-detail module pulls in a heavy graph (expo-router, storage,
// hooks, etc.) that the test does not exercise. We only import the
// `PulsingDot` named export, but ts-jest still evaluates the whole module
// during `require`, so the surrounding singletons need stubs.
jest.mock('expo-router', () => {
  const React = require('react')
  return {
    useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
    useLocalSearchParams: () => ({}),
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
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: { isAuthenticated: boolean }) => T) =>
    selector({ isAuthenticated: true }),
}))
jest.mock('@/lib/conversation-storage', () => ({
  getConversationsForBook: () => [],
  getMessages: () => [],
  addMessage: jest.fn(),
  createConversation: (bookId: string) => ({
    id: `nc-${bookId}`,
    bookId,
    title: 't',
    createdAt: 0,
    updatedAt: 0,
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
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: jest.fn(async () => undefined),
}))
jest.mock('@/hooks/useEmbeddingModel', () => ({
  useEmbeddingModel: () => ({ isReady: true, downloadProgress: 1 }),
}))
jest.mock('@/hooks/useRAGQuery', () => ({
  useRAGQuery: () => ({ askQuestion: jest.fn(), isLoading: false }),
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
      React.createElement('ChatMessage', { testID: p.testID }),
  }
})
jest.mock('@/components/ChatInput', () => {
  const React = require('react')
  return {
    ChatInput: (p: any) => React.createElement('ChatInput', p),
  }
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

describe('PulsingDot interval leak (#59)', () => {
  let intervalSpy: jest.SpyInstance
  let clearIntervalSpy: jest.SpyInstance

  beforeEach(() => {
    jest.useFakeTimers()
    intervalSpy = jest.spyOn(global, 'setInterval')
    clearIntervalSpy = jest.spyOn(global, 'clearInterval')
  })

  afterEach(() => {
    intervalSpy.mockRestore()
    clearIntervalSpy.mockRestore()
    jest.useRealTimers()
  })

  it('clears its interval on unmount (single mount)', () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { PulsingDot } = require('@/app/chat/[bookId]')
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<PulsingDot delay={0} />)
    })

    // Run the outer setTimeout(..., delay) so the interval is created.
    act(() => {
      jest.advanceTimersByTime(50)
    })

    const intervalIdsBefore = intervalSpy.mock.results
      .filter((r) => r.type === 'return')
      .map((r) => r.value as ReturnType<typeof setInterval>)
    expect(intervalIdsBefore.length).toBeGreaterThan(0)

    act(() => {
      tree.unmount()
    })

    const clearedIds = clearIntervalSpy.mock.calls.map(
      (call) => call[0] as ReturnType<typeof setInterval>,
    )
    for (const id of intervalIdsBefore) {
      expect(clearedIds).toContain(id)
    }
  })

  it('does not leak intervals across repeated mount/unmount cycles', () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { PulsingDot } = require('@/app/chat/[bookId]')
    for (let i = 0; i < 5; i++) {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<PulsingDot delay={0} />)
      })
      act(() => {
        jest.advanceTimersByTime(50)
      })
      act(() => {
        tree.unmount()
      })
    }

    const createdIds = intervalSpy.mock.results
      .filter((r) => r.type === 'return')
      .map((r) => r.value as ReturnType<typeof setInterval>)
    const clearedIds = clearIntervalSpy.mock.calls.map(
      (call) => call[0] as ReturnType<typeof setInterval>,
    )
    // Every interval created during the test MUST be in clearedIds —
    // otherwise we have leaked timers that will keep firing on torn-down
    // components.
    expect(createdIds.length).toBeGreaterThan(0)
    for (const id of createdIds) {
      expect(clearedIds).toContain(id)
    }
  })
})
