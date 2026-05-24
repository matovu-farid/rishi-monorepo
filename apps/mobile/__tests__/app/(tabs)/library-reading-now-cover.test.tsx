/**
 * LibraryScreen — critic-sweep fix #96 / STA-021.
 *
 * The "Reading Now" hero card used to render the same hash-based
 * letter fallback as any row, which gave the user no "cover pending"
 * signal for books whose cover extraction was deferred. The fix is
 * twofold:
 *
 *   1. `BookCover` now accepts a `loading` prop that renders a
 *      dashed-border placeholder (see
 *      `__tests__/components/ui/BookCover-loading.test.tsx`).
 *   2. LibraryScreen forwards `loading=true` to the Reading Now
 *      `BookCover` whenever `book.coverPath == null` AND
 *      `book.coverExtractionFailed !== true` — i.e. the cover is
 *      pending, not genuinely missing.
 *
 * This file pins (2). The BookCover stub captures the `loading` prop
 * passed in for the Reading Now card so we can assert without
 * traversing the full BookCover render tree.
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
  return {
    useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
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

// Stub BookCover so we can inspect the props the screen forwarded.
// `book-cover-reading-now` testID is set on the LibraryScreen side so
// we can target the hero pill specifically (NOT a row cell).
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

const mockBooks: any[] = []
let mockLastReadBook: any = null
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

function findReadingNowCover(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance | null {
  const hits = tree.root.findAll(
    (n) =>
      typeof n.type === 'string' &&
      (n.props as { testID?: string }).testID === 'reading-now-cover',
  )
  return hits[0] ?? null
}

const baseBook = {
  id: 'b1',
  title: 'Crime and Punishment',
  author: 'Dostoyevsky',
  format: 'epub' as const,
  filePath: '/tmp/cp.epub',
  coverPath: null as string | null,
  currentCfi: null,
  currentPage: null,
  createdAt: 0,
}

describe('LibraryScreen Reading Now card (#96 / STA-021)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  it('passes loading=true when the last-read book has no cover yet and extraction has NOT failed', () => {
    mockBooks.push(baseBook)
    mockLastReadBook = { ...baseBook, coverPath: null, coverExtractionFailed: false }
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const cover = findReadingNowCover(tree)
    expect(cover).not.toBeNull()
    expect((cover!.props as { loading?: boolean }).loading).toBe(true)
  })

  it('passes loading=false when the last-read book has a real cover', () => {
    mockBooks.push(baseBook)
    mockLastReadBook = { ...baseBook, coverPath: 'file:///tmp/c.png' }
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const cover = findReadingNowCover(tree)
    expect(cover).not.toBeNull()
    expect((cover!.props as { loading?: boolean }).loading).toBe(false)
  })

  it('passes loading=false when cover extraction is GENUINELY failed (letter tile path)', () => {
    // When extraction has been attempted AND failed, the letter-tile
    // fallback is the right signal — the cover is genuinely
    // unavailable, not pending. So the screen must NOT force the
    // dotted placeholder in that case.
    mockBooks.push(baseBook)
    mockLastReadBook = {
      ...baseBook,
      coverPath: null,
      coverExtractionFailed: true,
    }
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const cover = findReadingNowCover(tree)
    expect(cover).not.toBeNull()
    expect((cover!.props as { loading?: boolean }).loading).toBe(false)
  })
})
