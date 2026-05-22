import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, AppState, AppStateStatus, ActivityIndicator, AccessibilityInfo } from 'react-native'
import * as Haptics from 'expo-haptics'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { Reader, ReaderProvider, useReader } from '@epubjs-react-native/core'
import { useFileSystem } from '@/lib/epub/file-system-adapter'
import { GestureHandlerRootView } from 'react-native-gesture-handler'

import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { getBookForReading, updateBookCfi } from '@/lib/book-storage'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { safeBack } from '@/lib/navigation'
import { insertHighlight, getHighlightsByBookId, updateHighlight, deleteHighlight, restoreHighlight } from '@/lib/highlight-storage'
import {
  getBookmarksForBook,
  toggleBookmark,
  deleteBookmark as deleteBookmarkFromDb,
  isLocationBookmarked,
  type Bookmark,
} from '@/lib/bookmarks/bookmark-storage'
import { TTSVisualCue } from '@/components/TTSVisualCue'
import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { classifyParagraphForVisualCue } from '@/lib/tts/visual-cue-classify'
import { UndoSnackbar } from '@/components/UndoSnackbar'
import { useUndoSnackbar } from '@/hooks/useUndoSnackbar'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { usePlayerMachine } from '@/hooks/usePlayerMachine'
import { useTtsChatBridge } from '@/hooks/useTtsChatBridge'
import { usePageCaptureRef } from '@/hooks/usePageCaptureRef'
import { seedPlayerParagraphsFromChunks } from '@/lib/tts/seed-paragraphs'
import { resolveEpubReadFromSelection } from '@/lib/epub/read-aloud-from-selection'
import { useRealtimeChat } from '@/hooks/useRealtimeChat'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { GuardrailWarning } from '@/components/GuardrailWarning'
import { AnnotationPopover } from '@/components/AnnotationPopover'
import {
  ReaderShell,
  ReaderShellContext,
  ReaderErrorScreen,
  type ReaderErrorCause,
  type ReaderProgress,
} from '@/components/reader'
import { READER_THEMES } from '@/constants/reader-themes'
import { Book, ReaderSettings } from '@/types/book'
import type { Highlight, HighlightColor } from '@/types/highlight'
import { HIGHLIGHT_COLORS, HIGHLIGHT_OPACITY } from '@/types/highlight'
import type { Annotation } from '@epubjs-react-native/core'

/**
 * P1-J — map epubjs's onRelocated `progress` arg (a 0..1 float) into the
 * `ReaderProgress` shape that `ReaderProgressPill` renders as "42 / 100".
 *
 * epubjs emits NaN before book.locations have been generated, and may
 * pass `undefined` if a callsite doesn't forward the param at all. We
 * return `{ kind: 'none' }` in those cases so the pill renders the "—"
 * placeholder instead of "NaN / 100".
 *
 * Floats are rounded to the nearest whole percent and clamped to
 * [0, 100] — epubjs occasionally emits values fractionally outside the
 * range (e.g. 1.0000001) at the very end of the spine.
 *
 * Exported so the unit test in
 * `__tests__/components/reader/reader-epub-progress-pill.test.ts`
 * can pin the math without mounting the EPUB Reader component.
 */
export function computeEpubProgressForShell(progress: number): ReaderProgress {
  if (typeof progress !== 'number' || Number.isNaN(progress)) {
    return { kind: 'none' }
  }
  const clamped = Math.max(0, Math.min(1, progress))
  return { kind: 'page', current: Math.round(clamped * 100), total: 100 }
}

export default function ReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()
  const [book, setBook] = useState<Book | null>(null)

  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)
  // P0-L — track the cause of a failed load so ReaderErrorScreen can
  // pick its copy. `null` means "no error yet"; the post-load gate
  // below resolves to a concrete cause when `book` is missing.
  const [errorCause, setErrorCause] = useState<ReaderErrorCause | null>(null)
  // Bumped on Retry to re-fire the effect.
  const [loadAttempt, setLoadAttempt] = useState(0)

  // Load book from DB (async -- may download file from R2 for synced books).
  // When the lazy-download branch fires, `onDownloadStart` flips the
  // downloading flag so the loading screen renders "Downloading..." copy
  // instead of the fast-path "Loading book..." copy.
  useEffect(() => {
    if (id) {
      setLoading(true)
      setDownloading(false)
      setErrorCause(null)
      getBookForReading(id, { onDownloadStart: () => setDownloading(true) })
        .then((loaded) => setBook(loaded))
        .catch((err) => {
          console.error('Failed to load book for reading:', err)
          setBook(null)
          // The loader only throws from the R2 download path — treat any
          // thrown error as a cloud failure so the user sees a Retry that
          // means something.
          setErrorCause('cloud-download-failed')
        })
        .finally(() => setLoading(false))
    }
  }, [id, loadAttempt])

  if (loading) {
    return (
      <View testID="reader-loading" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" />
        <Text style={{ marginTop: 12, color: '#666' }}>
          {downloading ? 'Downloading…' : 'Loading book…'}
        </Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    // If the loader didn't throw but we still have no usable book, the
    // local file is gone (or the row vanished). Cloud failures already
    // set `errorCause` in the catch branch.
    const resolvedCause: ReaderErrorCause = errorCause ?? 'local-missing'
    return (
      <ReaderErrorScreen
        cause={resolvedCause}
        onBack={() => safeBack(router)}
        onRetry={() => setLoadAttempt((n) => n + 1)}
      />
    )
  }

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <ReaderProvider>
        <ReaderContent book={book} />
      </ReaderProvider>
    </GestureHandlerRootView>
  )
}

function ReaderContent({ book }: { book: Book }) {
  const router = useRouter()
  const insets = useSafeAreaInsets()
  const {
    toc,
    goToLocation,
    changeTheme,
    changeFontSize,
    changeFontFamily,
    addAnnotation,
    removeAnnotationByCfi,
    search,
    searchResults,
    clearSearchResults,
    isSearching,
  } = useReader()

  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())
  const [noteEditorOpen, setNoteEditorOpen] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [currentHref, setCurrentHref] = useState<string | null>(null)
  // RDR-026 — epubjs's spine parse fires AFTER the outer loading state
  // flips, so the user briefly stares at a blank theme-coloured screen.
  // We flip this flag inside `handleLocationChange` (epubjs's first
  // onRelocated emit) and gate an ActivityIndicator overlay on
  // `!engineReady` below.
  const [engineReady, setEngineReady] = useState(false)
  // P1-J — epubjs's `progress` arg (3rd param of onRelocated) is a 0..1
  // float. We mirror it into state so the bottom-bar pill re-renders
  // when the user turns a page. NaN until book.locations is ready.
  const [currentProgress, setCurrentProgress] = useState<number>(Number.NaN)
  const currentCfiRef = useRef<string | null>(book.currentCfi)
  const cfiSaveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Highlight state
  const [highlights, setHighlights] = useState<Highlight[]>([])
  const [selectedHighlight, setSelectedHighlight] = useState<Highlight | null>(null)
  const [popoverVisible, setPopoverVisible] = useState(false)
  const [popoverPosition, setPopoverPosition] = useState({ x: 0, y: 0 })

  // Bookmark state
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([])
  const [isCurrentBookmarked, setIsCurrentBookmarked] = useState<boolean>(false)

  // Wire the player machine + chat bridge once per book. The machine
  // listens for PLAY/PAUSE/PLAY_FROM events on `usePlayerStore.send`.
  usePlayerMachine(book.id)
  // Realtime voice chat
  const { status: realtimeStatus, showGuardrailWarning, toggle: toggleRealtime, isActive: realtimeActive } = useRealtimeChat(book.id)
  useTtsChatBridge(realtimeStatus)

  // G20 — register the reader's content area with the page-capture
  // registry so the voice-chat vision tool can screenshot the page.
  // The ref is attached to the top-level reader View (which wraps the
  // embedded Reader / epubjs WebView).
  const pageCaptureRef = useRef<View>(null)
  usePageCaptureRef(pageCaptureRef)

  // G10 — undo snackbar surface (5s window after a destructive action).
  const undoSnackbar = useUndoSnackbar()

  // Player observability — drive UI from store, not from the old hook.
  const playingState = usePlayerStore((s) => s.playingState)
  const activeParagraph = usePlayerStore((s) => s.activeParagraph)
  const ttsActive = playingState !== 'idle'

  // Premium feature gates — show sign-in sheet when signed-out users
  // tap TTS / AI chat / realtime voice.
  const requireTTS = useRequireAuth('tts')
  const requireAIChat = useRequireAuth('ai-chat')
  const requireVoiceChat = useRequireAuth('voice-chat')

  // G15 — visual-cue driver. Heuristic classifies the active paragraph
  // text for LaTeX / "Equation N" / "Figure N" markers and writes a cue
  // into the store; <TTSVisualCue /> renders if prefs allow.
  useEffect(() => {
    const setCue = useVisualCueStore.getState().setVisualCue
    if (!activeParagraph?.text) {
      setCue(null)
      return
    }
    const classification = classifyParagraphForVisualCue(activeParagraph.text)
    if (classification) {
      setCue({
        kind: classification.kind,
        label: classification.label,
        target: activeParagraph.index,
      })
    } else {
      setCue(null)
    }
  }, [activeParagraph])

  const theme = READER_THEMES[settings.themeName]

  // `defaultTheme` is read as a useEffect dep inside @epubjs-react-native/core's
  // <Reader>. Passing a fresh object literal each render re-fires that effect,
  // which calls setIsLoading/setTemplate → re-render → infinite loop.
  const readerDefaultTheme = useMemo(
    () => ({ body: { background: theme.background, color: theme.color } }),
    [theme.background, theme.color],
  )

  // Load highlights on mount
  useEffect(() => {
    if (book.id) {
      setHighlights(getHighlightsByBookId(book.id))
      setBookmarks(getBookmarksForBook(book.id))
    }
  }, [book.id])

  // Reflect bookmark presence at the current CFI in the toolbar icon.
  useEffect(() => {
    if (!book.id) return
    const cfi = currentCfiRef.current
    setIsCurrentBookmarked(cfi ? isLocationBookmarked(book.id, cfi) : false)
    // Recompute when bookmarks list changes
  }, [book.id, bookmarks, currentHref])

  // Convert highlights to initialAnnotations for Reader
  const initialAnnotations = useMemo(
    () =>
      highlights.map((h) => ({
        type: 'highlight' as const,
        cfiRange: h.cfiRange,
        data: { id: h.id },
        sectionIndex: 0,
        cfiRangeText: h.text,
        styles: {
          color: HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24',
          opacity: HIGHLIGHT_OPACITY,
        },
      })),
    [highlights]
  )

  // Save CFI on app background
  useEffect(() => {
    const handleAppStateChange = (nextState: AppStateStatus) => {
      if (nextState === 'background' || nextState === 'inactive') {
        if (book.id && currentCfiRef.current) {
          updateBookCfi(book.id, currentCfiRef.current)
        }
      }
    }
    const sub = AppState.addEventListener('change', handleAppStateChange)
    return () => sub.remove()
  }, [book.id])

  // Debounced CFI save on location change.
  //
  // P1-J — the 3rd param (`progress`) is epubjs's 0..1 page-position
  // float. We mirror it into `currentProgress` so the bottom-bar pill
  // can show "42 / 100" instead of the chapter label / raw href.
  const handleLocationChange = useCallback(
    (_totalLocations: number, currentLocation: any, progress: number) => {
      // Always update progress, even when the location payload is
      // empty — epubjs sometimes fires onRelocated with just the
      // progress float during book.locations generation.
      setCurrentProgress(progress)
      // RDR-026 — the first onRelocated emit means epubjs has parsed
      // the spine and rendered the first page. Drop the engine-loading
      // overlay.
      setEngineReady(true)

      if (currentLocation?.start?.cfi) {
        currentCfiRef.current = currentLocation.start.cfi
        setCurrentHref(currentLocation.start.href || null)

        if (cfiSaveTimeoutRef.current) {
          clearTimeout(cfiSaveTimeoutRef.current)
        }
        cfiSaveTimeoutRef.current = setTimeout(() => {
          if (book.id && currentCfiRef.current) {
            updateBookCfi(book.id, currentCfiRef.current)
          }
        }, 500)
      }
    },
    [book.id]
  )

  // Combined settings handler — branches on which field actually changed.
  const handleSettingsChange = useCallback(
    (next: ReaderSettings) => {
      saveReaderSettings(next)
      if (next.themeName !== settings.themeName) {
        const newTheme = READER_THEMES[next.themeName]
        changeTheme({ body: { background: newTheme.background, color: newTheme.color } })
      }
      if (next.fontSize !== settings.fontSize) {
        changeFontSize(`${next.fontSize}%`)
      }
      if (next.fontFamily !== settings.fontFamily) {
        changeFontFamily(next.fontFamily)
      }
      setSettings(next)
    },
    [settings, changeTheme, changeFontSize, changeFontFamily],
  )

  // TOC chapter selection
  const handleSelectChapter = useCallback(
    (href: string) => {
      goToLocation(href)
    },
    [goToLocation]
  )

  // Back navigation -- save position before leaving.
  // safeBack guards against deep-link cold-start where the nav stack is
  // empty (P1-B): we replace to /(tabs) instead of no-op'ing.
  const handleBack = useCallback(() => {
    if (book.id && currentCfiRef.current) {
      updateBookCfi(book.id, currentCfiRef.current)
    }
    safeBack(router)
  }, [book.id, router])

  // --- Highlight handlers ---

  // Text selection creates a highlight
  const handleSelected = useCallback(
    (selectedText: string, cfiRange: string) => {
      const h = insertHighlight({
        bookId: book.id,
        cfiRange,
        text: selectedText,
        color: 'yellow',
        note: null,
        chapter: currentHref || null,
      })
      const hex = HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24'
      addAnnotation('highlight', cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
      setHighlights((prev) => [h, ...prev])
      AccessibilityInfo.announceForAccessibility('Highlight created')
    },
    [book.id, currentHref, addAnnotation]
  )

  // G17 — "Read from here" handler. Seeds the player from the book's
  // chunks if not yet seeded, finds the paragraph the selection lives
  // in, and dispatches PLAY_FROM with the partial-first payload.
  //
  // Gated through `requireTTS` so signed-out users see the sign-in sheet
  // before the player machine receives PLAY_FROM (parity with the toolbar
  // TTS button — Phase 5 P0-A).
  const handleReadFromSelection = useCallback(
    (cfiRange: string, selectionText: string): boolean => {
      requireTTS(async () => {
        const send = usePlayerStore.getState().send
        if (!send) return

        let paragraphs = usePlayerStore.getState().currentParagraphs
        if (paragraphs.length === 0) {
          try {
            const seeded = await seedPlayerParagraphsFromChunks(
              book.id,
              book.filePath,
              book.format,
            )
            if (!seeded.seeded) {
              AccessibilityInfo.announceForAccessibility('No text available for reading')
              return
            }
            paragraphs = seeded.paragraphs
          } catch (err) {
            console.warn('[epub-read-aloud-from] seed failed:', err)
            return
          }
        }

        const playFrom = resolveEpubReadFromSelection(
          selectionText,
          cfiRange,
          paragraphs,
        )
        if (!playFrom) {
          AccessibilityInfo.announceForAccessibility('Could not find the selected text')
          return
        }

        send({
          type: 'PLAY_FROM',
          paragraphIndex: playFrom.paragraphIndex,
          partialFirstText: playFrom.partialFirstText,
          partialFirstKey: playFrom.partialFirstKey,
        })
      })
      return true
    },
    [book.id, book.filePath, book.format, requireTTS],
  )

  // Menu items for text selection context menu
  const menuItems = useMemo(
    () => [
      {
        label: 'Highlight Text',
        action: (cfiRange: string, text: string) => {
          handleSelected(text, cfiRange)
          return true // dismiss selection
        },
      },
      {
        label: 'Highlight & Note',
        action: (cfiRange: string, text: string) => {
          const h = insertHighlight({
            bookId: book.id,
            cfiRange,
            text,
            color: 'yellow',
            note: null,
            chapter: currentHref || null,
          })
          const hex = HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24'
          addAnnotation('highlight', cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
          setHighlights((prev) => [h, ...prev])
          setSelectedHighlight(h)
          AccessibilityInfo.announceForAccessibility('Highlight created')
          // Open note editor after a brief delay to let state settle
          setTimeout(() => setNoteEditorOpen(true), 100)
          return true
        },
      },
      {
        label: 'Read from here',
        action: (cfiRange: string, text: string) => {
          // Fire-and-forget — dismiss the selection menu immediately.
          void handleReadFromSelection(cfiRange, text)
          return true
        },
      },
    ],
    [book.id, currentHref, addAnnotation, handleSelected, handleReadFromSelection]
  )

  // Tapping an existing annotation shows the popover
  const handlePressAnnotation = useCallback(
    (annotation: Annotation) => {
      const match = highlights.find(
        (h) => h.cfiRange === annotation.cfiRange || (annotation.data as any)?.id === h.id
      )
      if (match) {
        setSelectedHighlight(match)
        // Position popover roughly in center-top area of screen since we don't get pixel coords
        const screenWidth = require('react-native').Dimensions.get('window').width
        const screenHeight = require('react-native').Dimensions.get('window').height
        setPopoverPosition({ x: screenWidth / 2, y: screenHeight * 0.35 })
        setPopoverVisible(true)
      }
    },
    [highlights]
  )

  // Annotation popover: edit note
  const handleEditNote = useCallback((highlight: Highlight) => {
    setPopoverVisible(false)
    setSelectedHighlight(highlight)
    setNoteEditorOpen(true)
  }, [])

  // Annotation popover: change color
  const handleChangeColor = useCallback(
    (highlightId: string, color: HighlightColor) => {
      updateHighlight(highlightId, { color })
      const updated = getHighlightsByBookId(book.id)
      setHighlights(updated)
      setPopoverVisible(false)
      // Re-render annotation with new color
      const h = highlights.find((h) => h.id === highlightId)
      if (h) {
        removeAnnotationByCfi(h.cfiRange)
        const hex = HIGHLIGHT_COLORS.find((c) => c.name === color)?.hex ?? '#FBBF24'
        addAnnotation('highlight', h.cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
      }
    },
    [book.id, highlights, addAnnotation, removeAnnotationByCfi]
  )

  // Delete highlight (with undo). The shared `restoreHighlight` flips
  // `isDeleted` back to false — the row was soft-deleted, so the undo is
  // a single DB write that re-paints the annotation.
  const handleDeleteHighlight = useCallback(
    (highlightId: string) => {
      const h = highlights.find((h) => h.id === highlightId)
      deleteHighlight(highlightId)
      if (h) removeAnnotationByCfi(h.cfiRange)
      setHighlights(getHighlightsByBookId(book.id))
      setPopoverVisible(false)

      // Surface the undo snackbar — repaints the annotation if the user taps it.
      if (h) {
        undoSnackbar.show('Highlight deleted', 'Undo', () => {
          restoreHighlight(highlightId)
          setHighlights(getHighlightsByBookId(book.id))
          const hex = HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24'
          addAnnotation(
            'highlight',
            h.cfiRange,
            { id: h.id },
            { color: hex, opacity: HIGHLIGHT_OPACITY },
          )
          AccessibilityInfo.announceForAccessibility('Highlight restored')
        })
      }
    },
    [book.id, highlights, removeAnnotationByCfi, undoSnackbar, addAnnotation]
  )

  // Save note
  const handleSaveNote = useCallback(
    (highlightId: string, note: string) => {
      updateHighlight(highlightId, { note: note || null })
      setHighlights(getHighlightsByBookId(book.id))
      setNoteEditorOpen(false)
    },
    [book.id]
  )

  // Navigate to highlight from list
  const handleNavigateToHighlight = useCallback(
    (cfiRange: string) => {
      goToLocation(cfiRange)
    },
    [goToLocation]
  )

  // Search handlers
  const handleSearch = useCallback(
    (query: string) => {
      setSearchQuery(query)
      if (query.trim().length > 1) {
        search(query.trim())
      } else {
        clearSearchResults()
      }
    },
    [search, clearSearchResults]
  )

  const handleSearchResultPress = useCallback(
    (cfi: string) => {
      goToLocation(cfi)
    },
    [goToLocation]
  )

  // --- TTS handlers ---

  // Toolbar TTS button. If playback is active → STOP; otherwise gate
  // on auth, then seed paragraphs from the book's chunks and dispatch PLAY.
  const handleToggleTTS = useCallback(() => {
    const sendFn = usePlayerStore.getState().send
    if (!sendFn) return
    if (ttsActive) {
      sendFn({ type: 'STOP' })
      return
    }
    requireTTS(async () => {
      try {
        const seeded = await seedPlayerParagraphsFromChunks(book.id, book.filePath, book.format)
        if (!seeded.seeded) {
          AccessibilityInfo.announceForAccessibility('No text available for reading')
          return
        }
        sendFn({ type: 'PLAY' })
      } catch (err) {
        console.warn('[reader-tts] seed failed:', err)
      }
    })
  }, [book.id, book.filePath, book.format, ttsActive, requireTTS])

  // --- Bookmark handlers ---

  const handleToggleBookmark = useCallback(() => {
    const cfi = currentCfiRef.current
    if (!cfi || !book.id) return
    const label = currentHref ?? cfi
    const result = toggleBookmark({ bookId: book.id, location: cfi, label })
    setBookmarks(getBookmarksForBook(book.id))
    setIsCurrentBookmarked(result.action === 'created')
    // RDR-027 — differentiate the add vs remove confirmation haptic. The
    // existing announceForAccessibility line stays for VoiceOver users.
    if (result.action === 'created') {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
    } else {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)
    }
    AccessibilityInfo.announceForAccessibility(
      result.action === 'created' ? 'Bookmark added' : 'Bookmark removed',
    )
  }, [book.id, currentHref])

  const handleDeleteBookmark = useCallback(
    (bookmarkId: string) => {
      if (!book.id) return
      deleteBookmarkFromDb(bookmarkId)
      const next = getBookmarksForBook(book.id)
      setBookmarks(next)
      const cfi = currentCfiRef.current
      setIsCurrentBookmarked(cfi ? isLocationBookmarked(book.id, cfi) : false)
    },
    [book.id]
  )

  const handleNavigateToBookmark = useCallback(
    (location: string) => {
      goToLocation(location)
    },
    [goToLocation]
  )

  // P1-J — drive the bottom-bar pill from epubjs's `progress` float so
  // users see "42 / 100" instead of the chapter title / raw href. The
  // chapter label is still computed below for the voice-chat activation
  // context (2cd13358); don't blow that wiring away.
  const progressForShell = useMemo<ReaderProgress>(
    () => computeEpubProgressForShell(currentProgress),
    [currentProgress],
  )

  const chapterLabel =
    toc?.find((t) => t.href === currentHref)?.label ?? undefined

  // Voice-chat activation context (P0-O). We pass the chapter label as
  // the page-text proxy (EPUB doesn't cheaply expose the rendered DOM
  // text), and the spine outline so the model can resolve "the
  // previous chapter", etc.
  const getActivationContext = useCallback(() => {
    const outline = toc?.map((t) => ({
      href: t.href,
      label: t.label,
    }))
    return {
      pageText: chapterLabel ?? '',
      outline,
    }
  }, [toc, chapterLabel])

  return (
    <View ref={pageCaptureRef} testID="reader-epub" style={{ flex: 1, backgroundColor: theme.background }}>
      <ReaderShell
        title={book.title}
        format="epub"
        onBack={handleBack}
        progress={progressForShell}
        chapterLabel={chapterLabel}
        ttsActive={ttsActive}
        realtimeActive={realtimeActive}
        bookId={book.id}
        onChatToggle={() =>
          requireAIChat(() => router.push(`/chat/${book.id}`))
        }
        getActivationContext={getActivationContext}
        onBookmarkTogglePress={handleToggleBookmark}
        isBookmarked={isCurrentBookmarked}
        onTTSPress={handleToggleTTS}
        ttsButtonActive={ttsActive}
        onRealtimePress={() => {
          if (realtimeActive) toggleRealtime()
          else requireVoiceChat(toggleRealtime)
        }}
        realtimeStatus={realtimeStatus}
        onChatPress={() => requireAIChat(() => router.push(`/chat/${book.id}`))}
        sheets={{
          toc: true,
          highlights: true,
          bookmarks: true,
          search: true,
          appearance: true,
          noteEditor: true,
        }}
        toc={toc ?? []}
        currentHref={currentHref}
        onSelectChapter={handleSelectChapter}
        highlights={highlights}
        onNavigateToHighlight={handleNavigateToHighlight}
        onDeleteHighlight={handleDeleteHighlight}
        bookmarks={bookmarks}
        onNavigateToBookmark={handleNavigateToBookmark}
        onDeleteBookmark={handleDeleteBookmark}
        searchQuery={searchQuery}
        searchResults={searchResults.results}
        isSearching={isSearching}
        onChangeSearchQuery={handleSearch}
        onSelectSearchResult={handleSearchResultPress}
        onSearchSheetClose={() => {
          if (searchQuery.length > 0) {
            setSearchQuery('')
            clearSearchResults()
          }
        }}
        settings={settings}
        onSettingsChange={handleSettingsChange}
        noteEditorHighlight={selectedHighlight}
        noteEditorOpen={noteEditorOpen}
        onSaveNote={handleSaveNote}
        onDiscardNote={() => setNoteEditorOpen(false)}
      >
        {/*
          E2E observability — exposes the current CFI as
          accessibilityLabel. The CFI string mutates on every page turn
          (epubjs assigns it from the spine + character offset), so
          Detox can detect navigation by reading two snapshots and
          comparing.
         */}
        <View
          testID="reader-position-indicator"
          accessible={true}
          accessibilityLabel={currentHref ?? currentCfiRef.current ?? 'unknown'}
          style={{ position: 'absolute', width: 0, height: 0 }}
        />
        <ReaderEngine
          book={book}
          readerDefaultTheme={readerDefaultTheme}
          menuItems={menuItems}
          initialAnnotations={initialAnnotations}
          onLocationChange={handleLocationChange}
          onPressAnnotation={handlePressAnnotation}
          popoverVisible={popoverVisible}
          dismissPopover={() => setPopoverVisible(false)}
        />

        {/*
          RDR-026 — engine-loading overlay covers the blank theme-coloured
          gap between the outer `loading` flip (DB fetch + R2 download
          done) and epubjs's first onRelocated emit (spine parsed,
          first page rendered). `engineReady` flips inside
          `handleLocationChange` above.
        */}
        {!engineReady ? (
          <View
            testID="reader-engine-loading"
            pointerEvents="none"
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              backgroundColor: theme.background,
              justifyContent: 'center',
              alignItems: 'center',
              zIndex: 12,
            }}
          >
            <ActivityIndicator size="large" color={theme.color} />
          </View>
        ) : null}

        <View style={{ position: 'absolute', top: insets.top + 48 + 8, left: 16, right: 16, zIndex: 11 }}>
          <GuardrailWarning visible={showGuardrailWarning} />
        </View>

        {/* G15 — visual cue badge (gated by prefsStore.ttsVisualCueEnabled
            AND a non-null cue in the visual-cue store). The EPUB WebView
            would need a postMessage bridge to drive setVisualCue based on
            DOM scanning; for now the component is mounted so the surface
            is live whenever something else (e.g. a future MOBI/AZW3
            heuristic) sets a cue. */}
        <TTSVisualCue />

        {/* G10 — undo snackbar (5s window after a destructive action) */}
        <UndoSnackbar
          visible={undoSnackbar.visible}
          message={undoSnackbar.message}
          actionLabel={undoSnackbar.actionLabel}
          onAction={undoSnackbar.action}
          onDismiss={undoSnackbar.dismiss}
        />

        {popoverVisible && selectedHighlight && (
          <AnnotationPopover
            visible={popoverVisible}
            highlight={selectedHighlight}
            position={popoverPosition}
            theme={theme}
            onEditNote={handleEditNote}
            onChangeColor={handleChangeColor}
            onDelete={handleDeleteHighlight}
            onDismiss={() => setPopoverVisible(false)}
          />
        )}
      </ReaderShell>
    </View>
  )
}

/**
 * Inner engine component — sits inside ReaderShell so it can consume
 * `ReaderShellContext.toggleToolbar` for the single-tap gesture.
 * Dismissing the annotation popover takes precedence over toggling.
 */
interface ReaderEngineProps {
  book: Book
  readerDefaultTheme: { body: { background: string; color: string } }
  menuItems: { label: string; action: (cfi: string, text: string) => boolean }[]
  initialAnnotations: ReturnType<typeof useMemo<Annotation[]>>
  onLocationChange: (
    totalLocations: number,
    currentLocation: { start?: { cfi?: string; href?: string } } | undefined,
    progress: number,
  ) => void
  onPressAnnotation: (annotation: Annotation) => void
  popoverVisible: boolean
  dismissPopover: () => void
}

function ReaderEngine({
  book,
  readerDefaultTheme,
  menuItems,
  initialAnnotations,
  onLocationChange,
  onPressAnnotation,
  popoverVisible,
  dismissPopover,
}: ReaderEngineProps) {
  const { toggleToolbar } = useContext(ReaderShellContext)
  const handleTap = useCallback(() => {
    if (popoverVisible) {
      dismissPopover()
      return
    }
    toggleToolbar()
  }, [popoverVisible, dismissPopover, toggleToolbar])

  return (
    <Reader
      src={book.filePath}
      fileSystem={useFileSystem}
      flow="paginated"
      enableSwipe={true}
      enableSelection={true}
      initialLocation={book.currentCfi || undefined}
      defaultTheme={readerDefaultTheme}
      menuItems={menuItems}
      initialAnnotations={initialAnnotations}
      onLocationChange={onLocationChange}
      onSingleTap={handleTap}
      onPressAnnotation={onPressAnnotation}
    />
  )
}
