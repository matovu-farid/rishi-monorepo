/**
 * Library tab screen (mobile) — defect P0-I.
 *
 * The screen was bypassing the design system: Tailwind grays, a
 * hardcoded `#0a7ea4`, and a Material-style floating-action button.
 * We migrate to:
 *   - background           ➜ colors.background.primary
 *   - "Reading Now" eyebrow ➜ colors.accent.primary
 *   - Subtitle / placeholder ➜ colors.label.secondary
 *   - FAB removed; replaced with an inline header `+` Pressable
 *     (`library-import-button`) so this matches the iOS nav-bar pattern.
 *
 * We pin observable behaviour for both the empty and populated
 * states:
 *   1. The library renders LibraryEmptyState when there are no books
 *      AND exposes the header `+` action even in that state.
 *   2. The Material FAB (`import-book-fab` testID) is GONE.
 *   3. A header-right import button (`library-import-button`) is
 *      always present and tappable.
 *   4. With seeded books, BookRow rows render.
 */

// ─── react-native primitives (kept very minimal: enough surface for
// FlatList + Pressable/TouchableOpacity to mount in node) ────────────────
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  const FlatList = React.forwardRef((p: any, r: unknown) => {
    const { data = [], renderItem, keyExtractor, ItemSeparatorComponent } = p
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
      // Returns a never-resolving promise so `useTheme`'s async setState
      // doesn't fire outside of `act` after the renderer finishes.
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
    // Mirror the real semantics: only re-run when the callback identity
    // changes. Naive `(cb) => cb()` would re-fire on every render and the
    // inner `loadBooks` setState would loop the tree.
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

// `@/components/ui` barrel pulls in Sheet → gesture-handler which doesn't
// compile under ts-jest in node mode. Stub the consumed exports.
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

// UrlImportSheet pulls in @gorhom/bottom-sheet — stub completely.
jest.mock('@/components/UrlImportSheet', () => ({
  UrlImportSheet: () => null,
}))

// SyncStatusIndicator pulls in zustand + sync state. Stub to a leaf.
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
  importEpubFile: jest.fn(async () => null),
  importPdfFile: jest.fn(async () => null),
  importMobiFile: jest.fn(async () => null),
  importDjvuFile: jest.fn(async () => null),
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

describe('LibraryScreen (P0-I: uses design tokens, removes FAB)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  it('does NOT render the Material FAB (`import-book-fab`)', () => {
    mockBooks.push({
      id: 'b1',
      title: 'Crime and Punishment',
      author: 'Dostoyevsky',
      format: 'epub',
      filePath: '/tmp/cp.epub',
      coverPath: null,
      currentCfi: null,
      currentPage: null,
      createdAt: 0,
    })
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const fab = findAll(
      tree,
      (n) => (n.props as { testID?: string }).testID === 'import-book-fab',
    )
    expect(fab.length).toBe(0)
  })

  it('renders a header-right import button (`library-import-button`)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const headerImport = findAll(
      tree,
      (n) =>
        (n.props as { testID?: string }).testID === 'library-import-button',
    )
    expect(headerImport.length).toBeGreaterThan(0)
  })

  it('mounts LibraryEmptyState when there are no books', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const empty = findAll(
      tree,
      (n) => (n.props as { testID?: string }).testID === 'library-empty-state',
    )
    expect(empty.length).toBeGreaterThan(0)
  })

  it('renders BookRows when there are seeded books', () => {
    mockBooks.push(
      {
        id: 'b1',
        title: 'Crime and Punishment',
        author: 'Dostoyevsky',
        format: 'epub',
        filePath: '/tmp/cp.epub',
        coverPath: null,
        currentCfi: null,
        currentPage: null,
        createdAt: 0,
      },
      {
        id: 'b2',
        title: 'War and Peace',
        author: 'Tolstoy',
        format: 'epub',
        filePath: '/tmp/wp.epub',
        coverPath: null,
        currentCfi: null,
        currentPage: null,
        createdAt: 0,
      },
    )
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const rows = findAll(
      tree,
      (n) =>
        typeof n.type === 'string' &&
        typeof (n.props as { testID?: string }).testID === 'string' &&
        (n.props as { testID: string }).testID.startsWith('library-book-row-'),
    )
    expect(rows.length).toBe(2)
  })
})
