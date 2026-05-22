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
  style,
  testID,
}: BookCoverProps): React.JSX.Element {
  const { colors, radius, shadow } = useTheme()
  const [hasError, setHasError] = useState(false)
  const width = SIZE_MAP[size]
  const height = width / aspectRatio
  const borderRadius = radius[rounded]
  const elevationStyle = shadow[elevation]

  const showFallback = !uri || hasError

  return (
    <View
      accessibilityRole="image"
      accessibilityLabel={`Cover of ${title}`}
      testID={testID}
      style={[
        {
          width,
          height,
          borderRadius,
          // VIS-008: only draw a hairline around the letter-tile fallback.
          // Apple Books lets real cover artwork float on the shadow alone.
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
      {showFallback ? (
        <Text
          style={{
            color: '#FFFFFF',
            fontSize: LETTER_FONT_SIZE[size],
            fontWeight: '600',
          }}
        >
          {title.charAt(0).toUpperCase()}
        </Text>
      ) : (
        <Image
          source={{ uri: uri ?? undefined }}
          style={{ width, height, borderRadius }}
          contentFit="cover"
          onError={() => setHasError(true)}
        />
      )}
    </View>
  )
}
