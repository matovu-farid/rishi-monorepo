/**
 * PDF reader screen (Batch 5 — WebView pivot).
 *
 * Renders the PDF inside a pdfjs WebView (PdfWebReader) and layers RN
 * chrome on top: toolbar, outline drawer (G07), go-to-page prompt
 * (G09), text-selection action bar (G08), highlight CRUD (G06), and
 * read-from-selection TTS (G17 — to be wired into the player service in
 * a follow-up; the resolver is in place).
 *
 * Replaces the previous react-native-pdf-based reader. See
 * `.parity/BATCH-5-NOTES.md` for the rationale.
 */
import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActivityIndicator,
  Alert,
  AppState,
  type AppStateStatus,
  FlatList,
  Modal,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import * as Haptics from 'expo-haptics'
import { useLocalSearchParams, useRouter } from 'expo-router'

import { IconSymbol } from '@/components/ui/icon-symbol'
import { PdfWebReader, type PdfWebReaderHandle } from '@/components/pdf/PdfWebReader'
import {
  flattenOutline,
  type PdfOutlineItem,
} from '@/components/pdf/pdf-webview-bridge'
import { usePdfStore, BookNavigationState } from '@/lib/stores/pdfStore'
import { getBookForReading, updateBookPage } from '@/lib/book-storage'
import { Book, ReaderSettings } from '@/types/book'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { safeBack } from '@/lib/navigation'
import {
  insertPdfHighlight,
  getPdfHighlightsByBookId,
  updateHighlight,
  deleteHighlight,
  restoreHighlight,
  type PdfHighlight,
} from '@/lib/highlight-storage'
import { HIGHLIGHT_COLORS, type HighlightColor } from '@/types/highlight'
import type { PdfLocator } from '@rishi/shared/types/pdf-locator'
import { decodePdfCfiRange } from '@rishi/shared/types/pdf-locator'
import {
  getBookmarksForBook,
  toggleBookmark,
  deleteBookmark as deleteBookmarkFromDb,
  isLocationBookmarked,
  type Bookmark,
} from '@/lib/bookmarks/bookmark-storage'
import { resolvePlayFromSelection } from '@/lib/pdf/read-aloud-from-selection'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { usePlayerMachine } from '@/hooks/usePlayerMachine'
import { TTSVisualCue } from '@/components/TTSVisualCue'
import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { classifyParagraphForVisualCue } from '@/lib/tts/visual-cue-classify'
import { useTtsChatBridge } from '@/hooks/useTtsChatBridge'
import { usePageCaptureRef } from '@/hooks/usePageCaptureRef'
import { useRealtimeChat } from '@/hooks/useRealtimeChat'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { GoToPageModal } from '@/components/pdf/GoToPageModal'
import { ThumbnailModal } from '@/components/pdf/thumbnail-modal'
import { UndoSnackbar } from '@/components/UndoSnackbar'
import { useUndoSnackbar } from '@/hooks/useUndoSnackbar'
import {
  ReaderShell,
  ReaderShellContext,
  ReaderErrorScreen,
  type ReaderErrorCause,
  type ReaderProgress,
  type TocItem,
} from '@/components/reader'

interface ActiveSelection {
  pageNumber: number
  text: string
  locator: PdfLocator
  anchor: { x: number; y: number }
}

export default function PdfReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const readerRef = useRef<PdfWebReaderHandle>(null)
  const [book, setBook] = useState<Book | null>(null)
  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)
  // P0-L — track failed-load cause for ReaderErrorScreen.
  const [errorCause, setErrorCause] = useState<ReaderErrorCause | null>(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [outlineVisible, setOutlineVisible] = useState(false)
  const [gotoVisible, setGotoVisible] = useState(false)
  const [thumbnailsVisible, setThumbnailsVisible] = useState(false)
  const [selection, setSelection] = useState<ActiveSelection | null>(null)
  const [pickerHighlight, setPickerHighlight] = useState<PdfHighlight | null>(null)
  const [pickerAnchor, setPickerAnchor] = useState<{ x: number; y: number } | null>(null)
  const [highlights, setHighlights] = useState<PdfHighlight[]>([])
  const [noteEditorOpen, setNoteEditorOpen] = useState(false)
  const [noteTargetHighlight, setNoteTargetHighlight] = useState<PdfHighlight | null>(null)
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([])
  const [isCurrentBookmarked, setIsCurrentBookmarked] = useState<boolean>(false)
  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())

  // Mount the player machine actor for this book. Subsequent reads of
  // `usePlayerStore` (via `MiniPlayer`) get the live machine state.
  usePlayerMachine(book?.id ?? '')

  // Bridge realtime voice-chat status to the player so chat-position is
  // preserved (CHAT_STARTED/CHAT_ENDED dispatched into the playerMachine).
  const { status: realtimeStatus } = useRealtimeChat(book?.id ?? '')
  useTtsChatBridge(realtimeStatus)

  // G20 — register the PDF WebView area as the page-capture target.
  const pageCaptureRef = useRef<View>(null)
  usePageCaptureRef(pageCaptureRef)

  // G10 — undo snackbar surface (5s window after a destructive action).
  const undoSnackbar = useUndoSnackbar()

  // Premium feature gate — initial TTS start path must show the sign-in
  // sheet for signed-out users.
  const requireTTS = useRequireAuth('tts')
  const requireAIChat = useRequireAuth('ai-chat')

  // Subscribe to active-paragraph changes to drive the highlight reconciler.
  const activeParagraph = usePlayerStore((s) => s.activeParagraph)

  // R3 — gate ReaderShell's auto-hide timer on TTS / realtime activity so the
  // bottom bar stays visible while audio is playing or voice chat is live.
  const playingState = usePlayerStore((s) => s.playingState)
  const ttsActive = playingState !== 'idle'

  // G15 — drive the visual-cue store from the active paragraph's text.
  // The classifier is a cheap text-based heuristic (LaTeX delimiters,
  // "Equation 1.2"-style labels) — full DOM scanning would require
  // injecting code into the PDF WebView, which is overkill for the
  // first-pass cue.
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

  const pageNumber = usePdfStore((s) => s.pageNumber)
  const pageCount = usePdfStore((s) => s.pageCount)
  const outline = usePdfStore((s) => s.outline)
  const setPageNumberStore = usePdfStore((s) => s.setPageNumber)
  const setScrollPageNumber = usePdfStore((s) => s.setScrollPageNumber)
  const setPageCount = usePdfStore((s) => s.setPageCount)
  const setOutlineStore = usePdfStore((s) => s.setOutline)
  const setBookNavigationState = usePdfStore((s) => s.setBookNavigationState)
  const resetParagraphState = usePdfStore((s) => s.resetParagraphState)

  // Reset store when the screen unmounts (otherwise opening another book
  // would inherit the previous book's state).
  useEffect(() => () => resetParagraphState(), [resetParagraphState])

  // ---- Load book ----
  useEffect(() => {
    if (!id) return
    setLoading(true)
    setDownloading(false)
    setErrorCause(null)
    getBookForReading(id, { onDownloadStart: () => setDownloading(true) })
      .then(async (loaded) => {
        if (!loaded) return
        setBook(loaded)
        setHighlights(getPdfHighlightsByBookId(loaded.id))
        setBookmarks(getBookmarksForBook(loaded.id))
      })
      .catch((err) => {
        console.error('[PdfReaderScreen] load failed:', err)
        setBook(null)
        // The loader only throws from the R2 download path — surface
        // this as a cloud-download failure so Retry is meaningful.
        setErrorCause('cloud-download-failed')
      })
      .finally(() => setLoading(false))
  }, [id, loadAttempt])

  // ---- Save position on background ----
  useEffect(() => {
    const handler = (next: AppStateStatus) => {
      if ((next === 'background' || next === 'inactive') && book?.id && pageNumber > 0) {
        updateBookPage(book.id, pageNumber)
      }
    }
    const sub = AppState.addEventListener('change', handler)
    return () => sub.remove()
  }, [book?.id, pageNumber])

  // ---- WebView events ----
  const handleLoad = useCallback(
    (info: { numPages: number; outline: PdfOutlineItem[] }) => {
      setPageCount(info.numPages)
      setOutlineStore(info.outline)
      // Apply any previously-saved highlights as overlays.
      if (highlights.length > 0) {
        readerRef.current?.setHighlights(
          highlights.map((h) => ({ id: h.id, color: h.color, locator: h.locator }))
        )
      }
      // Restore reading position.
      const initial = book?.currentPage ?? 1
      if (initial > 1) readerRef.current?.goToPage(initial)
      setBookNavigationState(BookNavigationState.Idle)
    },
    [book?.currentPage, highlights, setPageCount, setOutlineStore, setBookNavigationState]
  )

  const handlePageChange = useCallback(
    (page: number) => {
      setScrollPageNumber(page)
      // Persist with a soft debounce — we save on background change too, so
      // this just makes scrolling-then-killing-the-app safe.
      if (book?.id) updateBookPage(book.id, page)
    },
    [book?.id, setScrollPageNumber]
  )

  const handleSelection = useCallback(
    (sel: ActiveSelection) => {
      setSelection(sel)
    },
    []
  )

  const handleSelectionCleared = useCallback(() => {
    setSelection(null)
  }, [])

  const handleHighlightTapped = useCallback(
    (highlightId: string, anchor: { x: number; y: number }) => {
      const h = highlights.find((x) => x.id === highlightId)
      if (!h) return
      setPickerHighlight(h)
      setPickerAnchor(anchor)
    },
    [highlights]
  )

  // ---- Actions ----
  const handleGoToPage = useCallback(() => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        'Go to Page',
        `Enter a page number (1-${pageCount})`,
        (text) => {
          const page = Number.parseInt(text ?? '', 10)
          if (Number.isFinite(page) && page >= 1 && page <= pageCount) {
            setPageNumberStore(page)
            readerRef.current?.goToPage(page)
          }
        },
        'plain-text',
        String(pageNumber || 1)
      )
    } else {
      // Android — open the custom modal (G09).
      setGotoVisible(true)
    }
  }, [pageCount, pageNumber, setPageNumberStore])

  const handleGotoFromModal = useCallback(
    (page: number) => {
      setPageNumberStore(page)
      readerRef.current?.goToPage(page)
    },
    [setPageNumberStore],
  )

  const handleSelectThumbnailPage = useCallback(
    (page: number) => {
      setPageNumberStore(page)
      readerRef.current?.goToPage(page)
    },
    [setPageNumberStore],
  )

  const handleOpenOutline = useCallback(() => setOutlineVisible(true), [])
  const handleCloseOutline = useCallback(() => setOutlineVisible(false), [])

  const handleOutlineTap = useCallback(
    (page: number | null) => {
      if (page == null) return
      setOutlineVisible(false)
      setPageNumberStore(page)
      readerRef.current?.goToPage(page)
    },
    [setPageNumberStore]
  )

  const handleAddHighlight = useCallback(
    (color: HighlightColor) => {
      if (!selection || !book) return
      const inserted = insertPdfHighlight({
        bookId: book.id,
        locator: selection.locator,
        text: selection.text,
        color,
      })
      setHighlights((prev) => [inserted, ...prev])
      readerRef.current?.highlightSelection(inserted.id, color)
      setSelection(null)
    },
    [book, selection]
  )

  const handleChangeHighlightColor = useCallback(
    (color: HighlightColor) => {
      if (!pickerHighlight) return
      updateHighlight(pickerHighlight.id, { color })
      setHighlights((prev) =>
        prev.map((h) => (h.id === pickerHighlight.id ? { ...h, color } : h))
      )
      readerRef.current?.addHighlight(pickerHighlight.id, color, pickerHighlight.locator)
      setPickerHighlight(null)
      setPickerAnchor(null)
    },
    [pickerHighlight]
  )

  const handleDeleteHighlight = useCallback(() => {
    if (!pickerHighlight) return
    const deleted = pickerHighlight
    deleteHighlight(deleted.id)
    setHighlights((prev) => prev.filter((h) => h.id !== deleted.id))
    readerRef.current?.removeHighlight(deleted.id)
    setPickerHighlight(null)
    setPickerAnchor(null)

    // G10 — surface undo snackbar. restoreHighlight flips isDeleted
    // back; the WebView then re-paints the overlay via addHighlight.
    undoSnackbar.show('Highlight deleted', 'Undo', () => {
      restoreHighlight(deleted.id)
      setHighlights((prev) => [deleted, ...prev])
      readerRef.current?.addHighlight(deleted.id, deleted.color, deleted.locator)
    })
  }, [pickerHighlight, undoSnackbar])

  // Open the NoteEditor for the picker-selected highlight. Reuses the
  // existing EPUB editor — Batch 7 widened its prop type to accept any
  // shape with { id, text, note } (see components/NoteEditor.tsx).
  const handleOpenNoteEditor = useCallback(() => {
    if (!pickerHighlight) return
    setNoteTargetHighlight(pickerHighlight)
    setPickerHighlight(null)
    setPickerAnchor(null)
    // small delay so the picker closes cleanly before the sheet opens
    setTimeout(() => setNoteEditorOpen(true), 100)
  }, [pickerHighlight])

  const handleSaveNote = useCallback(
    (highlightId: string, note: string) => {
      updateHighlight(highlightId, { note: note || null })
      setHighlights((prev) =>
        prev.map((h) => (h.id === highlightId ? { ...h, note: note || null } : h)),
      )
      setNoteTargetHighlight(null)
    },
    [],
  )

  // Read-from-selection (G17). Batch 7 wires this fully to the player
  // machine via playerStore.send PLAY_FROM:
  //   1. Fetch the selected page paragraphs from the WebView.
  //   2. Seed playerStore.currentParagraphs so the machine has the
  //      list to step through.
  //   3. Compute the PLAY_FROM payload via the shared resolver.
  //   4. Dispatch into playerStore.send. The mounted usePlayerMachine
  //      actor receives the event and fetches audio via the new TTS
  //      service.
  const handleReadFromSelection = useCallback(() => {
    if (!selection) return
    requireTTS(async () => {
      try {
        const paragraphs = await readerRef.current?.getPageText(selection.pageNumber)
        if (!paragraphs) return
        const playFrom = resolvePlayFromSelection(selection.text, paragraphs)
        if (!playFrom) {
          Alert.alert('Read aloud', 'Could not find the selected text on this page.')
          return
        }

        // Seed the page's paragraphs as the player's current list. The shape
        // { index, text } matches ParagraphWithIndex (Batch 5 already emits
        // this shape from getPageText).
        usePlayerStore.setState({ currentParagraphs: paragraphs })

        const send = usePlayerStore.getState().send
        if (!send) {
          console.warn('[pdf-read-aloud-from] player machine not mounted yet')
          return
        }
        send({
          type: 'PLAY_FROM',
          paragraphIndex: playFrom.paragraphIndex,
          partialFirstText: playFrom.partialFirstText,
          partialFirstKey: playFrom.partialFirstKey,
        })
        setSelection(null)
      } catch (e) {
        console.warn('[pdf-read-aloud-from] failed', e)
      }
    })
  }, [selection, requireTTS])

  // Reconciler: when the active paragraph changes, scroll the WebView to
  // its page. Mobile PDF doesn't yet have a per-paragraph overlay highlight
  // bridge command; the page-level follow is enough to keep the user
  // visually anchored.
  useEffect(() => {
    if (!activeParagraph) return
    // Active paragraph ids from getPageText follow the pattern
    // pdf-{page}-{paragraphIndex} (see PdfWebReader webview-template).
    const match = /^pdf-(\d+)-/.exec(activeParagraph.index)
    if (!match) return
    const page = Number.parseInt(match[1], 10)
    if (Number.isFinite(page) && page > 0 && page !== pageNumber) {
      readerRef.current?.goToPage(page)
    }
  }, [activeParagraph, pageNumber])

  // ---- Bookmarks ----
  // Reflect bookmark presence at the current page (encoded as a pdf:
  // cfiRange) in the toolbar icon.
  useEffect(() => {
    if (!book?.id) return
    const cfi = `pdf:${JSON.stringify({ page: pageNumber || 1, rects: [] })}`
    setIsCurrentBookmarked(isLocationBookmarked(book.id, cfi))
  }, [book?.id, bookmarks, pageNumber])

  const handleToggleBookmark = useCallback(() => {
    if (!book?.id || !pageNumber) return
    const cfi = `pdf:${JSON.stringify({ page: pageNumber, rects: [] })}`
    const label = `Page ${pageNumber}`
    const result = toggleBookmark({ bookId: book.id, location: cfi, label })
    setBookmarks(getBookmarksForBook(book.id))
    setIsCurrentBookmarked(result.action === 'created')
    // RDR-027 — differentiated confirmation haptic (success on create,
    // warning on remove). Matches the EPUB reader's bookmark toggle.
    if (result.action === 'created') {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
    } else {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)
    }
  }, [book?.id, pageNumber])

  const handleDeleteBookmark = useCallback(
    (bookmarkId: string) => {
      if (!book?.id) return
      deleteBookmarkFromDb(bookmarkId)
      setBookmarks(getBookmarksForBook(book.id))
    },
    [book?.id],
  )

  const handleNavigateToBookmark = useCallback(
    (location: string) => {
      const loc = decodePdfCfiRange(location)
      const page = loc?.page ?? Number.parseInt(location, 10)
      if (Number.isFinite(page) && page >= 1) {
        setPageNumberStore(page)
        readerRef.current?.goToPage(page)
      }
    },
    [setPageNumberStore],
  )

  // ---- Highlights navigation ----
  const handleNavigateToHighlight = useCallback(
    (cfiRange: string) => {
      const loc = decodePdfCfiRange(cfiRange)
      if (loc?.page) {
        setPageNumberStore(loc.page)
        readerRef.current?.goToPage(loc.page)
      }
    },
    [setPageNumberStore],
  )

  const handleDeleteHighlightById = useCallback(
    (id: string) => {
      const target = highlights.find((h) => h.id === id)
      if (!target) return
      deleteHighlight(id)
      setHighlights((prev) => prev.filter((h) => h.id !== id))
      readerRef.current?.removeHighlight(id)
      undoSnackbar.show('Highlight deleted', 'Undo', () => {
        restoreHighlight(id)
        setHighlights((prev) => [target, ...prev])
        readerRef.current?.addHighlight(target.id, target.color, target.locator)
      })
    },
    [highlights, undoSnackbar],
  )

  // ---- TOC adapter (PDF outline -> TocItem) ----
  const tocItems = useMemo<TocItem[]>(() => {
    const convert = (items: PdfOutlineItem[]): TocItem[] =>
      items.map((it, idx) => ({
        href:
          it.pageNumber != null
            ? `pdf-page:${it.pageNumber}`
            : `pdf-page:none:${idx}`,
        label: it.title,
        subitems: it.children?.length ? convert(it.children) : undefined,
      }))
    return convert(outline)
  }, [outline])

  const currentTocHref = useMemo(
    () => (pageNumber > 0 ? `pdf-page:${pageNumber}` : null),
    [pageNumber],
  )

  const handleSelectChapter = useCallback(
    (href: string) => {
      const m = /^pdf-page:(\d+)$/.exec(href)
      if (!m) return
      const page = Number.parseInt(m[1], 10)
      if (Number.isFinite(page) && page >= 1) {
        setPageNumberStore(page)
        readerRef.current?.goToPage(page)
      }
    },
    [setPageNumberStore],
  )

  // ---- Appearance ----
  const handleSettingsChange = useCallback((next: ReaderSettings) => {
    saveReaderSettings(next)
    setSettings(next)
  }, [])

  // safeBack: deep-link cold-start has an empty stack, so a bare
  // router.back() no-ops and strands the user (P1-B).
  const handleBack = useCallback(() => {
    if (book?.id && pageNumber > 0) updateBookPage(book.id, pageNumber)
    safeBack(router)
  }, [book?.id, pageNumber, router])

  // ---- Render ----
  if (loading) {
    return (
      <View testID="reader-loading" style={styles.full}>
        <ActivityIndicator size="large" color="#fff" />
        <Text style={{ marginTop: 12, color: '#fff' }}>
          {downloading ? 'Downloading…' : 'Loading book…'}
        </Text>
      </View>
    )
  }
  if (!book || !book.filePath) {
    // P0-L — resolve cause: cloud failure was set in the catch branch;
    // otherwise the local file is gone.
    const resolvedCause: ReaderErrorCause = errorCause ?? 'local-missing'
    return (
      <ReaderErrorScreen
        cause={resolvedCause}
        onBack={() => safeBack(router)}
        onRetry={() => setLoadAttempt((n) => n + 1)}
      />
    )
  }

  const progressForShell: ReaderProgress =
    pageCount > 0
      ? { kind: 'page', current: pageNumber || 1, total: pageCount }
      : { kind: 'none' }

  const pdfNavCluster = (
    <PdfNavCluster
      pageNumber={pageNumber}
      pageCount={pageCount}
      onPrev={() => {
        if (pageNumber > 1) readerRef.current?.goToPage(pageNumber - 1)
      }}
      onNext={() => {
        if (pageNumber < pageCount) readerRef.current?.goToPage(pageNumber + 1)
      }}
      onPageIndicatorPress={handleGoToPage}
    />
  )

  return (
    <View ref={pageCaptureRef} testID="pdf-reader" style={{ flex: 1, backgroundColor: '#000' }}>
      <ReaderShell
        title={book.title}
        format="pdf"
        onBack={handleBack}
        progress={progressForShell}
        initialToolbarVisible={true}
        centerOverride={pdfNavCluster}
        ttsActive={ttsActive}
        realtimeActive={realtimeStatus !== 'idle'}
        bookId={book?.id}
        onChatToggle={() =>
          requireAIChat(() => router.push(`/chat/${book.id}`))
        }
        onBookmarkTogglePress={handleToggleBookmark}
        isBookmarked={isCurrentBookmarked}
        sheets={{
          toc: true,
          highlights: true,
          bookmarks: true,
          search: true,
          appearance: true,
          noteEditor: true,
        }}
        toc={tocItems}
        currentHref={currentTocHref}
        onSelectChapter={handleSelectChapter}
        highlights={highlights}
        onNavigateToHighlight={handleNavigateToHighlight}
        onDeleteHighlight={handleDeleteHighlightById}
        bookmarks={bookmarks}
        onNavigateToBookmark={handleNavigateToBookmark}
        onDeleteBookmark={handleDeleteBookmark}
        searchQuery=""
        searchResults={[]}
        isSearching={false}
        onChangeSearchQuery={() => undefined}
        onSelectSearchResult={() => undefined}
        settings={settings}
        onSettingsChange={handleSettingsChange}
        noteEditorHighlight={noteTargetHighlight}
        noteEditorOpen={noteEditorOpen}
        onSaveNote={handleSaveNote}
        onDiscardNote={() => {
          setNoteTargetHighlight(null)
          setNoteEditorOpen(false)
        }}
      >
        {/*
          E2E observability — invisible indicator that exposes the current
          page as an accessibilityLabel that Detox can read via
          `by.id('reader-position-indicator')`. Permanently mounted so
          tests don't need to tap to reveal the toolbar first.
         */}
        <View
          testID="reader-position-indicator"
          accessible={true}
          accessibilityLabel={`${pageNumber || 1}/${pageCount || 0}`}
          style={{ position: 'absolute', width: 0, height: 0 }}
        />
        {/* P0-C — Pressable goes FIRST so it sits behind the WebView.
            The WebView still receives every gesture; only taps that
            the WebView doesn't consume fall through to reveal the
            toolbar. */}
        <PressableToggleToolbar />

        <PdfWebReader
          ref={readerRef}
          fileUri={book.filePath}
          onLoad={handleLoad}
          onPageChange={handlePageChange}
          onSelection={handleSelection}
          onSelectionCleared={handleSelectionCleared}
          onHighlightTapped={handleHighlightTapped}
          onError={(msg) => console.warn('[pdf-webview] error:', msg)}
        />

        {/*
          RDR-022 — fold the legacy thumbnails + outline cluster into the
          ReaderShell auto-hide flow. We consume `bottomBarVisible` from
          ReaderShellContext and drop both opacity and pointerEvents in
          lockstep with the bottom bar; previously this cluster stayed on
          screen forever, breaking Apple-Books parity.
        */}
        <LegacyPdfTopRightChrome
          pageCount={pageCount}
          outlineCount={outline.length}
          onThumbnailsPress={() => setThumbnailsVisible(true)}
          onOutlinePress={handleOpenOutline}
        />

        {/* Selection action bar */}
      {selection ? (
        <View
          pointerEvents="box-none"
          style={styles.selectionBarWrapper}
        >
          <View style={styles.selectionBar}>
            {HIGHLIGHT_COLORS.map((c) => (
              <TouchableOpacity
                key={c.name}
                onPress={() => handleAddHighlight(c.name)}
                style={[styles.swatch, { backgroundColor: c.hex }]}
                hitSlop={{ top: 11, bottom: 11, left: 11, right: 11 }}
                accessibilityLabel={`Highlight in ${c.name}`}
              />
            ))}
            <TouchableOpacity
              onPress={handleReadFromSelection}
              style={styles.selectionAction}
            >
              <Text style={styles.selectionActionText}>Read</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => {
                readerRef.current?.clearSelection()
                setSelection(null)
              }}
              style={styles.selectionAction}
            >
              <Text style={styles.selectionActionText}>Cancel</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : null}

      {/* Highlight picker (color/delete after tapping an existing highlight) */}
      {pickerHighlight && pickerAnchor ? (
        <View pointerEvents="box-none" style={styles.pickerWrapper}>
          <View style={styles.pickerBar}>
            {HIGHLIGHT_COLORS.map((c) => (
              <TouchableOpacity
                key={c.name}
                onPress={() => handleChangeHighlightColor(c.name)}
                style={[
                  styles.swatch,
                  { backgroundColor: c.hex },
                  pickerHighlight.color === c.name && styles.swatchActive,
                ]}
                hitSlop={{ top: 11, bottom: 11, left: 11, right: 11 }}
                accessibilityLabel={`Recolor highlight to ${c.name}`}
              />
            ))}
            <TouchableOpacity onPress={handleOpenNoteEditor} style={styles.selectionAction}>
              <Text style={styles.selectionActionText}>Note</Text>
            </TouchableOpacity>
            <TouchableOpacity onPress={handleDeleteHighlight} style={styles.selectionAction}>
              <Text style={[styles.selectionActionText, { color: '#F87171' }]}>Delete</Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => {
                setPickerHighlight(null)
                setPickerAnchor(null)
              }}
              style={styles.selectionAction}
            >
              <Text style={styles.selectionActionText}>Close</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : null}

        {/* G15 — visual cue badge. Mounted unconditionally; the component
            gates its own rendering on prefsStore.ttsVisualCueEnabled +
            visualCueStore.label. We drive setVisualCue from the active
            paragraph's text via a lightweight heuristic in
            `lib/tts/visual-cue-classify.ts`. */}
        <TTSVisualCue />

        {/* G10 — undo snackbar after highlight delete */}
        <UndoSnackbar
          visible={undoSnackbar.visible}
          message={undoSnackbar.message}
          actionLabel={undoSnackbar.actionLabel}
          onAction={undoSnackbar.action}
          onDismiss={undoSnackbar.dismiss}
        />

        {/* G09 — Go-to-page modal (Android only — iOS uses Alert.prompt) */}
        <GoToPageModal
          visible={gotoVisible}
          pageCount={pageCount}
          currentPage={pageNumber || 1}
          onClose={() => setGotoVisible(false)}
          onSelectPage={handleGotoFromModal}
        />

        {/* G09 — Thumbnail grid modal */}
        {book?.filePath ? (
          <ThumbnailModal
            visible={thumbnailsVisible}
            onClose={() => setThumbnailsVisible(false)}
            onSelectPage={handleSelectThumbnailPage}
            filePath={book.filePath}
            totalPages={pageCount}
            currentPage={pageNumber || 1}
          />
        ) : null}

        {/* TOC modal (Phase 4 — G07) */}
        <Modal
          visible={outlineVisible}
          animationType="slide"
          onRequestClose={handleCloseOutline}
          presentationStyle="formSheet"
        >
          <SafeAreaView style={{ flex: 1, backgroundColor: '#1c1c1e' }}>
            <View style={styles.outlineHeader}>
              <Text style={{ color: '#fff', fontSize: 17, fontWeight: '600' }}>Contents</Text>
              <TouchableOpacity onPress={handleCloseOutline} hitSlop={10}>
                <IconSymbol name="xmark" size={20} color="#fff" />
              </TouchableOpacity>
            </View>
            <OutlineList outline={outline} currentPage={pageNumber} onTap={handleOutlineTap} />
          </SafeAreaView>
        </Modal>
      </ReaderShell>
    </View>
  )
}

/**
 * Full-area Pressable for tap-to-toggle. Lives inside ReaderShell so it
 * can call `toggleToolbar` from context. testID is preserved for Detox.
 *
 * P0-C — uses `StyleSheet.absoluteFill` so the whole page area routes
 * "missed" taps through to the toggle (was a 48pt top strip). The
 * Pressable is mounted BEFORE the PdfWebReader in JSX so it sits BEHIND
 * the WebView; the WebView still receives all gestures, only taps the
 * WebView doesn't consume fall through.
 */
function PressableToggleToolbar(): React.JSX.Element {
  const { toggleToolbar } = useContext(ReaderShellContext)
  return (
    <Pressable
      testID="reader-toggle-toolbar"
      onPress={toggleToolbar}
      style={StyleSheet.absoluteFill}
      accessibilityLabel="Toggle toolbar"
    />
  )
}

interface LegacyPdfTopRightChromeProps {
  pageCount: number
  outlineCount: number
  onThumbnailsPress: () => void
  onOutlinePress: () => void
}

/**
 * RDR-022 — outline + thumbnails buttons rendered above the PDF page,
 * tied to the same auto-hide flow as the bottom bar. Reads
 * `bottomBarVisible` from ReaderShellContext and drops opacity and
 * pointer events together so the buttons can neither be seen nor tapped
 * while the toolbar is hidden.
 */
function LegacyPdfTopRightChrome({
  pageCount,
  outlineCount,
  onThumbnailsPress,
  onOutlinePress,
}: LegacyPdfTopRightChromeProps): React.JSX.Element {
  const { bottomBarVisible } = useContext(ReaderShellContext)
  return (
    <SafeAreaView
      edges={['top']}
      style={[
        styles.legacyTopRight,
        { opacity: bottomBarVisible ? 1 : 0 },
      ]}
      pointerEvents={bottomBarVisible ? 'box-none' : 'none'}
    >
      <View style={styles.legacyTopRightInner} pointerEvents="box-none">
        <TouchableOpacity
          onPress={onThumbnailsPress}
          style={styles.iconButton}
          accessibilityLabel="Open Thumbnails"
          disabled={pageCount === 0}
        >
          <IconSymbol
            name="square.grid.2x2"
            size={22}
            color={pageCount === 0 ? '#666' : '#fff'}
          />
        </TouchableOpacity>
        <TouchableOpacity
          onPress={onOutlinePress}
          style={styles.iconButton}
          accessibilityLabel="Open Table of Contents"
          disabled={outlineCount === 0}
        >
          <IconSymbol
            name="list.bullet"
            size={22}
            color={outlineCount === 0 ? '#666' : '#fff'}
          />
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  )
}

interface PdfNavClusterProps {
  pageNumber: number
  pageCount: number
  onPrev: () => void
  onNext: () => void
  onPageIndicatorPress: () => void
}

function PdfNavCluster({
  pageNumber,
  pageCount,
  onPrev,
  onNext,
  onPageIndicatorPress,
}: PdfNavClusterProps): React.JSX.Element {
  return (
    <View style={styles.pdfNavCluster}>
      <TouchableOpacity
        onPress={onPrev}
        disabled={pageNumber <= 1}
        style={[styles.pdfNavBtn, pageNumber <= 1 && { opacity: 0.3 }]}
        accessibilityLabel="Previous page"
      >
        <IconSymbol name="chevron.left" size={24} color="#fff" />
      </TouchableOpacity>

      <TouchableOpacity onPress={onPageIndicatorPress} accessibilityLabel="Go to page">
        <Text style={styles.pdfNavLabel}>
          {pageNumber || 1} / {pageCount || '?'}
        </Text>
      </TouchableOpacity>

      <TouchableOpacity
        testID="reader-next-page-btn"
        onPress={onNext}
        disabled={pageNumber >= pageCount}
        style={[styles.pdfNavBtn, pageNumber >= pageCount && { opacity: 0.3 }]}
        accessibilityLabel="Next page"
      >
        <IconSymbol name="chevron.right" size={24} color="#fff" />
      </TouchableOpacity>
    </View>
  )
}

interface OutlineListProps {
  outline: PdfOutlineItem[]
  currentPage: number
  onTap: (page: number | null) => void
}

function OutlineList({ outline, currentPage, onTap }: OutlineListProps) {
  const rows = useMemo(() => flattenOutline(outline), [outline])
  if (rows.length === 0) {
    return (
      <View style={{ padding: 16 }}>
        <Text style={{ color: '#999' }}>This PDF has no table of contents.</Text>
      </View>
    )
  }
  return (
    <FlatList
      data={rows}
      keyExtractor={(_, i) => String(i)}
      renderItem={({ item }) => {
        const isCurrent =
          item.pageNumber !== null && item.pageNumber === currentPage
        return (
          <TouchableOpacity
            onPress={() => onTap(item.pageNumber)}
            disabled={item.pageNumber === null}
            style={[
              styles.outlineRow,
              { paddingLeft: 16 + item.depth * 16 },
              isCurrent && styles.outlineRowCurrent,
            ]}
          >
            <Text
              style={{
                color: item.pageNumber === null ? '#666' : '#fff',
                fontSize: 15,
                fontWeight: isCurrent ? '600' : '400',
              }}
              numberOfLines={1}
            >
              {item.title}
            </Text>
            {item.pageNumber !== null ? (
              <Text style={{ color: '#999', fontSize: 13 }}>{item.pageNumber}</Text>
            ) : null}
          </TouchableOpacity>
        )
      }}
    />
  )
}

const styles = StyleSheet.create({
  full: {
    flex: 1,
    backgroundColor: '#000',
    justifyContent: 'center',
    alignItems: 'center',
  },
  legacyTopRight: {
    position: 'absolute',
    top: 0,
    right: 0,
    zIndex: 11,
  },
  legacyTopRightInner: {
    flexDirection: 'row',
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  iconButton: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
  pdfNavCluster: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
  },
  pdfNavBtn: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
  pdfNavLabel: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '500',
    minWidth: 64,
    textAlign: 'center',
  },
  selectionBarWrapper: {
    position: 'absolute',
    top: 80,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  selectionBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: 'rgba(28,28,30,0.95)',
    borderRadius: 12,
  },
  selectionAction: {
    minHeight: 44,
    minWidth: 44,
    paddingHorizontal: 8,
    justifyContent: 'center',
    alignItems: 'center',
  },
  selectionActionText: { color: '#fff', fontSize: 14, fontWeight: '600' },
  swatch: {
    width: 22,
    height: 22,
    borderRadius: 11,
  },
  swatchActive: {
    borderWidth: 2,
    borderColor: '#fff',
  },
  pickerWrapper: {
    position: 'absolute',
    bottom: 80,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  pickerBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: 'rgba(28,28,30,0.95)',
    borderRadius: 12,
  },
  outlineHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderBottomColor: '#333',
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  outlineRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 14,
    paddingRight: 16,
    borderBottomColor: '#222',
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  outlineRowCurrent: { backgroundColor: 'rgba(10,126,164,0.2)' },
})
