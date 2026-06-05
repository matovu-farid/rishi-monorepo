import React, { useCallback, useState } from 'react'
import { LayoutChangeEvent, StyleSheet, View } from 'react-native'
import Pdf from 'react-native-pdf'
import { HighlightOverlay, type HighlightShape } from './HighlightOverlay'

export interface OutlineNode {
  title: string
  pageIdx: number
  children?: OutlineNode[]
}

export interface PdfNativeReaderProps {
  bookId: string
  filePath: string
  initialPage?: number
  highlights?: HighlightShape[]
  onPageChanged?: (page: number, total: number) => void
  onOutline?: (outline: OutlineNode[]) => void
  onScaleChanged?: (scale: number) => void
  onHighlightTap?: (id: string) => void
  /** iOS-only: pass true (default) to enable native text selection in react-native-pdf */
  enableTextSelection?: boolean
  /** Called when the user selects text on iOS via react-native-pdf's onChange("textSelected|...") */
  onTextSelected?: (text: string) => void
}

export function PdfNativeReader({
  bookId,
  filePath,
  initialPage = 1,
  highlights = [],
  onPageChanged,
  onOutline,
  onScaleChanged,
  onHighlightTap,
  enableTextSelection = true,
  onTextSelected,
}: PdfNativeReaderProps) {
  const [page, setPage] = useState(initialPage)
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
    </View>
  )
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  pdf: { flex: 1 },
})
