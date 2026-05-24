import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import {
  AccessibilityInfo,
  View,
  Text,
  TouchableOpacity,
  Pressable,
  AppState,
  AppStateStatus,
  ActivityIndicator,
  StyleSheet,
} from 'react-native'
import * as Haptics from 'expo-haptics'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { WebView } from 'react-native-webview'
import { File as ExpoFile } from 'expo-file-system'
import { IconSymbol } from '@/components/ui/icon-symbol'
import {
  getBookForReading,
  updateBookPage,
  updateBookProgress,
} from '@/lib/book-storage'
import { Book } from '@/types/book'
import { TTSVisualCue } from '@/components/TTSVisualCue'
import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { classifyParagraphForVisualCue } from '@/lib/tts/visual-cue-classify'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { usePlayerMachine } from '@/hooks/usePlayerMachine'
import { useTtsChatBridge } from '@/hooks/useTtsChatBridge'
import { usePageCaptureRef } from '@/hooks/usePageCaptureRef'
import { useRealtimeChat } from '@/hooks/useRealtimeChat'
import { seedPlayerParagraphsFromChunks } from '@/lib/tts/seed-paragraphs'
import { resolvePlainTextReadFromSelection } from '@/lib/reader-selection'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { buildReaderThemeInjection } from '@/lib/reader-theme-css'
import { READER_THEMES } from '@/constants/reader-themes'
import { safeBack } from '@/lib/navigation'
import type { ReaderSettings } from '@/types/book'
import {
  getHighlightsByBookId,
  deleteHighlight,
  restoreHighlight,
} from '@/lib/highlight-storage'
import type { Highlight } from '@/types/highlight'
import {
  getBookmarksForBook,
  toggleBookmark,
  deleteBookmark as deleteBookmarkFromDb,
  isLocationBookmarked,
  type Bookmark,
} from '@/lib/bookmarks/bookmark-storage'
import { useUndoSnackbar } from '@/hooks/useUndoSnackbar'
import { UndoSnackbar } from '@/components/UndoSnackbar'
import {
  ReaderShell,
  ReaderShellContext,
  ReaderErrorScreen,
  type ReaderErrorCause,
  type ReaderProgress,
  type TocItem,
} from '@/components/reader'

/**
 * DJVU reader using djvu.js — a pure JavaScript DJVU decoder.
 * The library is loaded from a CDN inside the WebView.
 * Pages are rendered to a <canvas> element.
 */
const DJVU_VIEWER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=yes"/>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1a1a1a;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-start;
    min-height: 100vh;
    padding: 16px 0 80px;
    overflow: auto;
  }
  canvas {
    max-width: 100%;
    height: auto;
    box-shadow: 0 2px 20px rgba(0,0,0,0.5);
  }
  .loading, .error {
    color: #aaa;
    font-family: -apple-system, sans-serif;
    font-size: 16px;
    text-align: center;
    padding: 40px 20px;
  }
  .error { color: #e55; }
</style>
</head>
<body>
<div class="loading" id="status">Loading DJVU viewer...</div>
<canvas id="canvas" style="display:none"></canvas>
<script src="https://cdn.jsdelivr.net/npm/djvu.js@0.5.2/dist/djvu.js"></script>
<script>
var djvuDoc = null;
var pageCount = 0;
var currentPage = 1;

function renderPage(pageNum) {
  if (!djvuDoc || pageNum < 1 || pageNum > pageCount) return;
  currentPage = pageNum;

  try {
    var page = djvuDoc.getPage(pageNum);
    var imageData = page.getImageData();

    var canvas = document.getElementById('canvas');
    canvas.width = imageData.width;
    canvas.height = imageData.height;
    var ctx = canvas.getContext('2d');
    ctx.putImageData(imageData, 0, 0);

    canvas.style.display = 'block';
    document.getElementById('status').style.display = 'none';

    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'page',
      current: currentPage,
      total: pageCount
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to render page ' + pageNum + ': ' + e.message;
    document.getElementById('status').style.display = 'block';
  }
}

function loadBook(base64) {
  try {
    document.getElementById('status').textContent = 'Decoding DJVU...';
    document.getElementById('status').style.display = 'block';

    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

    var buffer = bytes.buffer;
    djvuDoc = new DjVu.Document(buffer);
    pageCount = djvuDoc.getPageCount();

    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'loaded',
      total: pageCount
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to parse DJVU: ' + e.message;
    document.getElementById('status').style.display = 'block';
    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'error',
      message: e.message
    }));
  }
}

// Listen for messages from RN
document.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') renderPage(msg.page);
});
window.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') renderPage(msg.page);
});

// P1-K — Selection bridge.
//
// DJVU is canvas-only today: djvu.js rasterizes each page into the
// <canvas> element, so window.getSelection() over the canvas returns
// an empty string and this bridge stays inert in practice. We still
// wire it for two reasons:
//   1. The reader's 'onMessage' handler now branches on 'selection',
//      so a future text-layer / OCR phase (Phase 7) can light up the
//      "Read from here" pill without a code change to the reader.
//   2. It keeps the MOBI/DJVU wiring symmetric — same bridge, same
//      payload shape, same RN-side handler.
var __rishiSelectionTimer = null;
document.addEventListener('selectionchange', function() {
  if (__rishiSelectionTimer) clearTimeout(__rishiSelectionTimer);
  __rishiSelectionTimer = setTimeout(function() {
    try {
      var sel = (window.getSelection && window.getSelection()) ? window.getSelection().toString() : '';
      if (sel && sel.trim().length > 0) {
        window.ReactNativeWebView.postMessage(JSON.stringify({
          type: 'selection',
          text: sel
        }));
      }
    } catch (e) { /* ignore — selection API unavailable */ }
  }, 250);
});
</script>
</body>
</html>`

export default function DjvuReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const [book, setBook] = useState<Book | null>(null)
  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)
  // P0-L — track failed-load cause for ReaderErrorScreen.
  const [errorCause, setErrorCause] = useState<ReaderErrorCause | null>(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [pageCount, setPageCount] = useState(0)
  const [currentPage, setCurrentPage] = useState(1)
  const [bookLoaded, setBookLoaded] = useState(false)
  const [zoom, setZoom] = useState(100)
  const [highlights, setHighlights] = useState<Highlight[]>([])
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([])
  const [isCurrentBookmarked, setIsCurrentBookmarked] = useState<boolean>(false)
  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())
  const [noteEditorOpen, setNoteEditorOpen] = useState(false)
  // P1-K — last selection text reported by the WebView bridge. DJVU is
  // canvas-only today so this stays null in practice (window.getSelection
  // over the canvas returns ''); kept for symmetry with MOBI so a future
  // text layer / OCR phase can light up the "Read from here" pill.
  const [pendingSelection, setPendingSelection] = useState<string | null>(null)
  const undoSnackbar = useUndoSnackbar()

  const webViewRef = useRef<WebView>(null)
  const currentPageRef = useRef(1)
  // #41 — Mirrors `pageCount` so the bridged-message handler can
  // compute `current / total` for `updateBookProgress` without
  // waiting for React to re-render with the new state.
  const pageCountRef = useRef(0)

  // Mount the player machine for TTS read-aloud (Batch 7). The DJVU
  // extractor (chunker.getChunks for 'djvu') only returns paragraphs if
  // the DJVU extractor port is registered at app start. If not, the
  // toggle is a no-op (logged) and the user gets nothing to read.
  usePlayerMachine(book?.id ?? '')
  const playingState = usePlayerStore((s) => s.playingState)
  const ttsActive = playingState !== 'idle'
  const activeParagraph = usePlayerStore((s) => s.activeParagraph)

  // G14 — chat-resume bridge for DJVU.
  const { status: realtimeStatus } = useRealtimeChat(book?.id ?? '')
  useTtsChatBridge(realtimeStatus)

  // G20 — register the DJVU WebView as the page-capture target.
  const pageCaptureRef = useRef<View>(null)
  usePageCaptureRef(pageCaptureRef)

  // Premium feature gate — initial TTS start path must show the sign-in
  // sheet for signed-out users.
  const requireTTS = useRequireAuth('tts')
  const requireAIChat = useRequireAuth('ai-chat')

  // G15 — visual-cue driver from active paragraph text.
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

  const handleToggleTTS = useCallback(() => {
    const sendFn = usePlayerStore.getState().send
    if (!sendFn || !book) return
    if (ttsActive) {
      sendFn({ type: 'STOP' })
      return
    }
    requireTTS(async () => {
      try {
        const seeded = await seedPlayerParagraphsFromChunks(
          book.id,
          book.filePath,
          'djvu',
        )
        if (!seeded.seeded) {
          // STA-017 — DJVU extractor often returns no chunks (canvas-only
          // documents with no OCR layer). Surface a toast + a11y
          // announcement instead of a silent console.warn.
          console.warn('[djvu-tts] no chunks available — DJVU extractor not registered?')
          AccessibilityInfo.announceForAccessibility('No text available for reading')
          undoSnackbar.show('No text available for reading', 'Dismiss', () => undefined)
          return
        }
        sendFn({ type: 'PLAY' })
      } catch (err) {
        // STA-017 — DJVU seed threw. Surface a non-blocking toast; the
        // toolbar button stays usable.
        console.warn('[djvu-tts] seed failed:', err)
        AccessibilityInfo.announceForAccessibility('Could not start read-aloud')
        undoSnackbar.show('Could not start read-aloud', 'Dismiss', () => undefined)
      }
    })
  }, [book, ttsActive, requireTTS, undoSnackbar])

  // P1-K — "Read from here" handler for DJVU selections. DJVU is
  // canvas-only today so this rarely fires; wired for parity with the
  // MOBI / EPUB readers so a future text layer / OCR phase can light
  // up the floating pill without a reader-screen change.
  const handleReadFromSelection = useCallback(
    (selectionText: string) => {
      if (!book) return
      requireTTS(async () => {
        const send = usePlayerStore.getState().send
        if (!send) {
          // STA-024 — player machine not mounted yet; announce + toast.
          AccessibilityInfo.announceForAccessibility('Read-aloud unavailable right now')
          undoSnackbar.show('Read-aloud unavailable right now', 'Dismiss', () => undefined)
          return
        }
        let paragraphs = usePlayerStore.getState().currentParagraphs
        if (paragraphs.length === 0) {
          try {
            const seeded = await seedPlayerParagraphsFromChunks(
              book.id,
              book.filePath,
              'djvu',
            )
            if (!seeded.seeded) {
              // STA-024 — DJVU often returns no chunks (no OCR layer).
              // Announce + toast for parity with EPUB.
              AccessibilityInfo.announceForAccessibility('No text available for reading')
              undoSnackbar.show('No text available for reading', 'Dismiss', () => undefined)
              return
            }
            paragraphs = seeded.paragraphs
          } catch (err) {
            // STA-024 — seed threw. Announce + show a toast.
            console.warn('[djvu-read-aloud-from] seed failed:', err)
            AccessibilityInfo.announceForAccessibility('Could not start read-aloud')
            undoSnackbar.show('Could not start read-aloud', 'Dismiss', () => undefined)
            return
          }
        }
        const playFrom = resolvePlainTextReadFromSelection(
          selectionText,
          paragraphs,
        )
        if (!playFrom) {
          // STA-024 — resolver couldn't locate the selection. Parity with EPUB.
          AccessibilityInfo.announceForAccessibility('Could not find the selected text')
          undoSnackbar.show(
            'Could not find selected text on this page.',
            'Dismiss',
            () => undefined,
          )
          return
        }
        send({
          type: 'PLAY_FROM',
          paragraphIndex: playFrom.paragraphIndex,
          partialFirstText: playFrom.partialFirstText,
          partialFirstKey: playFrom.partialFirstKey,
        })
        setPendingSelection(null)
      })
    },
    [book, requireTTS, undoSnackbar],
  )

  // Load book from DB
  useEffect(() => {
    if (id) {
      setLoading(true)
      setDownloading(false)
      setErrorCause(null)
      getBookForReading(id, { onDownloadStart: () => setDownloading(true) })
        .then((loaded) => {
          if (loaded) {
            setBook(loaded)
            const startPage = loaded.currentPage || 1
            setCurrentPage(startPage)
            currentPageRef.current = startPage
            setHighlights(getHighlightsByBookId(loaded.id))
            setBookmarks(getBookmarksForBook(loaded.id))
          }
        })
        .catch((err) => {
          console.error('Failed to load book for reading:', err)
          setBook(null)
          // Only the R2 download path throws — surface as a cloud failure.
          setErrorCause('cloud-download-failed')
        })
        .finally(() => setLoading(false))
    }
  }, [id, loadAttempt])

  // Send file data to WebView once djvu.js is loaded
  useEffect(() => {
    if (!book || !bookLoaded) return

    const file = new ExpoFile(book.filePath)
    file.base64().then((base64) => {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'load', data: base64 })
      )
    })
  }, [book, bookLoaded])

  // Save position on app background
  useEffect(() => {
    const handleAppStateChange = (nextState: AppStateStatus) => {
      if (nextState === 'background' || nextState === 'inactive') {
        if (book?.id) {
          updateBookPage(book.id, currentPageRef.current)
          // #41 — Mirror progress for the library "Reading Now" pill
          // ("Page X of Y").
          const total = pageCountRef.current
          if (total > 0) {
            updateBookProgress(book.id, currentPageRef.current / total)
          }
        }
      }
    }
    const sub = AppState.addEventListener('change', handleAppStateChange)
    return () => sub.remove()
  }, [book?.id])

  const handleMessage = useCallback(
    (event: { nativeEvent: { data: string } }) => {
      const msg = JSON.parse(event.nativeEvent.data)
      if (msg.type === 'loaded') {
        setPageCount(msg.total)
        // #41 — Mirror into the ref so handleMessage's subsequent
        // 'page' events can compute progress without waiting for
        // React to re-render with the new state.
        pageCountRef.current = typeof msg.total === 'number' ? msg.total : 0
        // Render the saved page
        webViewRef.current?.postMessage(
          JSON.stringify({ type: 'goto', page: currentPageRef.current })
        )
      } else if (msg.type === 'page') {
        setCurrentPage(msg.current)
        currentPageRef.current = msg.current
        if (book?.id) {
          updateBookPage(book.id, msg.current)
          // #41 — Persist progress so the library pill subline can
          // render "Page X of Y" after the reader closes.
          const total = pageCountRef.current
          if (total > 0) {
            updateBookProgress(book.id, msg.current / total)
          }
        }
      } else if (msg.type === 'selection') {
        // P1-K — DJVU canvas selection bridge. In practice the canvas
        // returns an empty selection string and this branch never fires;
        // wired for future text-layer / OCR support so adding it
        // doesn't require a reader-screen change.
        const text = typeof msg.text === 'string' ? msg.text : ''
        setPendingSelection(text.trim().length > 0 ? text : null)
      }
    },
    [book?.id]
  )

  // ---- Bookmarks ----
  useEffect(() => {
    if (!book?.id) return
    const loc = `djvu-page:${currentPage}`
    setIsCurrentBookmarked(isLocationBookmarked(book.id, loc))
  }, [book?.id, bookmarks, currentPage])

  const handleToggleBookmark = useCallback(() => {
    if (!book?.id) return
    const loc = `djvu-page:${currentPage}`
    const label =
      pageCount > 0
        ? `Page ${currentPage} of ${pageCount}`
        : `Page ${currentPage}`
    const result = toggleBookmark({ bookId: book.id, location: loc, label })
    setBookmarks(getBookmarksForBook(book.id))
    setIsCurrentBookmarked(result.action === 'created')
    // RDR-027 — differentiated confirmation haptic (success on create,
    // warning on remove). Matches the EPUB reader's bookmark toggle.
    if (result.action === 'created') {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
    } else {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)
    }
  }, [book?.id, currentPage, pageCount])

  const handleDeleteBookmark = useCallback(
    (bookmarkId: string) => {
      if (!book?.id) return
      deleteBookmarkFromDb(bookmarkId)
      setBookmarks(getBookmarksForBook(book.id))
    },
    [book?.id],
  )

  const handleNavigateToBookmark = useCallback((location: string) => {
    const m = /^djvu-page:(\d+)$/.exec(location)
    if (!m) return
    const page = Number.parseInt(m[1], 10)
    if (Number.isFinite(page) && page >= 1) {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page }),
      )
    }
  }, [])

  // ---- Highlights (read-only listing; djvu canvas can't capture text) ----
  const handleNavigateToHighlight = useCallback((_cfiRange: string) => {
    // No structural mapping yet — clicking just closes the sheet.
  }, [])

  const handleDeleteHighlightById = useCallback(
    (id: string) => {
      const target = highlights.find((h) => h.id === id)
      if (!target) return
      deleteHighlight(id)
      setHighlights((prev) => prev.filter((h) => h.id !== id))
      undoSnackbar.show('Highlight deleted', 'Undo', () => {
        restoreHighlight(id)
        setHighlights((prev) => [target, ...prev])
      })
    },
    [highlights, undoSnackbar],
  )

  // ---- TOC adapter — synthesize one entry per page. ----
  const tocItems = useMemo<TocItem[]>(() => {
    if (pageCount === 0) return []
    return Array.from({ length: pageCount }, (_, i) => ({
      href: `djvu-page:${i + 1}`,
      label: `Page ${i + 1}`,
    }))
  }, [pageCount])

  // CHT-002 — voice-chat activation context. DJVU is canvas-only (no text
  // layer that survives the WebView round-trip), so the best we can do is
  // pass a "Page N of M" page-text proxy plus the synthesised per-page
  // outline. When TTS is active, forward the active paragraph too — the
  // shared extractor can light this up if the DJVU has an OCR layer.
  // Declared above the loading/error early-returns so the hook order stays
  // stable across renders (react-hooks/rules-of-hooks).
  const getActivationContext = useCallback(() => {
    const outline = tocItems.map((t) => ({ href: t.href, label: t.label }))
    const pageText = pageCount > 0
      ? `Page ${currentPage} of ${pageCount}`
      : `Page ${currentPage}`
    return {
      pageText,
      outline,
      activeParagraphText: activeParagraph?.text ?? undefined,
    }
  }, [tocItems, currentPage, pageCount, activeParagraph])

  const currentTocHref = useMemo(
    () => `djvu-page:${currentPage}`,
    [currentPage],
  )

  const handleSelectChapter = useCallback((href: string) => {
    const m = /^djvu-page:(\d+)$/.exec(href)
    if (!m) return
    const page = Number.parseInt(m[1], 10)
    if (Number.isFinite(page) && page >= 1) {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page }),
      )
    }
  }, [])

  // ---- Appearance ----
  const handleSettingsChange = useCallback((next: ReaderSettings) => {
    saveReaderSettings(next)
    setSettings(next)
  }, [])

  // Issue #47 — forward the active theme into the WebView whenever it
  // changes. DJVU is canvas-only today so the perceived effect is the
  // body background swap behind the canvas; without the hop, the
  // AppearanceSheet's theme picker is a no-op for DJVU users.
  useEffect(() => {
    if (!bookLoaded || !webViewRef.current) return
    const theme = READER_THEMES[settings.themeName]
    webViewRef.current.injectJavaScript(buildReaderThemeInjection(theme))
  }, [bookLoaded, settings.themeName])

  // safeBack: guards against deep-link cold-start where the nav stack is
  // empty and a bare router.back() would strand the user (P1-B).
  const handleBack = useCallback(() => {
    if (book?.id) {
      updateBookPage(book.id, currentPageRef.current)
      // #41 — Persist progress (see handleMessage / handleAppStateChange).
      const total = pageCountRef.current
      if (total > 0) {
        updateBookProgress(book.id, currentPageRef.current / total)
      }
    }
    safeBack(router)
  }, [book?.id, router])

  const handlePrevPage = useCallback(() => {
    if (currentPageRef.current > 1) {
      const next = currentPageRef.current - 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page: next })
      )
    }
  }, [])

  const handleNextPage = useCallback(() => {
    if (currentPageRef.current < pageCount) {
      const next = currentPageRef.current + 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page: next })
      )
    }
  }, [pageCount])

  const handleZoomIn = useCallback(() => {
    setZoom(prev => Math.min(prev + 25, 300))
  }, [])

  const handleZoomOut = useCallback(() => {
    setZoom(prev => Math.max(prev - 25, 50))
  }, [])

  // Send zoom level to WebView when it changes
  useEffect(() => {
    webViewRef.current?.injectJavaScript(`
      document.getElementById('canvas').style.transform = 'scale(${zoom / 100})';
      document.getElementById('canvas').style.transformOrigin = 'top center';
      true;
    `)
  }, [zoom])

  if (loading) {
    return (
      <View testID="reader-loading" style={{ flex: 1, backgroundColor: '#1a1a1a', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" color="#aaa" />
        <Text style={{ marginTop: 12, color: '#aaa' }}>
          {downloading ? 'Downloading…' : 'Loading book…'}
        </Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    // P0-L — distinguish "cloud download failed" from "local file gone".
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
      ? { kind: 'page', current: currentPage, total: pageCount }
      : { kind: 'none' }

  const djvuNavCluster = (
    <DjvuNavCluster
      currentPage={currentPage}
      pageCount={pageCount}
      zoom={zoom}
      onPrev={handlePrevPage}
      onNext={handleNextPage}
      onZoomIn={handleZoomIn}
      onZoomOut={handleZoomOut}
    />
  )

  return (
    <View ref={pageCaptureRef} testID="djvu-reader" style={{ flex: 1, backgroundColor: '#1a1a1a' }}>
      <ReaderShell
        title={book.title}
        format="djvu"
        onBack={handleBack}
        progress={progressForShell}
        centerOverride={djvuNavCluster}
        ttsActive={ttsActive}
        realtimeActive={realtimeStatus !== 'idle'}
        bookId={book.id}
        onChatToggle={() =>
          requireAIChat(() => router.push(`/chat/${book.id}`))
        }
        getActivationContext={getActivationContext}
        onTTSPress={handleToggleTTS}
        ttsButtonActive={ttsActive}
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
        noteEditorHighlight={null}
        noteEditorOpen={noteEditorOpen}
        onSaveNote={() => setNoteEditorOpen(false)}
        onDiscardNote={() => setNoteEditorOpen(false)}
      >
        {/* E2E observability — see PDF reader for rationale. */}
        <View
          testID="reader-position-indicator"
          accessible={true}
          accessibilityLabel={`${currentPage}/${pageCount || 0}`}
          style={{ position: 'absolute', width: 0, height: 0 }}
        />
        {/* P0-B — Pressable goes FIRST so it sits behind the WebView.
            The WebView still receives every gesture; only taps the
            WebView doesn't consume fall through to reveal the toolbar. */}
        <PressableToggleToolbar />

        <WebView
          ref={webViewRef}
          source={{ html: DJVU_VIEWER_HTML }}
          originWhitelist={['*']}
          onMessage={handleMessage}
          onLoadEnd={() => setBookLoaded(true)}
          style={{ flex: 1 }}
          javaScriptEnabled={true}
          allowsInlineMediaPlayback={true}
          onShouldStartLoadWithRequest={(request) => {
            // Allow CDN load for djvu.js and the initial HTML
            if (
              request.url.startsWith('about:') ||
              request.url.startsWith('data:') ||
              request.url.includes('cdn.jsdelivr.net')
            ) {
              return true
            }
            return false
          }}
        />

        {/* G15 — visual cue badge */}
        <TTSVisualCue />

        {/* P1-K — Floating "Read from here" pill. Renders only when
            the WebView reports a non-empty selection. For DJVU this
            is effectively a no-op today (canvas-only, no text layer)
            but the wiring matches MOBI / EPUB so future text-layer
            support lights it up automatically. */}
        {pendingSelection && (
          <View style={styles.readFromPillWrapper} pointerEvents="box-none">
            <TouchableOpacity
              testID="reader-read-from-selection-btn"
              accessibilityLabel="Read from here"
              onPress={() => handleReadFromSelection(pendingSelection)}
              style={styles.readFromPill}
            >
              <IconSymbol name="play.fill" size={16} color="#fff" />
              <Text style={styles.readFromPillText}>Read from here</Text>
            </TouchableOpacity>
          </View>
        )}

        {/* G10 — undo snackbar (5s window after a destructive action) */}
        <UndoSnackbar
          visible={undoSnackbar.visible}
          message={undoSnackbar.message}
          actionLabel={undoSnackbar.actionLabel}
          onAction={undoSnackbar.action}
          onDismiss={undoSnackbar.dismiss}
        />
      </ReaderShell>
    </View>
  )
}

/**
 * Full-area Pressable for tap-to-toggle. Lives inside ReaderShell so it
 * can call `toggleToolbar` from context. testID is preserved for Detox.
 *
 * P0-B — uses `StyleSheet.absoluteFill` so the whole page area routes
 * "missed" taps through to the toggle. The Pressable is mounted BEFORE
 * the WebView in JSX so it sits BEHIND it; the WebView still receives
 * all gestures, only taps the WebView doesn't consume fall through.
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

interface DjvuNavClusterProps {
  currentPage: number
  pageCount: number
  zoom: number
  onPrev: () => void
  onNext: () => void
  onZoomIn: () => void
  onZoomOut: () => void
}

function DjvuNavCluster({
  currentPage,
  pageCount,
  zoom,
  onPrev,
  onNext,
  onZoomIn,
  onZoomOut,
}: DjvuNavClusterProps): React.JSX.Element {
  return (
    <View style={styles.navCluster}>
      <TouchableOpacity
        onPress={onZoomOut}
        disabled={zoom <= 50}
        style={[styles.navBtn, zoom <= 50 && { opacity: 0.3 }]}
        accessibilityLabel="Zoom out"
      >
        <IconSymbol name="minus.magnifyingglass" size={20} color="#fff" />
      </TouchableOpacity>
      <Text style={styles.zoomLabel}>{zoom}%</Text>
      <TouchableOpacity
        onPress={onZoomIn}
        disabled={zoom >= 300}
        style={[styles.navBtn, zoom >= 300 && { opacity: 0.3 }]}
        accessibilityLabel="Zoom in"
      >
        <IconSymbol name="plus.magnifyingglass" size={20} color="#fff" />
      </TouchableOpacity>

      <View style={styles.separator} />

      <TouchableOpacity
        onPress={onPrev}
        disabled={currentPage <= 1}
        style={[styles.navBtn, currentPage <= 1 && { opacity: 0.3 }]}
        accessibilityLabel="Previous page"
      >
        <IconSymbol name="chevron.left" size={24} color="#fff" />
      </TouchableOpacity>

      <Text style={styles.navLabel}>
        {pageCount > 0 ? `${currentPage}/${pageCount}` : '...'}
      </Text>

      <TouchableOpacity
        testID="reader-next-page-btn"
        onPress={onNext}
        disabled={currentPage >= pageCount}
        style={[styles.navBtn, currentPage >= pageCount && { opacity: 0.3 }]}
        accessibilityLabel="Next page"
      >
        <IconSymbol name="chevron.right" size={24} color="#fff" />
      </TouchableOpacity>
    </View>
  )
}

const styles = StyleSheet.create({
  navCluster: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  navBtn: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
  navLabel: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '500',
    minWidth: 56,
    textAlign: 'center',
  },
  zoomLabel: {
    color: '#fff',
    fontSize: 12,
    minWidth: 36,
    textAlign: 'center',
  },
  separator: {
    width: 1,
    height: 16,
    backgroundColor: 'rgba(255,255,255,0.3)',
    marginHorizontal: 2,
  },
  // P1-K — Floating "Read from here" pill.
  readFromPillWrapper: {
    position: 'absolute',
    bottom: 96,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  readFromPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    backgroundColor: '#0a7ea4',
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 22,
    minHeight: 44,
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowOffset: { width: 0, height: 2 },
    shadowRadius: 4,
    elevation: 4,
  },
  readFromPillText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
})
