/**
 * LibraryScreen — critic-sweep fix #112 / PRF-008.
 *
 * The FlatList previously bound a fresh `renderItem` and `keyExtractor`
 * closure on every parent re-render (e.g. on every keystroke into the
 * search input). React Native's VirtualizedList compares those
 * callback identities frame-over-frame and treats identity changes as
 * a cell-shape change, which forces a full list reconcile + remount of
 * every BookRow cell.
 *
 * The fix hoists both callbacks to `useCallback`-stable references so
 * their identity survives unrelated parent re-renders. We pin two
 * acceptance assertions:
 *
 *   1. `keyExtractor` reference is identical before / after a parent
 *      re-render caused by the search input.
 *   2. `renderItem` reference is identical before / after that same
 *      parent re-render.
 *
 * The pre-existing `library-screen.test.tsx` virtualization suite
 * covers `getItemLayout`, `removeClippedSubviews`, `windowSize`, and
 * `initialNumToRender` — we do not duplicate those here.
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
      ItemSeparatorComponent,
      ListEmptyComponent,
    } = p
    if ((data as unknown[]).length === 0 && ListEmptyComponent) {
      const emptyNode = React.isValidElement(ListEmptyComponent)
        ? ListEmptyComponent
        : typeof ListEmptyComponent === 'function'
          ? React.createElement(ListEmptyComponent)
          : null
      return React.createElement('FlatList', { ...p, ref: r }, emptyNode)
    }
    const items = (data as unknown[]).map((item, index) => {
      const key = keyExtractor ? keyExtractor(item, index) : String(index)
      const rendered = renderItem ? renderItem({ item, index }) : null
      const sep =
        ItemSeparatorComponent && index < data.length - 1
          ? React.createElement(ItemSeparatorComponent, { key: `${key}-sep` })
          : null
      return React.createElement(
        React.Fragment,
        { key },
        rendered,
        sep,
      )
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

jest.mock('expo-router', () => {
  const React = require('react')
  // Stable router instance across renders (real `useRouter` returns
  // the same object reference frame-over-frame). The shared library
  // mock returns a fresh `{ push }` object each call, which produces
  // an unstable identity for any `useCallback([router, ...])` we
  // wrap; that bleeds into renderItem and defeats the perf assertion.
  const router = { push: jest.fn(), replace: jest.fn(), back: jest.fn() }
  return {
    useRouter: () => router,
    useFocusEffect: (cb: () => void) => {
      React.useEffect(() => {
        const cleanup = cb()
        return typeof cleanup === 'function' ? cleanup : undefined
      }, [cb])
    },
  }
})

jest.mock('expo-file-system', () => ({
  Directory: class {
    exists = false
    constructor(_a?: unknown, _b?: unknown) {}
    delete() {}
  },
  Paths: { document: '/tmp' },
}))

jest.mock('expo-haptics', () => ({
  selectionAsync: jest.fn(),
  impactAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

jest.mock('@/components/ui', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { ...p }),
    Hairline: require('@/components/ui/Hairline').Hairline,
  }
})
jest.mock('@/components/ui/BookCover', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { ...p }),
  }
})

jest.mock('@/components/UrlImportSheet', () => ({
  UrlImportSheet: () => null,
}))

jest.mock('@/components/SyncStatusIndicator', () => {
  const React = require('react')
  return {
    SyncStatusIndicator: () =>
      React.createElement('SyncStatusIndicator', { testID: 'sync-status' }),
  }
})

const mockBooks: unknown[] = []
let mockLastReadBook: unknown = null
jest.mock('@/lib/book-storage', () => ({
  getBooks: () => mockBooks,
  getLastReadBook: () => mockLastReadBook,
  deleteBook: jest.fn(),
}))

jest.mock('@/lib/file-import', () => ({
  importEpubFile: jest.fn(async () => ({ ok: true, book: null })),
  importPdfFile: jest.fn(async () => ({ ok: true, book: null })),
  importMobiFile: jest.fn(async () => ({ ok: true, book: null })),
  importDjvuFile: jest.fn(async () => ({ ok: true, book: null })),
}))

jest.mock('@/lib/onboarding/useTourTarget', () => ({
  useTourTargetLayout: () => ({ ref: { current: null }, onLayout: () => {} }),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import LibraryScreen from '@/app/(tabs)/index'

function findFlatList(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance {
  return tree.root.findByType('FlatList' as never)
}

const seedBook = {
  id: 'b1',
  title: 'Crime and Punishment',
  author: 'Dostoyevsky',
  format: 'epub' as const,
  filePath: '/tmp/cp.epub',
  coverPath: null,
  currentCfi: null,
  currentPage: null,
  createdAt: 0,
}

describe('LibraryScreen FlatList stability (#112 / PRF-008)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  function typeIntoSearch(
    tree: TestRenderer.ReactTestRenderer,
    text: string,
  ): void {
    const search = tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === 'library-search',
    )[0]
    act(() => {
      ;(search.props as { onChangeText?: (s: string) => void }).onChangeText?.(
        text,
      )
    })
  }

  it('keyExtractor identity survives a parent re-render caused by the search input', () => {
    mockBooks.push(seedBook, {
      ...seedBook,
      id: 'b2',
      title: 'War and Peace',
      filePath: '/tmp/wp.epub',
    })
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const before = (findFlatList(tree).props as {
      keyExtractor?: (item: unknown, idx: number) => string
    }).keyExtractor
    expect(typeof before).toBe('function')
    typeIntoSearch(tree, 'p')
    const after = (findFlatList(tree).props as {
      keyExtractor?: (item: unknown, idx: number) => string
    }).keyExtractor
    expect(after).toBe(before)
  })

  it('renderItem identity survives a parent re-render caused by the search input', () => {
    mockBooks.push(seedBook, {
      ...seedBook,
      id: 'b2',
      title: 'War and Peace',
      filePath: '/tmp/wp.epub',
    })
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const before = (findFlatList(tree).props as { renderItem?: unknown })
      .renderItem
    expect(typeof before).toBe('function')
    typeIntoSearch(tree, 'p')
    const after = (findFlatList(tree).props as { renderItem?: unknown })
      .renderItem
    expect(after).toBe(before)
  })

  it('keyExtractor returns book.id (sanity contract pin)', () => {
    mockBooks.push(seedBook)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const { keyExtractor } = findFlatList(tree).props as {
      keyExtractor: (item: { id: string }, idx: number) => string
    }
    expect(keyExtractor(seedBook, 0)).toBe('b1')
  })
})
