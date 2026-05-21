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
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
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
import { useLocalSearchParams, useRouter } from 'expo-router'

import { IconSymbol } from '@/components/ui/icon-symbol'
import { PdfWebReader, type PdfWebReaderHandle } from '@/components/pdf/PdfWebReader'
import {
  flattenOutline,
  type PdfOutlineItem,
} from '@/components/pdf/pdf-webview-bridge'
import { usePdfStore, BookNavigationState } from '@/lib/stores/pdfStore'
import { getBookForReading, updateBookPage } from '@/lib/book-storage'
import { Book } from '@/types/book'
import {
  insertPdfHighlight,
  getPdfHighlightsByBookId,
  updateHighlight,
  deleteHighlight,
  type PdfHighlight,
} from '@/lib/highlight-storage'
import { HIGHLIGHT_COLORS, type HighlightColor } from '@/types/highlight'
import type { PdfLocator } from '@rishi/shared/types/pdf-locator'
import { resolvePlayFromSelection } from '@/lib/pdf/read-aloud-from-selection'

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
  const [toolbarVisible, setToolbarVisible] = useState(true)
  const [outlineVisible, setOutlineVisible] = useState(false)
  const [selection, setSelection] = useState<ActiveSelection | null>(null)
  const [pickerHighlight, setPickerHighlight] = useState<PdfHighlight | null>(null)
  const [pickerAnchor, setPickerAnchor] = useState<{ x: number; y: number } | null>(null)
  const [highlights, setHighlights] = useState<PdfHighlight[]>([])

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
    getBookForReading(id)
      .then(async (loaded) => {
        if (!loaded) return
        setBook(loaded)
        setHighlights(getPdfHighlightsByBookId(loaded.id))
      })
      .catch((err) => console.error('[PdfReaderScreen] load failed:', err))
      .finally(() => setLoading(false))
  }, [id])

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
      Alert.alert(
        'Go to Page',
        `Current page: ${pageNumber} of ${pageCount}\n(Enter via the page indicator)`
      )
    }
  }, [pageCount, pageNumber, setPageNumberStore])

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
    deleteHighlight(pickerHighlight.id)
    setHighlights((prev) => prev.filter((h) => h.id !== pickerHighlight.id))
    readerRef.current?.removeHighlight(pickerHighlight.id)
    setPickerHighlight(null)
    setPickerAnchor(null)
  }, [pickerHighlight])

  /**
   * Read-from-selection (G17). Fetches the selected page's paragraphs
   * from the WebView, resolves to a PLAY_FROM payload via the shared
   * resolver, then forwards to the player service.
   *
   * The player-service wiring is being threaded through the new
   * service in Batch 3; this screen calls the resolver and surfaces
   * the result via console+haptic until the player UI lands. The
   * resolver result is the same shape `playerStore.send({type:
   * 'PLAY_FROM', ...})` consumes, so when the integration is done it's
   * a one-line dispatch.
   */
  const handleReadFromSelection = useCallback(async () => {
    if (!selection) return
    try {
      const paragraphs = await readerRef.current?.getPageText(selection.pageNumber)
      if (!paragraphs) return
      const playFrom = resolvePlayFromSelection(selection.text, paragraphs)
      if (!playFrom) {
        Alert.alert('Read aloud', 'Could not find the selected text on this page.')
        return
      }
      // TODO(Batch 5 follow-up): dispatch into the playerStore once the
      // PDF reader's TTS UI is wired. Logging today proves the resolver
      // works end-to-end through the WebView bridge.
      console.log('[pdf-read-aloud-from] PLAY_FROM payload:', playFrom)
      Alert.alert(
        'Read aloud',
        `Will start at paragraph ${playFrom.paragraphIndex} (key ${playFrom.partialFirstKey})`
      )
      setSelection(null)
    } catch (e) {
      console.warn('[pdf-read-aloud-from] failed', e)
    }
  }, [selection])

  const handleBack = useCallback(() => {
    if (book?.id && pageNumber > 0) updateBookPage(book.id, pageNumber)
    router.back()
  }, [book?.id, pageNumber, router])

  // ---- Render ----
  if (loading) {
    return (
      <View style={styles.full}>
        <Text style={{ color: '#fff' }}>Loading book…</Text>
      </View>
    )
  }
  if (!book || !book.filePath) {
    return (
      <View style={styles.full}>
        <Text style={{ color: '#fff' }}>Book file not available</Text>
      </View>
    )
  }

  return (
    <View testID="pdf-reader" style={{ flex: 1, backgroundColor: '#000' }}>
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

      {/* Tap target on the page edges to toggle toolbar — keep the
          WebView touch handlers intact for selection / scrolling. */}
      <Pressable
        onPress={() => setToolbarVisible((v) => !v)}
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          height: 48,
          backgroundColor: 'transparent',
        }}
        accessibilityLabel="Toggle toolbar"
      />

      {/* Top toolbar */}
      {toolbarVisible ? (
        <SafeAreaView edges={['top']} style={styles.topbar}>
          <View style={styles.topbarInner}>
            <TouchableOpacity
              onPress={handleBack}
              hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
              style={styles.iconButton}
              accessibilityLabel="Back"
            >
              <IconSymbol name="chevron.left" size={24} color="#fff" />
            </TouchableOpacity>
            <Text numberOfLines={1} style={styles.title}>
              {book.title}
            </Text>
            <TouchableOpacity
              onPress={handleOpenOutline}
              style={styles.iconButton}
              accessibilityLabel="Open Table of Contents"
              disabled={outline.length === 0}
            >
              <IconSymbol
                name="list.bullet"
                size={22}
                color={outline.length === 0 ? '#666' : '#fff'}
              />
            </TouchableOpacity>
          </View>
        </SafeAreaView>
      ) : null}

      {/* Bottom navigation */}
      {toolbarVisible ? (
        <SafeAreaView edges={['bottom']} style={styles.bottombar}>
          <View style={styles.bottombarInner}>
            <TouchableOpacity
              onPress={() => {
                if (pageNumber > 1) readerRef.current?.goToPage(pageNumber - 1)
              }}
              disabled={pageNumber <= 1}
              style={[styles.iconButton, pageNumber <= 1 && { opacity: 0.3 }]}
            >
              <IconSymbol name="chevron.left" size={28} color="#fff" />
            </TouchableOpacity>

            <TouchableOpacity onPress={handleGoToPage}>
              <Text style={styles.pageIndicator}>
                {pageNumber || 1} / {pageCount || '?'}
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              onPress={() => {
                if (pageNumber < pageCount) readerRef.current?.goToPage(pageNumber + 1)
              }}
              disabled={pageNumber >= pageCount}
              style={[styles.iconButton, pageNumber >= pageCount && { opacity: 0.3 }]}
            >
              <IconSymbol name="chevron.right" size={28} color="#fff" />
            </TouchableOpacity>
          </View>
        </SafeAreaView>
      ) : null}

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
                accessibilityLabel={`Recolor highlight to ${c.name}`}
              />
            ))}
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
  topbar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    backgroundColor: 'rgba(0,0,0,0.7)',
  },
  topbarInner: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  bottombar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: 'rgba(0,0,0,0.7)',
  },
  bottombarInner: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 24,
    paddingVertical: 10,
  },
  iconButton: {
    width: 44,
    height: 44,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    flex: 1,
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
    textAlign: 'center',
    marginHorizontal: 8,
  },
  pageIndicator: { color: '#fff', fontSize: 16, fontWeight: '500' },
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
    minHeight: 32,
    paddingHorizontal: 8,
    justifyContent: 'center',
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
