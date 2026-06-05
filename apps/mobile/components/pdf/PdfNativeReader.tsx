import React, { useCallback, useEffect, useState } from 'react'
import { LayoutChangeEvent, Platform, StyleSheet, View } from 'react-native'
import Pdf from 'react-native-pdf'
import { HighlightOverlay, type HighlightShape } from './HighlightOverlay'
import { AndroidSelectionOverlay } from './AndroidSelectionOverlay'
import type { WordRow } from '@/lib/pdf/word-hit-test'

export interface OutlineNode {
  title: string
  pageIdx: number
  children?: OutlineNode[]
}

export interface PdfNativeReaderProps {
  bookId: string
  filePath: string
  initialPage?: number
  /**
   * Controlled page number. When provided and different from the
   * reader's internal page state, the reader navigates to this page.
   * Useful for programmatic navigation (outline taps, go-to-page, etc.)
   */
  page?: number
  highlights?: HighlightShape[]
  onPageChanged?: (page: number, total: number) => void
  onOutline?: (outline: OutlineNode[]) => void
  onScaleChanged?: (scale: number) => void
  onHighlightTap?: (id: string) => void
  /** iOS-only: pass true (default) to enable native text selection in react-native-pdf */
  enableTextSelection?: boolean
  /** Called when the user selects text on iOS via react-native-pdf's onChange("textSelected|...") */
  onTextSelected?: (text: string) => void
  /** Android-only: word rects for the current page, used by the gesture selection overlay */
  words?: WordRow[]
}

export function PdfNativeReader({
  bookId,
  filePath,
  initialPage = 1,
  page: controlledPage,
  highlights = [],
  onPageChanged,
  onOutline,
  onScaleChanged,
  onHighlightTap,
  enableTextSelection = true,
  onTextSelected,
  words,
}: PdfNativeReaderProps) {
  const [page, setPage] = useState(initialPage)

  // When `controlledPage` changes (e.g. from outline tap or go-to-page),
  // sync internal page state so react-native-pdf navigates there.
  useEffect(() => {
    if (controlledPage != null && controlledPage !== page && controlledPage >= 1) {
      setPage(controlledPage)
    }
    // We intentionally exclude `page` from deps — we only want to fire
    // when the *caller* changes their target, not when the user flips
    // pages natively. The stale-closure risk is acceptable here because
    // `controlledPage` is always the source of truth for external nav.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [controlledPage])
  const [scale, setScale] = useState(1)
  const [pageSize, setPageSize] = useState({ widthPts: 612, heightPts: 792 })
  const [viewport, setViewport] = useState({ widthPx: 1, heightPx: 1 })

  const handleLoadComplete = useCallback(
    (
      _numPages: number,
      _path: string,
      size: number[],
      tableContents?: OutlineNode[],
    ) => {
      if (size && size.length >= 2) {
        setPageSize({ widthPts: size[0], heightPts: size[1] })
      }
      if (tableContents && onOutline) onOutline(tableContents)
    },
    [onOutline],
  )

  const handleLayout = useCallback((e: LayoutChangeEvent) => {
    setViewport({
      widthPx: e.nativeEvent.layout.width,
      heightPx: e.nativeEvent.layout.height,
    })
  }, [])

  const handleNativeChange = useCallback(
    (payload: string) => {
      if (!payload || typeof payload !== 'string') return
      if (payload.startsWith('textSelected|')) {
        const text = payload.slice('textSelected|'.length)
        onTextSelected?.(text)
      }
    },
    [onTextSelected],
  )

  return (
    <View style={styles.container} onLayout={handleLayout}>
      <Pdf
        source={{ uri: filePath }}
        horizontal
        enablePaging
        enableDoubleTapZoom
        page={page}
        onPageChanged={(p, total) => {
          setPage(p)
          onPageChanged?.(p, total)
        }}
        onScaleChanged={(s) => {
          setScale(s)
          onScaleChanged?.(s)
        }}
        onLoadComplete={handleLoadComplete}
        enableTextSelection={enableTextSelection}
        onChange={handleNativeChange}
        style={styles.pdf}
      />
      <HighlightOverlay
        page={page}
        pageSize={pageSize}
        viewport={{ widthPx: viewport.widthPx, heightPx: viewport.heightPx, scale }}
        highlights={highlights}
        onHighlightTap={onHighlightTap}
      />
      {Platform.OS === 'android' && words && words.length > 0 && (
        <AndroidSelectionOverlay
          pageSize={pageSize}
          viewport={{ widthPx: viewport.widthPx, heightPx: viewport.heightPx, scale }}
          words={words}
          onTextSelected={(text) => onTextSelected?.(text)}
        />
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  pdf: { flex: 1 },
})
