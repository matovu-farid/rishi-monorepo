import React, { useCallback, useContext, useEffect, useState } from 'react'
import {
  Pressable,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
} from 'react-native-reanimated'
import { IconButton } from '@/components/ui/IconButton'
import { LockChip } from '@/components/auth/LockChip'
import { Toolbar } from '@/components/ui/Toolbar'
import { useTheme } from '@/lib/theme'
import { zIndex } from '@/lib/theme/tokens'
import { ReaderProgressPill, type ReaderProgress } from './ReaderProgressPill'
import { ReaderShellContext } from './ReaderShellContext'
import type { RealtimeStatus } from '@/lib/realtime/types'

// P1-L — viewports < 380pt (e.g. iPhone SE, mini, small Androids) cannot
// fit the full 9-icon row without truncation. Collapse the secondary
// icons (highlights, bookmarks list, search, appearance) into a "More"
// overflow menu below this breakpoint.
const OVERFLOW_BREAKPOINT_PT = 380

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
  /**
   * P1-T — when true, render a tiny lock chip next to the TTS, voice
   * (realtime), and AI-chat icons. Caller is expected to pass
   * `!isAuthenticated` from the authStore. The chip is purely visual;
   * the IconButton onPress still fires (which opens the premium gate
   * via `useRequireAuth`).
   */
  showLockChips?: boolean
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
  showLockChips = false,
  testID,
}: ReaderBottomBarProps): React.JSX.Element {
  const { colors, typography, motion, reduceMotion, spacing } = useTheme()
  const { width: viewportWidth } = useWindowDimensions()
  const opacity = useSharedValue(visible ? 1 : 0)
  const [moreOpen, setMoreOpen] = useState(false)

  // RDR-025 — bumps ReaderShell's touch-tick so the 3s auto-hide timer
  // restarts each time the user touches the bar. Wired to the wrapper's
  // `onTouchStart` below so it fires without consuming the press; the
  // IconButton children still receive their normal onPress callbacks.
  const { interact } = useContext(ReaderShellContext)
  const handleTouchStart = useCallback(() => {
    interact()
  }, [interact])

  useEffect(() => {
    opacity.value = withTiming(visible ? 1 : 0, {
      duration: reduceMotion ? 0 : motion.duration.fast,
    })
  }, [visible, opacity, motion.duration.fast, reduceMotion])

  // When the bar is hidden, the menu must close too — otherwise reopening
  // the chrome would re-expose the popover at a stale anchor.
  useEffect(() => {
    if (!visible) setMoreOpen(false)
  }, [visible])

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
  }))

  const subhead = typography.scale.subhead

  const realtimeActive =
    realtimeStatus != null && realtimeStatus !== 'idle'

  // P1-L — secondary actions collapse on narrow viewports.
  const narrow = viewportWidth < OVERFLOW_BREAKPOINT_PT
  const hasAnySecondary =
    onHighlightsPress != null ||
    onBookmarksPress != null ||
    onSearchPress != null ||
    onAppearancePress != null
  const showMoreButton = narrow && hasAnySecondary

  const closeMore = useCallback(() => setMoreOpen(false), [])
  const openMore = useCallback(() => setMoreOpen(true), [])

  const handleMenuItem = useCallback(
    (handler: (() => void) | undefined) => () => {
      closeMore()
      handler?.()
    },
    [closeMore],
  )

  return (
    <Animated.View
      pointerEvents={visible ? 'auto' : 'none'}
      testID={testID}
      // RDR-025 — onTouchStart restarts ReaderShell's auto-hide timer
      // without flipping visibility. The handler doesn't preventDefault
      // / stopPropagation so child IconButton presses still fire.
      onTouchStart={handleTouchStart}
      style={[
        {
          position: 'absolute',
          bottom: 0,
          left: 0,
          right: 0,
          // P1-M — shared token; toolbar must stay below overlayChrome (20).
          zIndex: zIndex.toolbar,
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
            {!narrow && onHighlightsPress ? (
              <IconButton
                name="pencil-outline"
                onPress={onHighlightsPress}
                label="Highlights"
                haptic="light"
              />
            ) : null}
            {!narrow && onBookmarksPress ? (
              <IconButton
                name="list-circle-outline"
                onPress={onBookmarksPress}
                label="Open bookmarks list"
                haptic="light"
              />
            ) : null}
            {!narrow && onAppearancePress ? (
              <IconButton
                name="text-outline"
                onPress={onAppearancePress}
                label="Appearance and font size"
                haptic="light"
              />
            ) : null}
            {!narrow && onSearchPress ? (
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
              <View style={styles.chipHost}>
                <IconButton
                  name="volume-high-outline"
                  onPress={onTTSPress}
                  label={ttsButtonActive ? 'Stop reading aloud' : 'Read aloud'}
                  color={ttsButtonActive ? colors.accent.primary : undefined}
                  haptic="light"
                />
                {showLockChips ? (
                  <View style={styles.chipOverlay} pointerEvents="none">
                    <LockChip testID="tts-lock-chip" />
                  </View>
                ) : null}
              </View>
            ) : null}
            {onRealtimePress ? (
              <View style={styles.chipHost}>
                <IconButton
                  name="mic-outline"
                  onPress={onRealtimePress}
                  label={realtimeActive ? 'End voice chat' : 'Start voice chat'}
                  color={realtimeActive ? colors.accent.primary : undefined}
                  haptic="light"
                />
                {showLockChips ? (
                  <View style={styles.chipOverlay} pointerEvents="none">
                    <LockChip testID="realtime-lock-chip" />
                  </View>
                ) : null}
              </View>
            ) : null}
            {onChatPress ? (
              <View style={styles.chipHost}>
                <IconButton
                  name="chatbubble-outline"
                  onPress={onChatPress}
                  label="Ask AI about this book"
                  haptic="light"
                />
                {showLockChips ? (
                  <View style={styles.chipOverlay} pointerEvents="none">
                    <LockChip testID="ai-chat-lock-chip" />
                  </View>
                ) : null}
              </View>
            ) : null}
            {showMoreButton ? (
              <IconButton
                name="ellipsis-horizontal"
                onPress={openMore}
                label="More reader actions"
                haptic="light"
                testID="reader-bottom-more"
              />
            ) : null}
          </View>
        }
      />
      {showMoreButton && moreOpen ? (
        <ReaderBottomMoreMenu
          testID="reader-bottom-more-sheet"
          onClose={closeMore}
          onHighlightsPress={
            onHighlightsPress ? handleMenuItem(onHighlightsPress) : undefined
          }
          onBookmarksPress={
            onBookmarksPress ? handleMenuItem(onBookmarksPress) : undefined
          }
          onSearchPress={
            onSearchPress ? handleMenuItem(onSearchPress) : undefined
          }
          onAppearancePress={
            onAppearancePress ? handleMenuItem(onAppearancePress) : undefined
          }
        />
      ) : null}
    </Animated.View>
  )
}

interface ReaderBottomMoreMenuProps {
  onClose: () => void
  onHighlightsPress?: () => void
  onBookmarksPress?: () => void
  onSearchPress?: () => void
  onAppearancePress?: () => void
  testID?: string
}

// P1-L — lightweight overflow menu rendered above the bottom bar on narrow
// viewports. We deliberately use plain RN primitives (Pressable + View)
// instead of the gorhom BottomSheet so the menu does not depend on a
// gesture-handler tree being present (and so it remains trivial to render
// in unit tests). The backdrop fills the screen and closes on press; the
// menu itself sits flush above the toolbar's right cluster.
function ReaderBottomMoreMenu({
  onClose,
  onHighlightsPress,
  onBookmarksPress,
  onSearchPress,
  onAppearancePress,
  testID,
}: ReaderBottomMoreMenuProps): React.JSX.Element {
  const { colors, spacing, typography } = useTheme()
  const body = typography.scale.body

  // A11Y-009 (#106) — every overflow item carries a consistent
  // role/label/hint triple. Hints describe the outcome of the action
  // so VoiceOver / TalkBack can announce "Highlights — opens the list
  // of highlights" instead of just "Highlights".
  const items: Array<{
    key: string
    label: string
    hint: string
    icon: 'pencil-outline' | 'list-circle-outline' | 'search-outline' | 'text-outline'
    onPress: () => void
  }> = []
  if (onHighlightsPress)
    items.push({
      key: 'highlights',
      label: 'Highlights',
      hint: 'Opens the list of saved highlights',
      icon: 'pencil-outline',
      onPress: onHighlightsPress,
    })
  if (onBookmarksPress)
    items.push({
      key: 'bookmarks',
      label: 'Bookmarks',
      hint: 'Opens the list of bookmarks',
      icon: 'list-circle-outline',
      onPress: onBookmarksPress,
    })
  if (onSearchPress)
    items.push({
      key: 'search',
      label: 'Search',
      hint: 'Opens search within the book',
      icon: 'search-outline',
      onPress: onSearchPress,
    })
  if (onAppearancePress)
    items.push({
      key: 'appearance',
      label: 'Appearance',
      hint: 'Opens appearance and font size settings',
      icon: 'text-outline',
      onPress: onAppearancePress,
    })

  return (
    <View
      testID={testID}
      accessibilityViewIsModal={true}
      style={styles.moreOverlay}
      pointerEvents="box-none"
    >
      <Pressable
        testID="reader-bottom-more-backdrop"
        accessibilityRole="button"
        accessibilityLabel="Dismiss menu"
        accessibilityHint="Closes the reader actions menu"
        onPress={onClose}
        style={styles.moreBackdrop}
      />
      <View
        accessibilityRole="menu"
        accessibilityViewIsModal={true}
        style={[
          styles.moreSheet,
          {
            backgroundColor: colors.background.secondary,
            paddingVertical: spacing.sm,
            marginHorizontal: spacing.lg,
            marginBottom: spacing.sm,
          },
        ]}
      >
        {items.map((item) => (
          <Pressable
            key={item.key}
            testID={`reader-bottom-more-item-${item.key}`}
            accessibilityRole="menuitem"
            accessibilityLabel={item.label}
            accessibilityHint={item.hint}
            onPress={item.onPress}
            style={({ pressed }) => [
              styles.moreItem,
              {
                paddingVertical: spacing.md,
                paddingHorizontal: spacing.lg,
                opacity: pressed ? 0.6 : 1,
              },
            ]}
          >
            <Text
              style={{
                fontSize: body.fontSize,
                lineHeight: body.lineHeight,
                fontWeight: body.fontWeight,
                color: colors.label.primary,
              }}
            >
              {item.label}
            </Text>
          </Pressable>
        ))}
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  cluster: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  // P1-T — chip host wraps an IconButton so the LockChip can sit
  // absolutely on its top-right corner without forcing a layout shift.
  chipHost: {
    position: 'relative',
  },
  chipOverlay: {
    position: 'absolute',
    top: -2,
    right: -2,
  },
  // P1-L — overflow menu styles. The overlay anchors the popover above
  // the toolbar without obscuring it, and the backdrop covers everything
  // else so taps outside dismiss the menu.
  moreOverlay: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: '100%',
    top: -9999,
    justifyContent: 'flex-end',
  },
  moreBackdrop: {
    ...StyleSheet.absoluteFillObject,
  },
  moreSheet: {
    borderRadius: 14,
    overflow: 'hidden',
  },
  moreItem: {
    flexDirection: 'row',
    alignItems: 'center',
  },
})
