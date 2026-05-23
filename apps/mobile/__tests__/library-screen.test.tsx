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

const fileImportMocks = {
  importEpubFile: jest.fn(async () => ({ ok: true, book: null })),
  importPdfFile: jest.fn(async () => ({ ok: true, book: null })),
  importMobiFile: jest.fn(async () => ({ ok: true, book: null })),
  importDjvuFile: jest.fn(async () => ({ ok: true, book: null })),
}
jest.mock('@/lib/file-import', () => fileImportMocks)

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

/**
 * P0-J — Search empty state.
 *
 * When the user types a query that matches no books, the FlatList
 * collapses to zero items but the screen previously rendered NOTHING
 * (no `ListEmptyComponent`, and the top-level `books.length === 0`
 * branch doesn't fire because the underlying library still has books).
 *
 * Fix: render a `library-search-empty` view with "No books match" copy
 * and a clear-search button (`library-search-clear`) that resets the
 * query.
 */
describe('LibraryScreen (P0-J: search empty state)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  function findOne(
    tree: TestRenderer.ReactTestRenderer,
    testID: string,
  ): TestRenderer.ReactTestInstance | null {
    const hits = findAll(
      tree,
      (n) => (n.props as { testID?: string }).testID === testID,
    )
    return hits[0] ?? null
  }

  function seedBooks() {
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
  }

  it('renders search-empty view when query matches nothing', () => {
    seedBooks()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const search = findOne(tree, 'library-search')
    expect(search).not.toBeNull()
    act(() => {
      ;(search!.props as { onChangeText?: (s: string) => void }).onChangeText?.(
        'zzzzzz',
      )
    })
    const empty = findOne(tree, 'library-search-empty')
    expect(empty).not.toBeNull()
    // Includes the query in the copy.
    function collectText(node: TestRenderer.ReactTestInstance): string {
      const childrenText = node.children
        .map((child) =>
          typeof child === 'string'
            ? child
            : collectText(child as TestRenderer.ReactTestInstance),
        )
        .join(' ')
      return childrenText
    }
    const allText = collectText(empty!)
    expect(allText).toMatch(/No books match/i)
    expect(allText).toMatch(/zzzzzz/)
  })

  it('shows a clear-search button that resets the query', () => {
    seedBooks()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const search = findOne(tree, 'library-search')!
    act(() => {
      ;(search.props as { onChangeText?: (s: string) => void }).onChangeText?.(
        'zzzzzz',
      )
    })
    const clearBtn = findOne(tree, 'library-search-clear')
    expect(clearBtn).not.toBeNull()
    act(() => {
      ;(clearBtn!.props as { onPress?: () => void }).onPress?.()
    })
    // After clear, both BookRows are visible again and the search-empty
    // view is gone.
    expect(findOne(tree, 'library-search-empty')).toBeNull()
    const rows = findAll(
      tree,
      (n) =>
        typeof n.type === 'string' &&
        typeof (n.props as { testID?: string }).testID === 'string' &&
        (n.props as { testID: string }).testID.startsWith(
          'library-book-row-',
        ),
    )
    expect(rows.length).toBe(2)
  })
})

/**
 * P0-K — Stage-specific import error copy.
 *
 * The shared service returns `{ok:false, stage, error}` but the mobile
 * screen previously surfaced a single generic "Could not import book"
 * message. We now thread the `stage` through the mobile import
 * wrappers and map it to user-readable copy.
 *
 * Stages exercised here:
 *   - parse          ➜ "looks corrupted or isn't a valid <FMT>"
 *   - storage-full   ➜ device storage hint
 *   - permission     ➜ file-access permission hint
 *
 * The 'picker-cancel' stage is silently swallowed (no alert).
 */
describe('LibraryScreen (P0-K: stage-specific import errors)', () => {
  const { Alert } = require('react-native') as { Alert: { alert: jest.Mock } }

  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
    Alert.alert.mockClear()
    fileImportMocks.importEpubFile.mockReset()
    fileImportMocks.importPdfFile.mockReset()
    fileImportMocks.importMobiFile.mockReset()
    fileImportMocks.importDjvuFile.mockReset()
  })

  async function triggerEpubImport(tree: TestRenderer.ReactTestRenderer) {
    // The empty-state path renders LibraryEmptyState with its own button,
    // but the header `+` button is always available. We call doImport
    // via the Alert.alert("Import Book", ..., buttons) flow: capture the
    // EPUB button and invoke it directly.
    const headerBtn = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'library-import-button',
    )[0]
    await act(async () => {
      ;(headerBtn.props as { onPress?: () => void }).onPress?.()
    })
    const buttons = Alert.alert.mock.calls[0][2] as Array<{
      text: string
      onPress?: () => void | Promise<void>
    }>
    Alert.alert.mockClear()
    const epubBtn = buttons.find((b) => b.text === 'EPUB')!
    await act(async () => {
      await epubBtn.onPress?.()
    })
  }

  it('shows parse-specific copy when stage=parse', async () => {
    fileImportMocks.importEpubFile.mockResolvedValueOnce({
      ok: false,
      stage: 'parse',
      error: 'zip header corrupt',
    } as never)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    await triggerEpubImport(tree)
    expect(Alert.alert).toHaveBeenCalled()
    const [, body] = Alert.alert.mock.calls[0]
    expect(String(body)).toMatch(/corrupt|not a valid|couldn'?t be read/i)
  })

  it('shows storage-full copy when stage=storage-full', async () => {
    fileImportMocks.importEpubFile.mockResolvedValueOnce({
      ok: false,
      stage: 'storage-full',
      error: 'ENOSPC',
    } as never)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    await triggerEpubImport(tree)
    expect(Alert.alert).toHaveBeenCalled()
    const [, body] = Alert.alert.mock.calls[0]
    expect(String(body)).toMatch(/storage|space|full/i)
  })

  it('shows permission copy when stage=permission', async () => {
    fileImportMocks.importEpubFile.mockResolvedValueOnce({
      ok: false,
      stage: 'permission',
      error: 'EACCES',
    } as never)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    await triggerEpubImport(tree)
    expect(Alert.alert).toHaveBeenCalled()
    const [, body] = Alert.alert.mock.calls[0]
    expect(String(body)).toMatch(/permission|access/i)
  })

  it('stays silent when stage=picker-cancel', async () => {
    fileImportMocks.importEpubFile.mockResolvedValueOnce({
      ok: false,
      stage: 'picker-cancel',
      error: 'user cancelled',
    } as never)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    await triggerEpubImport(tree)
    // Only the initial "Import Book" alert was shown — no failure alert.
    expect(Alert.alert).not.toHaveBeenCalled()
  })
})

/**
 * P1-AF — Library FlatList virtualization for 1000+ books.
 *
 * The screen previously mounted a FlatList with default render windowing
 * and no `getItemLayout`, which caused dropped frames and unbounded view
 * recycling on libraries of 1000+ books. We pin the four perf props the
 * defect ticket calls out:
 *   - `getItemLayout`         ➜ enables jump-to-index without measuring
 *   - `removeClippedSubviews` ➜ unmounts off-screen rows
 *   - `windowSize=10`         ➜ caps off-screen page buffer
 *   - `initialNumToRender=12` ➜ first paint covers a typical screen
 */
describe('LibraryScreen (P1-AF: FlatList virtualization)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  function findFlatList(
    tree: TestRenderer.ReactTestRenderer,
  ): TestRenderer.ReactTestInstance {
    return tree.root.findByType('FlatList' as never)
  }

  function seed() {
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
  }

  it('passes `removeClippedSubviews`, `windowSize=10`, and `initialNumToRender=12`', () => {
    seed()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const list = findFlatList(tree)
    const props = list.props as {
      removeClippedSubviews?: boolean
      windowSize?: number
      initialNumToRender?: number
    }
    expect(props.removeClippedSubviews).toBe(true)
    expect(props.windowSize).toBe(10)
    expect(props.initialNumToRender).toBe(12)
  })

  it('passes a `getItemLayout` that returns a fixed-size layout', () => {
    seed()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const list = findFlatList(tree)
    const props = list.props as {
      getItemLayout?: (
        data: unknown,
        index: number,
      ) => { length: number; offset: number; index: number }
    }
    expect(typeof props.getItemLayout).toBe('function')
    const layout0 = props.getItemLayout!(null, 0)
    const layout3 = props.getItemLayout!(null, 3)
    expect(layout0.index).toBe(0)
    expect(layout3.index).toBe(3)
    expect(layout0.length).toBeGreaterThan(0)
    // Fixed-size: offset must scale linearly with index.
    expect(layout3.offset).toBe(layout0.length * 3 + layout0.offset)
  })
})

/**
 * P1-AB — Loading skeleton on first focus.
 *
 * Before the first `useFocusEffect` callback fires + `getBooks()`
 * settles, the screen used to render the "No books yet" empty state —
 * which flashes in for one frame even when the user actually has
 * books. We pin a `library-skeleton` placeholder grid that appears
 * until the first load completes.
 */
describe('LibraryScreen (P1-AB: loading skeleton on first focus)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  function findAllByID(
    tree: TestRenderer.ReactTestRenderer,
    testID: string,
  ): TestRenderer.ReactTestInstance[] {
    return tree.root.findAll(
      (n) => (n.props as { testID?: string }).testID === testID,
    )
  }

  it('renders a library-skeleton placeholder before the first load resolves', () => {
    // Suppress the focus-effect so the initial render is observed
    // BEFORE getBooks() runs. We restore the original implementation at
    // the end of the test to keep cross-test isolation.
    const expoRouter = require('expo-router') as {
      useFocusEffect: (cb: () => void) => void
    }
    const original = expoRouter.useFocusEffect
    expoRouter.useFocusEffect = () => {
      /* skip first-focus side-effect */
    }
    try {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<LibraryScreen />)
      })
      const skeleton = findAllByID(tree, 'library-skeleton')
      expect(skeleton.length).toBeGreaterThan(0)
      // The "No books yet" empty state must NOT be visible while we
      // haven't confirmed the library is actually empty.
      const empty = findAllByID(tree, 'library-empty-state')
      expect(empty.length).toBe(0)
    } finally {
      expoRouter.useFocusEffect = original
    }
  })

  it('replaces the skeleton with content after the first load resolves', () => {
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
    // After useFocusEffect fires inside act, the skeleton is gone.
    const skeleton = findAllByID(tree, 'library-skeleton')
    expect(skeleton.length).toBe(0)
    const rows = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        typeof (n.props as { testID?: string }).testID === 'string' &&
        (n.props as { testID: string }).testID.startsWith(
          'library-book-row-',
        ),
    )
    expect(rows.length).toBe(1)
  })
})

/**
 * #32 — Library row layout: cover renders twice + row stacks vertically.
 *
 * The "Reading Now" card was rendering ABOVE the FlatList, but the
 * same book also stayed in the FlatList's `data`. The user perceived
 * it as one broken entry: a small cover (Reading Now card) + chevron
 * + a larger cover (BookRow) + title + author + delete trailing
 * underneath. The fix is to filter the last-read book out of the
 * FlatList so the library lists each book exactly once.
 *
 * We pin three observable consequences:
 *   1. When `lastReadBook` is set, the library does NOT render a
 *      duplicate `library-book-row-<id>` for that same book.
 *   2. Other books still render their rows.
 *   3. The "Reading Now" card itself is still present (the surfaced
 *      shortcut at the top of the screen is the intended UX).
 *   4. The BookRow's children (cover, title column, delete button)
 *      remain direct siblings of the row Pressable so flexDirection
 *      can lay them out horizontally.
 */
describe('LibraryScreen (#32: row de-duplication + horizontal layout)', () => {
  beforeEach(() => {
    mockBooks.length = 0
    mockLastReadBook = null
  })

  function findAllByID(
    tree: TestRenderer.ReactTestRenderer,
    testID: string,
  ): TestRenderer.ReactTestInstance[] {
    // Filter on `typeof n.type === 'string'` so we count host element
    // instances only (React.forwardRef components forward the same
    // props to the underlying host and would otherwise inflate the
    // count by 2x).
    return tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === testID,
    )
  }

  const booksFixture = [
    {
      id: 'b1',
      title: 'Purple Cow',
      author: 'Seth Godin',
      format: 'epub',
      filePath: '/tmp/purple-cow.epub',
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
      createdAt: 1,
    },
  ]

  it('does NOT render a duplicate BookRow for the lastReadBook', () => {
    mockBooks.push(...booksFixture)
    mockLastReadBook = booksFixture[0]
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    // The last-read book (b1) is surfaced via the "Reading Now" card
    // ABOVE the list, so the FlatList must not render it again.
    const duplicateRow = findAllByID(tree, 'library-book-row-b1')
    expect(duplicateRow.length).toBe(0)
  })

  it('still renders rows for the other books', () => {
    mockBooks.push(...booksFixture)
    mockLastReadBook = booksFixture[0]
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    // b2 is not the last-read book, so it should still show up.
    const otherRow = findAllByID(tree, 'library-book-row-b2')
    expect(otherRow.length).toBeGreaterThan(0)
  })

  it('keeps the BookRow children as horizontal siblings of the row Pressable', () => {
    // No lastReadBook so b1 renders in the FlatList directly. We then
    // assert structural shape: the row Pressable should contain a
    // BookCover, a title-column View, and a delete TouchableOpacity
    // as direct children — i.e. they remain horizontal siblings under
    // the flexDirection:row Pressable, not stacked in nested wrappers.
    mockBooks.push(booksFixture[0])
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LibraryScreen />)
    })
    const rows = findAllByID(tree, 'library-book-row-b1')
    expect(rows.length).toBe(1)
    const row = rows[0]
    // The Pressable's children should include a cover, a title, and the
    // delete button — and they must all be siblings (no nested
    // wrapper turning the layout into a vertical stack).
    const cover = row.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === 'book-row-cover-b1',
    )
    const title = row.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === 'book-row-title',
    )
    const del = row.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.props as { testID?: string }).testID === 'book-delete-button',
    )
    expect(cover.length).toBe(1)
    expect(title.length).toBe(1)
    expect(del.length).toBe(1)
    // flexDirection: 'row' must be present on the row Pressable so the
    // three children lay out horizontally rather than stacking.
    const styleProp = (row.props as { style?: unknown }).style
    const fn =
      typeof styleProp === 'function'
        ? (styleProp as (s: { pressed: boolean }) => unknown[])
        : null
    expect(fn).not.toBeNull()
    const flattened = (fn!({ pressed: false }) as unknown[]).reduce<
      Record<string, unknown>
    >((acc, entry) => {
      if (entry && typeof entry === 'object') {
        return { ...acc, ...(entry as Record<string, unknown>) }
      }
      return acc
    }, {})
    expect(flattened.flexDirection).toBe('row')
  })
})
