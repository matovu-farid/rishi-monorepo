import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, AppState, AppStateStatus, ActivityIndicator, AccessibilityInfo } from 'react-native'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { Reader, ReaderProvider, useReader } from '@epubjs-react-native/core'
import { useFileSystem } from '@/lib/epub/file-system-adapter'
import { GestureHandlerRootView } from 'react-native-gesture-handler'

import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { getBookForReading, updateBookCfi } from '@/lib/book-storage'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { insertHighlight, getHighlightsByBookId, updateHighlight, deleteHighlight, restoreHighlight } from '@/lib/highlight-storage'
import {
  getBookmarksForBook,
  toggleBookmark,
  deleteBookmark as deleteBookmarkFromDb,
  isLocationBookmarked,
  type Bookmark,
} from '@/lib/bookmarks/bookmark-storage'
import { TTSControls } from '@/components/TTSControls'
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
  type ReaderProgress,
} from '@/components/reader'
import { READER_THEMES } from '@/constants/reader-themes'
import { Book, ReaderSettings } from '@/types/book'
import type { Highlight, HighlightColor } from '@/types/highlight'
import { HIGHLIGHT_COLORS, HIGHLIGHT_OPACITY } from '@/types/highlight'
import type { Annotation } from '@epubjs-react-native/core'

export default function ReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const [book, setBook] = useState<Book | null>(null)

  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)

  // Load book from DB (async -- may download file from R2 for synced books).
  // When the lazy-download branch fires, `onDownloadStart` flips the
  // downloading flag so the loading screen renders "Downloading..." copy
  // instead of the fast-path "Loading book..." copy.
  useEffect(() => {
    if (id) {
      setLoading(true)
      setDownloading(false)
      getBookForReading(id, { onDownloadStart: () => setDownloading(true) })
        .then((loaded) => setBook(loaded))
        .catch((err) => console.error('Failed to load book for reading:', err))
        .finally(() => setLoading(false))
    }
  }, [id])

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
    return (
      <View testID="reader-error" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#666', fontSize: 16 }}>Book file not available</Text>
      </View>
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

  // Debounced CFI save on location change
  const handleLocationChange = useCallback(
    (_totalLocations: number, currentLocation: any, _progress: number) => {
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

  // Back navigation -- save position before leaving
  const handleBack = useCallback(() => {
    if (book.id && currentCfiRef.current) {
      updateBookCfi(book.id, currentCfiRef.current)
    }
    router.back()
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
  const handleReadFromSelection = useCallback(
    async (cfiRange: string, selectionText: string) => {
      const send = usePlayerStore.getState().send
      if (!send) return false

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
            return true
          }
          paragraphs = seeded.paragraphs
        } catch (err) {
          console.warn('[epub-read-aloud-from] seed failed:', err)
          return true
        }
      }

      const playFrom = resolveEpubReadFromSelection(
        selectionText,
        cfiRange,
        paragraphs,
      )
      if (!playFrom) {
        AccessibilityInfo.announceForAccessibility('Could not find the selected text')
        return true
      }

      send({
        type: 'PLAY_FROM',
        paragraphIndex: playFrom.paragraphIndex,
        partialFirstText: playFrom.partialFirstText,
        partialFirstKey: playFrom.partialFirstKey,
      })
      return true
    },
    [book.id, book.filePath, book.format],
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

  // Derive a progress label for ReaderShell's center pill. EPUB doesn't
  // expose page totals from the spine cheaply — use the chapter label
  // when present, otherwise the raw CFI prefix, otherwise no pill.
  const progressForShell = useMemo<ReaderProgress>(() => {
    const chapter = toc?.find((t) => t.href === currentHref)?.label
    if (chapter) return { kind: 'cfi', label: chapter }
    if (currentHref) return { kind: 'cfi', label: currentHref }
    return { kind: 'none' }
  }, [toc, currentHref])

  const chapterLabel =
    toc?.find((t) => t.href === currentHref)?.label ?? undefined

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

        <View style={{ position: 'absolute', top: insets.top + 48 + 8, left: 16, right: 16, zIndex: 11 }}>
          <GuardrailWarning visible={showGuardrailWarning} />
        </View>

        <TTSControls />

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
