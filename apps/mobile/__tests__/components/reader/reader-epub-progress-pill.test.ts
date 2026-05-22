/**
 * P1-J — EPUB reader progress pill must show a page % derived from the
 * epubjs `progress` arg (3rd param to onRelocated, a 0..1 float), NOT
 * the chapter label / raw href.
 *
 * Pre-fix: `progressForShell` in `app/reader/[id].tsx` resolved to a
 * `{ kind: 'cfi', label }` pill whose label was the chapter title or
 * the raw href. The pill in ReaderShell's bottom bar rendered text like
 * "Chapter 3" or "OEBPS/ch03.xhtml" instead of "42 / 100".
 *
 * Post-fix: a pure helper `computeEpubProgressForShell(progress)` maps
 * epubjs's 0..1 float to the `{ kind: 'page', current, total }` shape
 * that `ReaderProgressPill` already knows how to format ("42 / 100").
 *
 * This test imports JUST that pure helper from `app/reader/[id].tsx`.
 * To make the import resolve in jest's `testEnvironment: 'node'` we
 * mock every heavy dependency (react-native, expo-router, the epubjs
 * bridge, gesture-handler, safe-area, and the @/-aliased modules that
 * touch the filesystem / MMKV / SQLite at module load).
 */

// ── React Native primitives ─────────────────────────────────────────────
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: { children?: React.ReactNode }, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, (p as { children?: React.ReactNode }).children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    AppState: { addEventListener: () => ({ remove: () => {} }) },
    AppStateStatus: undefined,
    ActivityIndicator: mk('ActivityIndicator'),
    AccessibilityInfo: { announceForAccessibility: () => {} },
    StyleSheet: { create: <T,>(s: T) => s, hairlineWidth: 0.5, absoluteFill: {} },
    Dimensions: { get: () => ({ width: 0, height: 0 }) },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>) => spec.ios ?? spec.default },
  }
})

// ── Routing / navigation ────────────────────────────────────────────────
jest.mock('expo-router', () => ({
  useLocalSearchParams: () => ({}),
  useRouter: () => ({ back: () => {}, replace: () => {}, push: () => {} }),
}))

// ── Native haptics (RDR-027 imports `expo-haptics` for bookmark feedback;
//   the package ships ES modules so jest needs a stub) ──────────────────
jest.mock('expo-haptics', () => ({
  notificationAsync: jest.fn(),
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

// ── EPUB engine bridge ──────────────────────────────────────────────────
jest.mock('@epubjs-react-native/core', () => ({
  Reader: () => null,
  ReaderProvider: ({ children }: { children: React.ReactNode }) => children,
  useReader: () => ({
    toc: [],
    goToLocation: () => {},
    changeTheme: () => {},
    changeFontSize: () => {},
    changeFontFamily: () => {},
    addAnnotation: () => {},
    removeAnnotationByCfi: () => {},
    search: () => {},
    searchResults: { results: [] },
    clearSearchResults: () => {},
    isSearching: false,
  }),
}))

// ── Gesture / safe-area host ────────────────────────────────────────────
jest.mock('react-native-gesture-handler', () => ({
  GestureHandlerRootView: ({ children }: { children: React.ReactNode }) => children,
}))
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
}))

// ── App-local modules with side effects at import time ──────────────────
jest.mock('@/lib/epub/file-system-adapter', () => ({ useFileSystem: () => undefined }))
jest.mock('@/lib/book-storage', () => ({
  getBookForReading: jest.fn(),
  updateBookCfi: jest.fn(),
}))
jest.mock('@/lib/reader-settings', () => ({
  loadReaderSettings: () => ({ themeName: 'light', fontSize: 100, fontFamily: 'default' }),
  saveReaderSettings: jest.fn(),
}))
jest.mock('@/lib/navigation', () => ({ safeBack: jest.fn() }))
jest.mock('@/lib/highlight-storage', () => ({
  insertHighlight: jest.fn(),
  getHighlightsByBookId: () => [],
  updateHighlight: jest.fn(),
  deleteHighlight: jest.fn(),
  restoreHighlight: jest.fn(),
}))
jest.mock('@/lib/bookmarks/bookmark-storage', () => ({
  getBookmarksForBook: () => [],
  toggleBookmark: jest.fn(),
  deleteBookmark: jest.fn(),
  isLocationBookmarked: () => false,
}))
jest.mock('@/components/TTSVisualCue', () => ({ TTSVisualCue: () => null }))
jest.mock('@/lib/tts/visual-cue', () => ({
  useVisualCueStore: Object.assign(() => null, { getState: () => ({ setVisualCue: () => {} }) }),
}))
jest.mock('@/lib/tts/visual-cue-classify', () => ({
  classifyParagraphForVisualCue: () => null,
}))
jest.mock('@/components/UndoSnackbar', () => ({ UndoSnackbar: () => null }))
jest.mock('@/hooks/useUndoSnackbar', () => ({
  useUndoSnackbar: () => ({
    visible: false,
    message: '',
    actionLabel: '',
    action: () => {},
    dismiss: () => {},
    show: () => {},
  }),
}))
jest.mock('@/lib/stores/playerStore', () => ({
  usePlayerStore: Object.assign(() => null, {
    getState: () => ({
      send: null,
      currentParagraphs: [],
      activeParagraph: null,
      playingState: 'idle',
      setSend: () => {},
    }),
  }),
}))
jest.mock('@/hooks/usePlayerMachine', () => ({ usePlayerMachine: () => {} }))
jest.mock('@/hooks/useTtsChatBridge', () => ({ useTtsChatBridge: () => {} }))
jest.mock('@/hooks/usePageCaptureRef', () => ({ usePageCaptureRef: () => {} }))
jest.mock('@/lib/tts/seed-paragraphs', () => ({ seedPlayerParagraphsFromChunks: jest.fn() }))
jest.mock('@/lib/epub/read-aloud-from-selection', () => ({ resolveEpubReadFromSelection: () => null }))
jest.mock('@/hooks/useRealtimeChat', () => ({
  useRealtimeChat: () => ({
    status: 'idle',
    showGuardrailWarning: false,
    toggle: () => {},
    isActive: false,
  }),
}))
jest.mock('@/components/auth/useRequireAuth', () => ({ useRequireAuth: () => (fn: () => void) => fn() }))
jest.mock('@/components/GuardrailWarning', () => ({ GuardrailWarning: () => null }))
jest.mock('@/components/AnnotationPopover', () => ({ AnnotationPopover: () => null }))
jest.mock('@/components/reader', () => ({
  ReaderShell: () => null,
  ReaderShellContext: { Provider: () => null },
  ReaderErrorScreen: () => null,
}))
jest.mock('@/constants/reader-themes', () => ({
  READER_THEMES: { light: { background: '#fff', color: '#000' } },
}))
jest.mock('@/types/highlight', () => ({
  HIGHLIGHT_COLORS: [{ name: 'yellow', hex: '#FBBF24' }],
  HIGHLIGHT_OPACITY: 0.4,
}))
jest.mock('@/lib/theme', () => ({ useTheme: () => ({ colors: {}, spacing: {}, radius: {}, typography: { scale: { footnote: {} } } }) }))

// eslint-disable-next-line import/first
import { computeEpubProgressForShell } from '@/app/reader/[id]'

describe('P1-J — computeEpubProgressForShell', () => {
  it('maps a 0..1 epubjs progress float to a { kind: page, current, total } pill', () => {
    expect(computeEpubProgressForShell(0.42)).toEqual({
      kind: 'page',
      current: 42,
      total: 100,
    })
  })

  it('rounds to the nearest whole percent', () => {
    expect(computeEpubProgressForShell(0.4249)).toEqual({
      kind: 'page',
      current: 42,
      total: 100,
    })
    expect(computeEpubProgressForShell(0.425)).toEqual({
      kind: 'page',
      current: 43,
      total: 100,
    })
  })

  it('clamps the boundaries to [0, 100]', () => {
    expect(computeEpubProgressForShell(0)).toEqual({ kind: 'page', current: 0, total: 100 })
    expect(computeEpubProgressForShell(1)).toEqual({ kind: 'page', current: 100, total: 100 })
  })

  it('returns { kind: none } when epubjs has not yet produced a progress (NaN / undefined)', () => {
    // epubjs emits NaN before locations are generated; the pill should
    // hide rather than show "NaN / 100".
    expect(computeEpubProgressForShell(Number.NaN)).toEqual({ kind: 'none' })
    expect(computeEpubProgressForShell(undefined as unknown as number)).toEqual({ kind: 'none' })
  })
})
