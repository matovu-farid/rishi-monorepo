import React, { useState } from 'react'
import { View, Text, StyleSheet, type ViewStyle } from 'react-native'
import { Image } from 'expo-image'
import { useTheme, type RadiusKey } from '@/lib/theme'

export type BookCoverSize = 'sm' | 'md' | 'lg'
export type BookCoverElevation = 'flat' | 'low' | 'medium'

export type BookCoverProps = {
  uri?: string | null
  title: string
  size: BookCoverSize
  aspectRatio?: number
  rounded?: RadiusKey
  elevation?: BookCoverElevation
  style?: ViewStyle
  testID?: string
  /**
   * STA-021: when true AND `uri` is absent, render a dashed-border
   * placeholder instead of the hash-tinted letter tile. The library
   * "Reading Now" card and BookRow use this to distinguish "cover
   * extraction is deferred" (PDF/DJVU on import) from "the book truly
   * has no cover and we're falling back to a letter."
   *
   * Has no effect when a real `uri` is provided.
   */
  pending?: boolean
}

// UI-SPEC §7f size map. Height derives from aspectRatio (default 2/3 book ratio).
const SIZE_MAP: Record<BookCoverSize, number> = {
  sm: 48,
  md: 96,
  lg: 144,
}

// VIS-019: deterministic hash-based palette. The previous set clustered at
// L≈50 / chroma≈55 which made every letter tile read brown. Replaced with
// saturated "book-jacket" hues — covers the hue wheel at higher chroma so
// adjacent letter tiles on a shelf differentiate at a glance.
const FALLBACK_PALETTE = [
  '#C2185B', // crimson rose
  '#7B1FA2', // royal purple
  '#303F9F', // ink blue
  '#0288D1', // azure
  '#00796B', // teal
  '#388E3C', // forest green
  '#F57C00', // marmalade
  '#D32F2F', // brick red
]

function hashTitle(title: string): number {
  let sum = 0
  for (let i = 0; i < title.length; i++) sum += title.charCodeAt(i)
  return sum
}

function fallbackColor(title: string): string {
  return FALLBACK_PALETTE[hashTitle(title) % FALLBACK_PALETTE.length]
}

const LETTER_FONT_SIZE: Record<BookCoverSize, number> = {
  sm: 20,
  md: 36,
  lg: 56,
}

export function BookCover({
  uri,
  title,
  size,
  aspectRatio = 2 / 3,
  rounded = 'md',
  elevation = 'low',
  style,
  testID,
  pending = false,
}: BookCoverProps): React.JSX.Element {
  const { colors, radius, shadow } = useTheme()
  const [hasError, setHasError] = useState(false)
  const width = SIZE_MAP[size]
  const height = width / aspectRatio
  const borderRadius = radius[rounded]
  const elevationStyle = shadow[elevation]

  // STA-021: a real `uri` always wins (even with pending=true) so the
  // moment the cover lands the placeholder swaps out cleanly. Only fall
  // into pending when we have NO image and the caller signalled the
  // cover is still being prepared.
  const showImage = Boolean(uri) && !hasError
  const showPending = !showImage && pending
  const showFallback = !showImage && !showPending

  const accessibilityLabel = showPending
    ? `Preparing cover for ${title}`
    : `Cover of ${title}`

  return (
    <View
      accessibilityRole="image"
      accessibilityLabel={accessibilityLabel}
      testID={testID}
      style={[
        {
          width,
          height,
          borderRadius,
          // VIS-008: only draw a hairline around the letter-tile fallback.
          // Apple Books lets real cover artwork float on the shadow alone.
          // STA-021: the pending placeholder swaps to a 1pt dashed border
          // so the "cover hasn't loaded yet" cue is distinct from the
          // solid-hairline letter tile.
          borderWidth: showPending
            ? 1
            : showFallback
              ? StyleSheet.hairlineWidth
              : 0,
          borderStyle: showPending ? 'dashed' : 'solid',
          borderColor: colors.separator.nonOpaque,
          overflow: 'hidden',
          backgroundColor: showFallback
            ? fallbackColor(title)
            : showPending
              ? colors.fill.tertiary
              : undefined,
          alignItems: 'center',
          justifyContent: 'center',
        },
        elevationStyle,
        style,
      ]}
    >
      {showImage ? (
        <Image
          source={{ uri: uri ?? undefined }}
          style={{ width, height, borderRadius }}
          contentFit="cover"
          onError={() => setHasError(true)}
        />
      ) : showPending ? (
        // No glyph — the dashed border + tinted surface is the cue. We
        // mark the node with a testID so callers/tests can assert on the
        // pending branch without colour matching.
        <View
          testID="book-cover-pending"
          style={{ width, height }}
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
        />
      ) : (
        <Text
          style={{
            color: '#FFFFFF',
            fontSize: LETTER_FONT_SIZE[size],
            fontWeight: '600',
          }}
        >
          {title.charAt(0).toUpperCase()}
        </Text>
      )}
    </View>
  )
}
