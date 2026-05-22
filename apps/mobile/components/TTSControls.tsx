import { useContext } from 'react'
import { View, TouchableOpacity, ActivityIndicator } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated, { SlideInDown, SlideOutDown } from 'react-native-reanimated'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { usePlayerStore, type PlayerStoreState } from '@/lib/stores/playerStore'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { ReaderShellContext } from '@/components/reader/ReaderShell'

// Mirror ReaderShell's bottom bar inner-row min-height so the floating
// TTSControls clears it when the bar is visible.
const BOTTOM_BAR_HEIGHT = 44

/**
 * Floating bottom bar for TTS playback controls.
 *
 * Refactored in Batch 7 to read from `playerStore.playingState` (the
 * XState-driven authority) instead of the deprecated `useTTSPlayer` hook.
 * Buttons dispatch into `playerStore.send` — wired by `usePlayerMachine`.
 *
 * Active states (loading, playing, paused, etc.) determine button states
 * and the progress bar's "playing" indicator pulse. The progress bar tracks
 * `paragraphIndex / currentParagraphs.length` from the player context.
 */
export function TTSControls() {
  const insets = useSafeAreaInsets()
  const playingState = usePlayerStore((s) => s.playingState)
  const send = usePlayerStore((s) => s.send)
  const activeParagraph = usePlayerStore((s) => s.activeParagraph)
  const currentParagraphs = usePlayerStore((s) => s.currentParagraphs)

  const { bottomBarVisible } = useContext(ReaderShellContext)

  const requireTTS = useRequireAuth('tts')

  const isLoading = playingState === 'loading' || playingState === 'waitingForParagraphs' || playingState === 'pageNavigating'
  const isPlaying = playingState === 'playing'
  const isPaused = playingState.startsWith('paused')
  const isVisible = playingState !== 'idle'

  // Compute progress from store
  const total = currentParagraphs.length
  const currentIndex = activeParagraph
    ? Math.max(0, currentParagraphs.findIndex((p) => p.index === activeParagraph.index))
    : 0
  const progressPercent = total > 0 ? ((currentIndex + 1) / total) * 100 : 0

  if (!isVisible || !send) return null

  const handlePlay = () => {
    if (isPlaying) {
      send({ type: 'PAUSE' })
    } else if (isPaused) {
      send({ type: 'RESUME' })
    } else {
      // Initial play is the only branch that crosses the premium gate;
      // pause/resume on an in-flight session are free.
      requireTTS(() => send({ type: 'PLAY' }))
    }
  }

  const handleStop = () => send({ type: 'STOP' })
  const handleNext = () => send({ type: 'NEXT' })
  const handlePrev = () => send({ type: 'PREV' })

  return (
    <Animated.View
      entering={SlideInDown.duration(250)}
      exiting={SlideOutDown.duration(200)}
      style={{
        position: 'absolute',
        bottom:
          insets.bottom + 16 + (bottomBarVisible ? BOTTOM_BAR_HEIGHT : 0),
        left: 16,
        right: 16,
        height: 56,
        borderRadius: 16,
        backgroundColor: 'rgba(0,0,0,0.8)',
        overflow: 'hidden',
      }}
      accessibilityLabel={`Reading passage ${currentIndex + 1} of ${total}`}
    >
      {/* Controls row */}
      <View
        style={{
          flex: 1,
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'center',
          paddingHorizontal: 8,
        }}
      >
        {/* Previous */}
        <TouchableOpacity
          onPress={handlePrev}
          disabled={isLoading}
          style={{
            width: 44,
            height: 44,
            alignItems: 'center',
            justifyContent: 'center',
            opacity: isLoading ? 0.3 : 1,
          }}
          accessibilityLabel="Previous passage"
          accessibilityRole="button"
        >
          <IconSymbol name="backward.fill" size={22} color="#FFFFFF" />
        </TouchableOpacity>

        {/* Play/Pause */}
        <TouchableOpacity
          onPress={handlePlay}
          disabled={isLoading}
          style={{
            width: 44,
            height: 44,
            alignItems: 'center',
            justifyContent: 'center',
          }}
          accessibilityLabel={isPlaying ? 'Pause' : 'Play'}
          accessibilityRole="button"
        >
          {isLoading ? (
            <ActivityIndicator color="#FFFFFF" size={20} />
          ) : (
            <IconSymbol
              name={isPlaying ? 'pause.fill' : 'play.fill'}
              size={22}
              color="#FFFFFF"
            />
          )}
        </TouchableOpacity>

        {/* Next */}
        <TouchableOpacity
          onPress={handleNext}
          disabled={isLoading}
          style={{
            width: 44,
            height: 44,
            alignItems: 'center',
            justifyContent: 'center',
            opacity: isLoading ? 0.3 : 1,
          }}
          accessibilityLabel="Next passage"
          accessibilityRole="button"
        >
          <IconSymbol name="forward.fill" size={22} color="#FFFFFF" />
        </TouchableOpacity>

        {/* Stop */}
        <TouchableOpacity
          onPress={handleStop}
          style={{
            width: 44,
            height: 44,
            alignItems: 'center',
            justifyContent: 'center',
          }}
          accessibilityLabel="Stop reading"
          accessibilityRole="button"
        >
          <IconSymbol name="stop.fill" size={22} color="#FFFFFF" />
        </TouchableOpacity>
      </View>

      {/* Progress bar */}
      <View
        style={{
          height: 2,
          backgroundColor: 'rgba(255,255,255,0.2)',
        }}
      >
        <View
          style={{
            height: 2,
            width: `${progressPercent}%`,
            backgroundColor: '#0a7ea4',
          }}
        />
      </View>
    </Animated.View>
  )
}

// Re-export the PlayerStoreState type at the module level for legacy callers.
export type { PlayerStoreState }
