import React, { useCallback, useState } from 'react'
import { StyleSheet, View } from 'react-native'
import Pdf from 'react-native-pdf'

export interface OutlineNode {
  title: string
  pageIdx: number
  children?: OutlineNode[]
}

export interface PdfNativeReaderProps {
  bookId: string
  filePath: string
  initialPage?: number
  onPageChanged?: (page: number, total: number) => void
  onOutline?: (outline: OutlineNode[]) => void
  onScaleChanged?: (scale: number) => void
}

export function PdfNativeReader({
  bookId,
  filePath,
  initialPage = 1,
  onPageChanged,
  onOutline,
  onScaleChanged,
}: PdfNativeReaderProps) {
  const [page, setPage] = useState(initialPage)

  const handleLoadComplete = useCallback(
    (
      _numPages: number,
      _path: string,
      _size: number[],
      tableContents?: OutlineNode[],
    ) => {
      if (tableContents && onOutline) onOutline(tableContents)
    },
    [onOutline],
  )

  return (
    <View style={styles.container}>
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
        onScaleChanged={(s) => onScaleChanged?.(s)}
        onLoadComplete={handleLoadComplete}
        style={styles.pdf}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  pdf: { flex: 1 },
})
