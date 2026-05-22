import React, {
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react'
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  View,
  useColorScheme,
  useWindowDimensions,
} from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated, {
  Extrapolation,
  cancelAnimation,
  interpolate,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'

import { GlassDisk } from '@/components/ui/GlassDisk'
import { ReaderShellContext } from '@/components/reader/ReaderShell'
import { useTheme } from '@/lib/theme'
import { usePlayerStore } from '@/lib/stores/playerStore'

export interface MiniPlayerProps {
  bookId?: string
  variant?: 'reader' | 'global'
  tabBarHeight?: number
  testID?: string
}

const ORB_SIZE = 52
const PILL_HEIGHT = 66
const PILL_RADIUS = 40
const ORB_RADIUS = 26
const PILL_WIDTH_NO_REPEAT = 240
const PILL_WIDTH_WITH_REPEAT = 280
const BAR_HEIGHTS = [8, 14, 20, 12] as const
const AUTO_COLLAPSE_MS = 4000
const BOTTOM_BAR_HEIGHT = 44

function PillIconButton({
  iconName,
  onPress,
  label,
  loading,
  testID,
  color,
}: {
  iconName: React.ComponentProps<typeof Ionicons>['name']
  onPress: () => void
  label: string
  loading?: boolean
  testID?: string
  color: string
}): React.JSX.Element {
  return (
    <Pressable
      onPress={onPress}
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      hitSlop={6}
      style={{
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      {loading ? (
        <ActivityIndicator size="small" color={color} />
      ) : (
        <Ionicons name={iconName} size={22} color={color} />
      )}
    </Pressable>
  )
}

export function MiniPlayer({
  bookId: _bookId,
  variant = 'reader',
  tabBarHeight,
  testID,
}: MiniPlayerProps): React.JSX.Element | null {
  const insets = useSafeAreaInsets()
  const { width: screenWidth } = useWindowDimensions()
  const { motion, reduceMotion } = useTheme()
  const scheme = useColorScheme() ?? 'light'

  const playingState = usePlayerStore((s) => s.playingState)
  const send = usePlayerStore((s) => s.send)
  const repeatMode = usePlayerStore((s) => s.repeatMode)

  const shellContext = useContext(ReaderShellContext)
  const bottomBarVisible = shellContext?.bottomBarVisible ?? false

  const [expanded, setExpanded] = useState(false)
  const collapseTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const expandedValue = useSharedValue(0)
  const bar0Scale = useSharedValue(1)
  const bar1Scale = useSharedValue(1)
  const bar2Scale = useSharedValue(1)
  const bar3Scale = useSharedValue(1)
  const bar0Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar0Scale.value }],
  }))
  const bar1Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar1Scale.value }],
  }))
  const bar2Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar2Scale.value }],
  }))
  const bar3Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar3Scale.value }],
  }))

  const isPlaying = playingState === 'playing'
  const isPaused =
    playingState === 'paused.clean' || playingState === 'paused.stale'
  const isLoading =
    playingState === 'loading' ||
    playingState === 'waitingForParagraphs' ||
    playingState === 'pageNavigating'

  const resolvedTabBarHeight =
    variant === 'global' ? (tabBarHeight ?? 49) : 0
  const bottomOffset =
    variant === 'reader'
      ? insets.bottom +
        16 +
        (expanded ? 0 : bottomBarVisible ? BOTTOM_BAR_HEIGHT : 0)
      : insets.bottom + 16 + resolvedTabBarHeight

  const pillWidth =
    repeatMode !== 'off' ? PILL_WIDTH_WITH_REPEAT : PILL_WIDTH_NO_REPEAT

  // Morph: width + translateX so the pill ends centered on screen while the
  // orb remains anchored at right:16. Animating right/left would thrash
  // layout; transform keeps it on the UI thread.
  const containerStyle = useAnimatedStyle(() => {
    const w = interpolate(
      expandedValue.value,
      [0, 1],
      [ORB_SIZE, pillWidth],
      Extrapolation.CLAMP,
    )
    const h = interpolate(
      expandedValue.value,
      [0, 1],
      [ORB_SIZE, PILL_HEIGHT],
      Extrapolation.CLAMP,
    )
    const r = interpolate(
      expandedValue.value,
      [0, 1],
      [ORB_RADIUS, PILL_RADIUS],
      Extrapolation.CLAMP,
    )
    const tx = interpolate(
      expandedValue.value,
      [0, 1],
      [0, -(screenWidth / 2 - 16 - pillWidth / 2)],
      Extrapolation.CLAMP,
    )
    return {
      width: w,
      height: h,
      borderRadius: r,
      transform: [{ translateX: tx }],
    }
  })

  const orbFadeStyle = useAnimatedStyle(() => ({
    opacity: 1 - expandedValue.value,
  }))
  const pillFadeStyle = useAnimatedStyle(() => ({
    opacity: expandedValue.value,
  }))

  useEffect(() => {
    if (reduceMotion) {
      expandedValue.value = withTiming(expanded ? 1 : 0, {
        duration: motion.duration.fast,
      })
    } else {
      expandedValue.value = withSpring(expanded ? 1 : 0, motion.spring.snappy)
    }
  }, [expanded, reduceMotion, expandedValue, motion])

  // Bar animation while playing. Half-period 150ms, stagger 100ms — slower
  // than AIChatOrb so it reads as "audio playback" not "thinking AI".
  useEffect(() => {
    const bars = [bar0Scale, bar1Scale, bar2Scale, bar3Scale]
    bars.forEach((b) => cancelAnimation(b))
    if (!isPlaying || reduceMotion) {
      bars.forEach((b) => {
        b.value = withTiming(1, { duration: 150 })
      })
      return
    }
    const halfPeriod = 150
    const stagger = 100
    bars.forEach((b, i) => {
      b.value = withDelay(
        i * stagger,
        withRepeat(
          withSequence(
            withTiming(0.5, { duration: halfPeriod }),
            withTiming(1, { duration: halfPeriod }),
          ),
          -1,
          true,
        ),
      )
    })
  }, [isPlaying, reduceMotion, bar0Scale, bar1Scale, bar2Scale, bar3Scale])

  // Auto-collapse when expanded but not actively playing. Active playback
  // suppresses the timer so a user pinning the pill open mid-paragraph
  // doesn't lose it.
  useEffect(() => {
    if (collapseTimerRef.current) {
      clearTimeout(collapseTimerRef.current)
      collapseTimerRef.current = null
    }
    if (expanded && !isPlaying) {
      collapseTimerRef.current = setTimeout(() => {
        setExpanded(false)
      }, AUTO_COLLAPSE_MS)
    }
    return () => {
      if (collapseTimerRef.current) {
        clearTimeout(collapseTimerRef.current)
        collapseTimerRef.current = null
      }
    }
  }, [expanded, isPlaying])

  const handleExpand = useCallback(() => {
    if (!reduceMotion) {
      void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)
    }
    setExpanded(true)
  }, [reduceMotion])

  const bumpCollapse = useCallback(() => {
    if (collapseTimerRef.current) {
      clearTimeout(collapseTimerRef.current)
      collapseTimerRef.current = null
    }
    if (expanded && !isPlaying) {
      collapseTimerRef.current = setTimeout(() => {
        setExpanded(false)
      }, AUTO_COLLAPSE_MS)
    }
  }, [expanded, isPlaying])

  const dispatch = useCallback(
    (event: { type: 'PAUSE' | 'RESUME' | 'STOP' | 'NEXT' | 'PREV' | 'REPEAT' }) => {
      if (!reduceMotion) {
        void Haptics.selectionAsync()
      }
      send?.(event)
      bumpCollapse()
    },
    [send, reduceMotion, bumpCollapse],
  )

  const handlePlayPause = useCallback(() => {
    if (isPlaying) {
      dispatch({ type: 'PAUSE' })
    } else if (isPaused) {
      dispatch({ type: 'RESUME' })
    }
  }, [isPlaying, isPaused, dispatch])

  if (playingState === 'idle' || !send) return null

  const iconColor = scheme === 'dark' ? '#FFFFFF' : '#1C1C1E'
  const barColor =
    scheme === 'dark' ? 'rgba(255,255,255,0.50)' : 'rgba(0,0,0,0.50)'

  return (
    <Animated.View
      testID={testID ?? 'mini-player'}
      style={[
        {
          position: 'absolute',
          bottom: bottomOffset,
          right: 16,
          zIndex: 20,
          overflow: 'hidden',
        },
        containerStyle,
      ]}
    >
      <GlassDisk size={ORB_SIZE} style={{ position: 'absolute', top: 0, left: 0 }}>
        <View style={StyleSheet.absoluteFill} />
      </GlassDisk>

      {/* Orb face (collapsed) — Pressable that expands on tap. */}
      <Animated.View
        style={[
          {
            position: 'absolute',
            top: 0,
            left: 0,
            width: ORB_SIZE,
            height: ORB_SIZE,
            alignItems: 'center',
            justifyContent: 'center',
          },
          orbFadeStyle,
        ]}
        pointerEvents={expanded ? 'none' : 'auto'}
      >
        <Pressable
          testID="mini-player-orb"
          onPress={handleExpand}
          accessibilityRole="button"
          accessibilityLabel={
            isPlaying ? 'Audio playing — tap to expand' : 'Audio paused — tap to expand'
          }
          accessibilityHint="Open the playback controls"
          style={{
            width: ORB_SIZE,
            height: ORB_SIZE,
            alignItems: 'center',
            justifyContent: 'center',
            flexDirection: 'row',
            gap: 3,
          }}
        >
          {[bar0Style, bar1Style, bar2Style, bar3Style].map((barStyle, i) => (
            <Animated.View
              key={i}
              style={[
                {
                  width: 3,
                  height: BAR_HEIGHTS[i],
                  borderRadius: 1.5,
                  backgroundColor: barColor,
                },
                barStyle,
              ]}
            />
          ))}
        </Pressable>
      </Animated.View>

      {/* Pill face (expanded) — controls row. */}
      {expanded ? (
        <Animated.View
          testID="mini-player-pill"
          style={[
            {
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'space-evenly',
              paddingHorizontal: 12,
              gap: 8,
            },
            pillFadeStyle,
          ]}
          pointerEvents="auto"
        >
          <PillIconButton
            iconName="play-skip-back"
            label="Previous paragraph"
            color={iconColor}
            testID="mini-player-prev"
            onPress={() => dispatch({ type: 'PREV' })}
          />
          <PillIconButton
            iconName={isPlaying ? 'pause' : 'play'}
            label={isPlaying ? 'Pause' : 'Play'}
            color={iconColor}
            loading={isLoading}
            testID="mini-player-play-pause"
            onPress={handlePlayPause}
          />
          {repeatMode !== 'off' ? (
            <PillIconButton
              iconName="repeat"
              label="Repeat paragraph"
              color={iconColor}
              testID="mini-player-repeat"
              onPress={() => dispatch({ type: 'REPEAT' })}
            />
          ) : null}
          <PillIconButton
            iconName="play-skip-forward"
            label="Next paragraph"
            color={iconColor}
            testID="mini-player-next"
            onPress={() => dispatch({ type: 'NEXT' })}
          />
          <PillIconButton
            iconName="stop"
            label="Stop playback"
            color={iconColor}
            testID="mini-player-stop"
            onPress={() => dispatch({ type: 'STOP' })}
          />
        </Animated.View>
      ) : null}
    </Animated.View>
  )
}

