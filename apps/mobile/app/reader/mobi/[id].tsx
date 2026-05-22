import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import {
  View,
  Text,
  TouchableOpacity,
  Pressable,
  AppState,
  AppStateStatus,
  ActivityIndicator,
  StyleSheet,
} from 'react-native'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { WebView } from 'react-native-webview'
import { File as ExpoFile } from 'expo-file-system'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { getBookForReading, updateBookPage } from '@/lib/book-storage'
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
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
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
 * Minimal inline MOBI parser running inside a WebView.
 *
 * MOBI/PalmDOC format overview:
 * - PDB header (78 bytes) contains record offsets
 * - Record 0 is the MOBI header with metadata
 * - Records 1..N contain PalmDOC-compressed HTML
 * - Compression type 1 = none, type 2 = PalmDOC LZ77
 *
 * We extract the HTML, split by <mbp:pagebreak/> into chapters,
 * and render the current chapter. Navigation is handled by RN.
 */
const MOBI_PARSER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=yes"/>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 18px;
    line-height: 1.7;
    padding: 16px 20px 80px;
    color: #1a1a1a;
    background: #fafaf8;
    word-wrap: break-word;
    overflow-wrap: break-word;
  }
  img { max-width: 100%; height: auto; }
  a { color: #0a7ea4; }
  h1, h2, h3 { margin: 1em 0 0.5em; }
  p { margin: 0.5em 0; }
  .loading { display: flex; align-items: center; justify-content: center; height: 80vh; color: #666; font-size: 16px; }
  .error { color: #c00; padding: 20px; text-align: center; }
</style>
</head>
<body>
<div class="loading" id="status">Parsing MOBI file...</div>
<div id="content" style="display:none"></div>
<script>
// PalmDOC decompression (LZ77 variant)
function decompressPalmDOC(data) {
  var out = [];
  var i = 0;
  while (i < data.length) {
    var c = data[i++];
    if (c === 0) {
      out.push(0);
    } else if (c >= 1 && c <= 8) {
      for (var j = 0; j < c && i < data.length; j++) {
        out.push(data[i++]);
      }
    } else if (c >= 9 && c <= 0x7F) {
      out.push(c);
    } else if (c >= 0x80 && c <= 0xBF) {
      if (i >= data.length) break;
      var next = data[i++];
      var dist = ((c << 8) | next) >> 3 & 0x7FF;
      var len = (next & 0x07) + 3;
      for (var k = 0; k < len; k++) {
        if (out.length - dist >= 0) {
          out.push(out[out.length - dist]);
        } else {
          out.push(0);
        }
      }
    } else {
      // c >= 0xC0: space + (c ^ 0x80)
      out.push(32);
      out.push(c ^ 0x80);
    }
  }
  return new Uint8Array(out);
}

function parseMobi(buf) {
  var view = new DataView(buf);

  // PDB header: numRecords at offset 76
  var numRecords = view.getUint16(76, false);

  // Record info list starts at offset 78, each entry is 8 bytes
  var recordOffsets = [];
  for (var r = 0; r < numRecords; r++) {
    recordOffsets.push(view.getUint32(78 + r * 8, false));
  }

  // Record 0 is the MOBI/PalmDOC header
  var rec0Start = recordOffsets[0];
  var compression = view.getUint16(rec0Start, false); // 1=none, 2=PalmDOC
  var textRecordCount = view.getUint16(rec0Start + 8, false);

  // Extract and decompress text records
  var allBytes = [];
  for (var i = 1; i <= textRecordCount && i < recordOffsets.length; i++) {
    var start = recordOffsets[i];
    var end = (i + 1 < recordOffsets.length) ? recordOffsets[i + 1] : buf.byteLength;
    var recData = new Uint8Array(buf, start, end - start);

    if (compression === 2) {
      var decompressed = decompressPalmDOC(recData);
      for (var b = 0; b < decompressed.length; b++) allBytes.push(decompressed[b]);
    } else {
      for (var b = 0; b < recData.length; b++) allBytes.push(recData[b]);
    }
  }

  var decoder = new TextDecoder('utf-8', { fatal: false });
  var html = decoder.decode(new Uint8Array(allBytes));

  // Split into chapters by <mbp:pagebreak/>
  var chapters = html.split(/<mbp:pagebreak\\s*\\/?>/i).filter(function(ch) {
    return ch.trim().length > 0;
  });

  if (chapters.length === 0) {
    chapters = [html];
  }

  return chapters;
}

var chapters = [];
var currentChapter = 0;

function showChapter(index) {
  if (index < 0 || index >= chapters.length) return;
  currentChapter = index;
  // Sanitize: render via DOM parser to strip scripts
  var parser = new DOMParser();
  var doc = parser.parseFromString(chapters[index], 'text/html');
  // Remove any script tags from parsed content
  doc.querySelectorAll('script').forEach(function(s) { s.remove(); });
  document.getElementById('content').innerHTML = doc.body.innerHTML;
  document.getElementById('content').style.display = 'block';
  document.getElementById('status').style.display = 'none';
  window.scrollTo(0, 0);
  window.ReactNativeWebView.postMessage(JSON.stringify({
    type: 'chapter',
    current: currentChapter,
    total: chapters.length
  }));
}

function loadBook(base64) {
  try {
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    chapters = parseMobi(bytes.buffer);
    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'loaded',
      total: chapters.length
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to parse MOBI: ' + e.message;
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
  if (msg.type === 'goto') showChapter(msg.chapter);
});
window.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') showChapter(msg.chapter);
});
</script>
</body>
</html>`

export default function MobiReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const [book, setBook] = useState<Book | null>(null)
  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)
  // P0-L — track failed-load cause for ReaderErrorScreen.
  const [errorCause, setErrorCause] = useState<ReaderErrorCause | null>(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [chapterCount, setChapterCount] = useState(0)
  const [currentChapter, setCurrentChapter] = useState(0)
  const [bookLoaded, setBookLoaded] = useState(false)
  const [highlights, setHighlights] = useState<Highlight[]>([])
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([])
  const [isCurrentBookmarked, setIsCurrentBookmarked] = useState<boolean>(false)
  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())
  const [noteEditorOpen, setNoteEditorOpen] = useState(false)
  const undoSnackbar = useUndoSnackbar()

  const webViewRef = useRef<WebView>(null)
  const currentChapterRef = useRef(0)

  // Mount the player machine for this book — TTS controls (rendered
  // below) read state from `usePlayerStore`.
  usePlayerMachine(book?.id ?? '')
  const playingState = usePlayerStore((s) => s.playingState)
  const ttsActive = playingState !== 'idle'

  const activeParagraph = usePlayerStore((s) => s.activeParagraph)

  // G14 — chat-resume bridge: when realtime voice-chat starts/ends,
  // dispatch CHAT_STARTED / CHAT_ENDED into the player so the active
  // paragraph is preserved across the interruption.
  const { status: realtimeStatus } = useRealtimeChat(book?.id ?? '')
  useTtsChatBridge(realtimeStatus)

  // G20 — register the MOBI WebView as the page-capture target.
  const pageCaptureRef = useRef<View>(null)
  usePageCaptureRef(pageCaptureRef)

  // Premium feature gate — initial TTS start path must show the sign-in
  // sheet for signed-out users.
  const requireTTS = useRequireAuth('tts')
  const requireAIChat = useRequireAuth('ai-chat')

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
            const startChapter = loaded.currentPage || 0
            setCurrentChapter(startChapter)
            currentChapterRef.current = startChapter
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

  // Send file data to WebView once loaded
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
          updateBookPage(book.id, currentChapterRef.current)
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
        setChapterCount(msg.total)
        // Navigate to saved chapter
        webViewRef.current?.postMessage(
          JSON.stringify({ type: 'goto', chapter: currentChapterRef.current })
        )
      } else if (msg.type === 'chapter') {
        setCurrentChapter(msg.current)
        currentChapterRef.current = msg.current
        if (book?.id) {
          updateBookPage(book.id, msg.current)
        }
      }
    },
    [book?.id]
  )

  // ---- Bookmarks ----
  useEffect(() => {
    if (!book?.id) return
    const loc = `mobi-chapter:${currentChapter}`
    setIsCurrentBookmarked(isLocationBookmarked(book.id, loc))
  }, [book?.id, bookmarks, currentChapter])

  const handleToggleBookmark = useCallback(() => {
    if (!book?.id) return
    const loc = `mobi-chapter:${currentChapter}`
    const label =
      chapterCount > 0
        ? `Chapter ${currentChapter + 1} of ${chapterCount}`
        : `Chapter ${currentChapter + 1}`
    const result = toggleBookmark({ bookId: book.id, location: loc, label })
    setBookmarks(getBookmarksForBook(book.id))
    setIsCurrentBookmarked(result.action === 'created')
  }, [book?.id, currentChapter, chapterCount])

  const handleDeleteBookmark = useCallback(
    (bookmarkId: string) => {
      if (!book?.id) return
      deleteBookmarkFromDb(bookmarkId)
      setBookmarks(getBookmarksForBook(book.id))
    },
    [book?.id],
  )

  const handleNavigateToBookmark = useCallback((location: string) => {
    const m = /^mobi-chapter:(\d+)$/.exec(location)
    if (!m) return
    const chapter = Number.parseInt(m[1], 10)
    if (Number.isFinite(chapter) && chapter >= 0) {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter }),
      )
    }
  }, [])

  // ---- Highlights (read-only listing; MOBI doesn't yet capture
  //      selection highlights, but synced rows still surface here.) ----
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

  // ---- TOC adapter — synthesize one entry per chapter. ----
  const tocItems = useMemo<TocItem[]>(() => {
    if (chapterCount === 0) return []
    return Array.from({ length: chapterCount }, (_, i) => ({
      href: `mobi-chapter:${i}`,
      label: `Chapter ${i + 1}`,
    }))
  }, [chapterCount])

  const currentTocHref = useMemo(
    () => `mobi-chapter:${currentChapter}`,
    [currentChapter],
  )

  const handleSelectChapter = useCallback((href: string) => {
    const m = /^mobi-chapter:(\d+)$/.exec(href)
    if (!m) return
    const chapter = Number.parseInt(m[1], 10)
    if (Number.isFinite(chapter) && chapter >= 0) {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter }),
      )
    }
  }, [])

  // ---- Appearance ----
  const handleSettingsChange = useCallback((next: ReaderSettings) => {
    saveReaderSettings(next)
    setSettings(next)
  }, [])

  const handleBack = useCallback(() => {
    if (book?.id) {
      updateBookPage(book.id, currentChapterRef.current)
    }
    router.back()
  }, [book?.id, router])

  const handlePrevChapter = useCallback(() => {
    if (currentChapterRef.current > 0) {
      const next = currentChapterRef.current - 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter: next })
      )
    }
  }, [])

  const handleNextChapter = useCallback(() => {
    if (currentChapterRef.current < chapterCount - 1) {
      const next = currentChapterRef.current + 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter: next })
      )
    }
  }, [chapterCount])

  // ---- TTS: read aloud (Batch 7) ----
  // Mobi/Azw3 chunks come from the shared mobi extractor — the same one
  // the chunker uses for RAG. We seed paragraphs once and dispatch PLAY;
  // the player machine fetches audio via the new TTS service.
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
          book.format,
        )
        if (!seeded.seeded) return
        sendFn({ type: 'PLAY' })
      } catch (err) {
        console.warn('[mobi-tts] seed failed:', err)
      }
    })
  }, [book, ttsActive, requireTTS])

  // CSS reconciler: highlight the active paragraph inside the WebView.
  // Uses a simple data-attribute selector — the parser doesn't emit
  // paragraph ids so this is best-effort; the active id from the player
  // is the chunker's stable id which doesn't survive the round-trip
  // through the chapter-split HTML. We instead apply a global "TTS
  // active" CSS hint by injecting a stylesheet once the WebView is ready.
  useEffect(() => {
    if (!bookLoaded || !webViewRef.current) return
    if (!activeParagraph) return
    // Best-effort inline highlight: scroll the WebView to the top of
    // the active paragraph by id when the WebView can find a matching
    // element. Most MOBI HTML doesn't carry stable ids, so this is a
    // no-op in practice — the audio still plays, the visual cue is
    // simply not present (matches what electron does on AZW3 when the
    // doc has no paragraph ids).
    webViewRef.current.injectJavaScript(`
      try {
        var el = document.querySelector('[data-paragraph-index="${activeParagraph.index}"]');
        if (el) {
          el.scrollIntoView({behavior: 'smooth', block: 'center'});
          document.querySelectorAll('.rishi-tts-active').forEach(function(n){n.classList.remove('rishi-tts-active')});
          el.classList.add('rishi-tts-active');
        }
      } catch (e) {}
      true;
    `)
  }, [activeParagraph, bookLoaded])

  // G15 — visual-cue heuristic. MOBI/AZW3 chunks come from the
  // PalmDOC parser as plain text; the classifier picks up LaTeX and
  // labelled-figure markers.
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

  if (loading) {
    return (
      <View testID="reader-loading" style={{ flex: 1, backgroundColor: '#fafaf8', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" />
        <Text style={{ marginTop: 12, color: '#666' }}>
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
        onBack={() => {
          if (router.canGoBack()) router.back()
          else router.replace('/(tabs)')
        }}
        onRetry={() => setLoadAttempt((n) => n + 1)}
      />
    )
  }

  const progressForShell: ReaderProgress =
    chapterCount > 0
      ? { kind: 'chapter', current: currentChapter + 1, total: chapterCount }
      : { kind: 'none' }

  const mobiNavCluster = (
    <MobiNavCluster
      currentChapter={currentChapter}
      chapterCount={chapterCount}
      onPrev={handlePrevChapter}
      onNext={handleNextChapter}
    />
  )

  return (
    <View ref={pageCaptureRef} testID="mobi-reader" style={{ flex: 1, backgroundColor: '#fafaf8' }}>
      <ReaderShell
        title={book.title}
        format="mobi"
        onBack={handleBack}
        progress={progressForShell}
        centerOverride={mobiNavCluster}
        ttsActive={ttsActive}
        realtimeActive={realtimeStatus !== 'idle'}
        bookId={book.id}
        onChatToggle={() =>
          requireAIChat(() => router.push(`/chat/${book.id}`))
        }
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
          accessibilityLabel={`${currentChapter + 1}/${chapterCount || 0}`}
          style={{ position: 'absolute', width: 0, height: 0 }}
        />
        {/* P0-B — Pressable goes FIRST so it sits behind the WebView.
            The WebView still receives every gesture; only taps that
            land where the WebView doesn't (or that the WebView ignores)
            fall through to reveal the toolbar. */}
        <PressableToggleToolbar />

        {/* Wrap the WebView in a flex container View so it doesn't
            render as a direct child of the reader root. iOS RN's
            new-architecture renderer composites WKWebView on its own
            layer, which can confuse Detox's visibility hit-test for
            sibling overlays (toolbar buttons). The extra wrapper
            isolates the WebView's compositor layer. */}
        <View style={{ flex: 1 }}>
          <WebView
            ref={webViewRef}
            source={{ html: MOBI_PARSER_HTML }}
            originWhitelist={['*']}
            onMessage={handleMessage}
            onLoadEnd={() => setBookLoaded(true)}
            style={{ flex: 1 }}
            javaScriptEnabled={true}
            onShouldStartLoadWithRequest={() => true}
          />
        </View>

        {/* G15 — visual cue badge */}
        <TTSVisualCue />

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
 * the WebView wrapper so it sits BEHIND the WebView; the WebView still
 * receives all its scroll / select gestures, and only taps the WebView
 * doesn't consume (including the edges around its bounds) fall through.
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

interface MobiNavClusterProps {
  currentChapter: number
  chapterCount: number
  onPrev: () => void
  onNext: () => void
}

function MobiNavCluster({
  currentChapter,
  chapterCount,
  onPrev,
  onNext,
}: MobiNavClusterProps): React.JSX.Element {
  return (
    <View style={styles.navCluster}>
      <TouchableOpacity
        onPress={onPrev}
        disabled={currentChapter <= 0}
        style={[styles.navBtn, currentChapter <= 0 && { opacity: 0.3 }]}
        accessibilityLabel="Previous chapter"
      >
        <IconSymbol name="chevron.left" size={24} color="#fff" />
      </TouchableOpacity>

      <Text style={styles.navLabel}>
        {chapterCount > 0 ? `Ch ${currentChapter + 1}/${chapterCount}` : '...'}
      </Text>

      <TouchableOpacity
        testID="reader-next-page-btn"
        onPress={onNext}
        disabled={currentChapter >= chapterCount - 1}
        style={[styles.navBtn, currentChapter >= chapterCount - 1 && { opacity: 0.3 }]}
        accessibilityLabel="Next chapter"
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
    gap: 16,
  },
  navBtn: {
    width: 36,
    height: 36,
    justifyContent: 'center',
    alignItems: 'center',
  },
  navLabel: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '500',
    minWidth: 72,
    textAlign: 'center',
  },
})
