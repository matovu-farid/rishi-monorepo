import { View, TouchableOpacity, ActivityIndicator } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated, { SlideInDown, SlideOutDown } from 'react-native-reanimated'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface TTSControlsProps {
  status: 'loading' | 'playing' | 'paused'
  currentChunkIndex: number
  totalChunks: number
  onPlay: () => void
  onPause: () => void
  onStop: () => void
  onNext: () => void
  onPrevious: () => void
}

/**
 * Floating bottom bar for TTS playback controls.
 * Shows play/pause, previous, next, stop buttons and a chunk progress bar.
 */
export function TTSControls({
  status,
  currentChunkIndex,
  totalChunks,
  onPlay,
  onPause,
  onStop,
  onNext,
  onPrevious,
}: TTSControlsProps) {
  const insets = useSafeAreaInsets()
  const isLoading = status === 'loading'
  const isPlaying = status === 'playing'
  const progressPercent = totalChunks > 0 ? ((currentChunkIndex + 1) / totalChunks) * 100 : 0

  return (
    <Animated.View
      entering={SlideInDown.duration(250)}
      exiting={SlideOutDown.duration(200)}
      style={{
        position: 'absolute',
        bottom: insets.bottom + 16,
        left: 16,
        right: 16,
        height: 56,
        borderRadius: 16,
        backgroundColor: 'rgba(0,0,0,0.8)',
        overflow: 'hidden',
      }}
      accessibilityLabel={`Reading passage ${currentChunkIndex + 1} of ${totalChunks}`}
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
          onPress={onPrevious}
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
          onPress={isPlaying ? onPause : onPlay}
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
          onPress={onNext}
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
          onPress={onStop}
          disabled={isLoading}
          style={{
            width: 44,
            height: 44,
            alignItems: 'center',
            justifyContent: 'center',
            opacity: isLoading ? 0.3 : 1,
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
