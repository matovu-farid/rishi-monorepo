import React, { useEffect } from 'react'
import { Text, View, StyleSheet } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
} from 'react-native-reanimated'
import { IconButton } from '@/components/ui/IconButton'
import { Toolbar } from '@/components/ui/Toolbar'
import { useTheme } from '@/lib/theme'
import { ReaderProgressPill, type ReaderProgress } from './ReaderProgressPill'
import type { RealtimeStatus } from '@/lib/realtime/types'

export interface ReaderBottomBarProps {
  visible: boolean
  progress: ReaderProgress
  centerOverride?: React.ReactNode
  chapterLabel?: string
  onTocPress?: () => void
  onHighlightsPress?: () => void
  onBookmarksPress?: () => void
  onSearchPress?: () => void
  onAppearancePress?: () => void
  onBookmarkTogglePress?: () => void
  isBookmarked?: boolean
  onTTSPress?: () => void
  ttsButtonActive?: boolean
  onRealtimePress?: () => void
  realtimeStatus?: RealtimeStatus
  onChatPress?: () => void
  testID?: string
}

export function ReaderBottomBar({
  visible,
  progress,
  centerOverride,
  chapterLabel,
  onTocPress,
  onHighlightsPress,
  onBookmarksPress,
  onSearchPress,
  onAppearancePress,
  onBookmarkTogglePress,
  isBookmarked,
  onTTSPress,
  ttsButtonActive,
  onRealtimePress,
  realtimeStatus,
  onChatPress,
  testID,
}: ReaderBottomBarProps): React.JSX.Element {
  const { colors, typography, motion, reduceMotion, spacing } = useTheme()
  const opacity = useSharedValue(visible ? 1 : 0)

  useEffect(() => {
    opacity.value = withTiming(visible ? 1 : 0, {
      duration: reduceMotion ? 0 : motion.duration.fast,
    })
  }, [visible, opacity, motion.duration.fast, reduceMotion])

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
  }))

  const subhead = typography.scale.subhead

  const realtimeActive =
    realtimeStatus != null && realtimeStatus !== 'idle'

  return (
    <Animated.View
      pointerEvents={visible ? 'auto' : 'none'}
      testID={testID}
      style={[
        {
          position: 'absolute',
          bottom: 0,
          left: 0,
          right: 0,
          zIndex: 10,
        },
        animatedStyle,
      ]}
    >
      <Toolbar
        position="bottom"
        blur
        transparent
        hairline
        left={
          chapterLabel ? (
            <Text
              numberOfLines={1}
              style={{
                fontSize: subhead.fontSize,
                lineHeight: subhead.lineHeight,
                fontWeight: subhead.fontWeight,
                color: colors.label.secondary,
                maxWidth: 120,
              }}
            >
              {chapterLabel}
            </Text>
          ) : null
        }
        center={centerOverride ?? <ReaderProgressPill progress={progress} />}
        right={
          <View style={[styles.cluster, { gap: spacing.sm }]}>
            {onTocPress ? (
              <IconButton
                name="list-outline"
                onPress={onTocPress}
                label="Table of contents"
                haptic="light"
              />
            ) : null}
            {onHighlightsPress ? (
              <IconButton
                name="pencil-outline"
                onPress={onHighlightsPress}
                label="Highlights"
                haptic="light"
              />
            ) : null}
            {onBookmarksPress ? (
              <IconButton
                name="list-circle-outline"
                onPress={onBookmarksPress}
                label="Open bookmarks list"
                haptic="light"
              />
            ) : null}
            {onAppearancePress ? (
              <IconButton
                name="text-outline"
                onPress={onAppearancePress}
                label="Appearance and font size"
                haptic="light"
              />
            ) : null}
            {onSearchPress ? (
              <IconButton
                name="search-outline"
                onPress={onSearchPress}
                label="Search the book"
                haptic="light"
              />
            ) : null}
            {onBookmarkTogglePress ? (
              <IconButton
                name={isBookmarked ? 'bookmark' : 'bookmark-outline'}
                onPress={onBookmarkTogglePress}
                label={isBookmarked ? 'Remove bookmark' : 'Add bookmark'}
                color={isBookmarked ? colors.accent.error : undefined}
                haptic="light"
              />
            ) : null}
            {onTTSPress ? (
              <IconButton
                name="volume-high-outline"
                onPress={onTTSPress}
                label={ttsButtonActive ? 'Stop reading aloud' : 'Read aloud'}
                color={ttsButtonActive ? colors.accent.primary : undefined}
                haptic="light"
              />
            ) : null}
            {onRealtimePress ? (
              <IconButton
                name="mic-outline"
                onPress={onRealtimePress}
                label={realtimeActive ? 'End voice chat' : 'Start voice chat'}
                color={realtimeActive ? colors.accent.primary : undefined}
                haptic="light"
              />
            ) : null}
            {onChatPress ? (
              <IconButton
                name="chatbubble-outline"
                onPress={onChatPress}
                label="Ask AI about this book"
                haptic="light"
              />
            ) : null}
          </View>
        }
      />
    </Animated.View>
  )
}

const styles = StyleSheet.create({
  cluster: {
    flexDirection: 'row',
    alignItems: 'center',
  },
})
