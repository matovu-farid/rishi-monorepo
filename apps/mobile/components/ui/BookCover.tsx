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
  /**
   * #96 / STA-021 — when true, render a dashed-border placeholder
   * (distinct from the deterministic letter-tile fallback) so the user
   * knows the cover is still being fetched / extracted. Caller must
   * set this to `true` only while the cover is genuinely pending —
   * once extraction has resolved (success OR genuine failure), pass
   * `loading={false}` so the image OR the letter tile takes over.
   */
  loading?: boolean
  style?: ViewStyle
  testID?: string
}

// UI-SPEC §7f size map. Height derives from aspectRatio (default 2/3 book ratio).
const SIZE_MAP: Record<BookCoverSize, number> = {
  sm: 48,
  md: 96,
  lg: 144,
}

// Deterministic hash-based palette. Muted tones that work in both light & dark.
const FALLBACK_PALETTE = [
  '#8B7355',
  '#5B8B6B',
  '#6B7B8B',
  '#8B6B7B',
  '#7B8B5B',
  '#6B5B8B',
  '#8B7B5B',
  '#5B6B8B',
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
  loading = false,
  style,
  testID,
}: BookCoverProps): React.JSX.Element {
  const { colors, radius, shadow } = useTheme()
  const [hasError, setHasError] = useState(false)
  const width = SIZE_MAP[size]
  const height = width / aspectRatio
  const borderRadius = radius[rounded]
  const elevationStyle = shadow[elevation]

  // #96 / STA-021 — loading wins over both the real image and the
  // letter tile so the caller can always force a "pending" signal
  // (e.g. while cover extraction is still in flight for a deferred
  // book). It collapses to false once the caller flips it off.
  const showLoading = loading
  const showFallback = !showLoading && (!uri || hasError)
  const showImage = !showLoading && !showFallback

  const accessibilityLabel = showLoading
    ? `Cover of ${title} loading`
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
          // STA-021: the loading placeholder draws a dashed border (see
          // the inner `book-cover-loading` View below) — the outer
          // wrapper stays borderless so the dashed line reads as the
          // primary "pending" affordance.
          borderWidth: showFallback ? StyleSheet.hairlineWidth : 0,
          borderColor: colors.separator.nonOpaque,
          overflow: 'hidden',
          backgroundColor: showFallback ? fallbackColor(title) : undefined,
          alignItems: 'center',
          justifyContent: 'center',
        },
        elevationStyle,
        style,
      ]}
    >
      {showLoading ? (
        <View
          testID="book-cover-loading"
          accessible={false}
          style={{
            width: '100%',
            height: '100%',
            borderRadius,
            borderWidth: 1.5,
            borderStyle: 'dashed',
            borderColor: colors.separator.opaque,
            backgroundColor: colors.fill.quaternary,
          }}
        />
      ) : showFallback ? (
        <Text
          style={{
            color: '#FFFFFF',
            fontSize: LETTER_FONT_SIZE[size],
            fontWeight: '600',
          }}
        >
          {title.charAt(0).toUpperCase()}
        </Text>
      ) : showImage ? (
        <Image
          source={{ uri: uri ?? undefined }}
          style={{ width, height, borderRadius }}
          contentFit="cover"
          onError={() => setHasError(true)}
        />
      ) : null}
    </View>
  )
}
