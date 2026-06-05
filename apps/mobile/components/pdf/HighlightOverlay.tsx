import React from 'react'
import { View, StyleSheet } from 'react-native'
import {
  pdfRectToScreen,
  type PageSize,
  type Viewport,
  type PdfRect,
} from './coord-transform'

export interface HighlightShape {
  id: string
  page: number
  color: 'yellow' | 'green' | 'blue' | 'pink'
  rects: PdfRect[]
}

const COLOR_RGBA: Record<HighlightShape['color'], string> = {
  yellow: 'rgba(255, 235, 59, 0.35)',
  green:  'rgba(76, 175, 80, 0.30)',
  blue:   'rgba(33, 150, 243, 0.30)',
  pink:   'rgba(233, 30, 99, 0.30)',
}

export interface HighlightOverlayProps {
  page: number
  pageSize: PageSize
  viewport: Viewport
  highlights: HighlightShape[]
  onHighlightTap?: (id: string) => void
}

export function HighlightOverlay({
  page,
  pageSize,
  viewport,
  highlights,
  onHighlightTap,
}: HighlightOverlayProps) {
  const onThisPage = highlights.filter((h) => h.page === page)
  if (onThisPage.length === 0) return null

  return (
    <View pointerEvents="box-none" style={StyleSheet.absoluteFill}>
      {onThisPage.flatMap((h) =>
        h.rects.map((r, i) => {
          const screen = pdfRectToScreen(r, pageSize, viewport)
          return (
            <View
              key={`${h.id}-${i}`}
              testID="highlight-rect"
              accessibilityRole="button"
              onTouchEnd={() => onHighlightTap?.(h.id)}
              style={{
                position: 'absolute',
                left: screen.left,
                top: screen.top,
                width: screen.width,
                height: screen.height,
                backgroundColor: COLOR_RGBA[h.color],
              }}
            />
          )
        }),
      )}
    </View>
  )
}
