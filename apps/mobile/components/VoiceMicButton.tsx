import { useEffect } from 'react'
import { ActivityIndicator, TouchableOpacity } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withRepeat,
  withTiming,
} from 'react-native-reanimated'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface VoiceMicButtonProps {
  isRecording: boolean
  isTranscribing: boolean
  disabled: boolean
  onPress: () => void
}

const AnimatedTouchable = Animated.createAnimatedComponent(TouchableOpacity)

export function VoiceMicButton({
  isRecording,
  isTranscribing,
  disabled,
  onPress,
}: VoiceMicButtonProps) {
  const pulseOpacity = useSharedValue(1)

  useEffect(() => {
    if (isRecording) {
      pulseOpacity.value = withRepeat(
        withTiming(0.6, { duration: 800 }),
        -1,
        true
      )
    } else {
      pulseOpacity.value = withTiming(1, { duration: 200 })
    }
  }, [isRecording, pulseOpacity])

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: isRecording ? pulseOpacity.value : disabled ? 0.5 : 1,
  }))

  const bgClass = isTranscribing
    ? 'bg-[#0a7ea4]'
    : isRecording
      ? 'bg-red-500'
      : 'bg-gray-200 dark:bg-gray-700'

  const accessibilityLabel = isTranscribing
    ? 'Transcribing'
    : isRecording
      ? 'Stop recording'
      : 'Start voice input'

  return (
    <AnimatedTouchable
      onPress={onPress}
      disabled={disabled || isTranscribing}
      className={`w-10 h-10 rounded-full items-center justify-center ${bgClass}`}
      style={animatedStyle}
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
    >
      {isTranscribing ? (
        <ActivityIndicator color="#FFFFFF" size={16} />
      ) : (
        <IconSymbol
          name="mic.fill"
          size={20}
          color={isRecording ? '#FFFFFF' : '#9BA1A6'}
        />
      )}
    </AnimatedTouchable>
  )
}
