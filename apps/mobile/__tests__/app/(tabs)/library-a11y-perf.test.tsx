/**
 * Library tab — critic-sweep fix #104 / A11Y-007.
 *
 * The header `+` Pressable must expose an `accessibilityLabel` so
 * VoiceOver announces a meaningful name instead of "Button" for the
 * icon-only control. Acceptance text from VALIDATED.md#A11Y-007 pins
 * the label to "Add book".
 *
 * Mock surface mirrors `__tests__/library-screen.test.tsx` — we only
 * pull in the host primitives + stubs needed to mount LibraryScreen in
 * a node test VM.
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

jest.mock('@/components/ui', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { testID: p.testID, ...p }),
    Hairline: require('@/components/ui/Hairline').Hairline,
  }
})
jest.mock('@/components/ui/BookCover', () => {
  const React = require('react')
  return {
    BookCover: (p: any) =>
      React.createElement('BookCover', { testID: p.testID, ...p }),
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

function findAll(
  tree: TestRenderer.ReactTestRenderer,
  predicate: (n: TestRenderer.ReactTestInstance) => boolean,
) {
  return tree.root.findAll(predicate)
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

describe('LibraryScreen (#104 / A11Y-007: import button accessibilityLabel)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  it('exposes accessibilityLabel="Add book" on the header import button (empty state)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const labelled = findAll(
      tree,
      (n) =>
        (n.props as { testID?: string }).testID === 'library-import-button' &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Add book',
    )
    expect(labelled.length).toBeGreaterThan(0)
  })

  it('exposes accessibilityLabel="Add book" on the header import button (populated state)', () => {
    mockBooks.push(seedBook)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const labelled = findAll(
      tree,
      (n) =>
        (n.props as { testID?: string }).testID === 'library-import-button' &&
        (n.props as { accessibilityLabel?: string }).accessibilityLabel ===
          'Add book',
    )
    expect(labelled.length).toBeGreaterThan(0)
  })

  it('keeps accessibilityRole="button" on the import button', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const btn = findAll(
      tree,
      (n) => (n.props as { testID?: string }).testID === 'library-import-button',
    )[0]
    expect(btn).toBeDefined()
    expect(
      (btn!.props as { accessibilityRole?: string }).accessibilityRole,
    ).toBe('button')
  })
})
