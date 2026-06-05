import React, { useCallback, useState } from 'react'
import { StyleSheet, View } from 'react-native'
import {
  LongPressGestureHandler,
  PanGestureHandler,
  State,
} from 'react-native-gesture-handler'
import {
  pdfRectToScreen,
  screenPointToPdf,
  type PageSize,
  type Viewport,
} from './coord-transform'
import {
  findWordAtPdfPoint,
  wordsBetween,
  type WordRow,
} from '@/lib/pdf/word-hit-test'

export interface AndroidSelectionOverlayProps {
  pageSize: PageSize
  viewport: Viewport
  words: WordRow[]
  onTextSelected: (text: string) => void
}

export function AndroidSelectionOverlay({
  pageSize,
  viewport,
  words,
  onTextSelected,
}: AndroidSelectionOverlayProps) {
  const [anchor, setAnchor] = useState<WordRow | null>(null)
  const [cursor, setCursor] = useState<WordRow | null>(null)

  const handleLongPress = useCallback(
    (x: number, y: number) => {
      const pdfPoint = screenPointToPdf({ x, y }, pageSize, viewport)
      const hit = findWordAtPdfPoint(words, pdfPoint)
      if (hit) {
        setAnchor(hit)
        setCursor(hit)
      }
    },
    [pageSize, viewport, words],
  )

  const handlePan = useCallback(
    (x: number, y: number) => {
      if (!anchor) return
      const pdfPoint = screenPointToPdf({ x, y }, pageSize, viewport)
      const hit = findWordAtPdfPoint(words, pdfPoint)
      if (hit) setCursor(hit)
    },
    [anchor, pageSize, viewport, words],
  )

  const handlePanEnd = useCallback(() => {
    if (anchor && cursor) {
      const range = wordsBetween(words, anchor, cursor)
      const text = range.map((w) => w.text).join(' ')
      if (text.length > 0) onTextSelected(text)
    }
    setAnchor(null)
    setCursor(null)
  }, [anchor, cursor, words, onTextSelected])

  const selectionRects =
    anchor && cursor
      ? wordsBetween(words, anchor, cursor).map((w) =>
          pdfRectToScreen({ x: w.x, y: w.y, w: w.w, h: w.h }, pageSize, viewport),
        )
      : []

  return (
    <LongPressGestureHandler
      minDurationMs={350}
      testID="android-selection-gesture"
      onHandlerStateChange={(e: any) => {
        if (e.nativeEvent.state === State.ACTIVE) {
          handleLongPress(e.nativeEvent.x, e.nativeEvent.y)
        }
      }}
    >
      <PanGestureHandler
        onGestureEvent={(e: any) => handlePan(e.nativeEvent.x, e.nativeEvent.y)}
        onEnded={handlePanEnd}
        enabled={anchor !== null}
      >
        <View pointerEvents="box-none" style={StyleSheet.absoluteFill}>
          {selectionRects.map((r, i) => (
            <View
              key={i}
              testID="android-selection-rect"
              style={{
                position: 'absolute',
                left: r.left, top: r.top, width: r.width, height: r.height,
                backgroundColor: 'rgba(33, 150, 243, 0.30)',
              }}
            />
          ))}
        </View>
      </PanGestureHandler>
    </LongPressGestureHandler>
  )
}
