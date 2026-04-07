import { useEffect } from 'react'
import { TouchableOpacity, ActivityIndicator } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withRepeat,
  withTiming,
  cancelAnimation,
} from 'react-native-reanimated'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { RealtimeStatus } from '@/lib/realtime/types'

const AnimatedTouchable = Animated.createAnimatedComponent(TouchableOpacity)

interface RealtimeVoiceButtonProps {
  status: RealtimeStatus
  onPress: () => void
}

export function RealtimeVoiceButton({ status, onPress }: RealtimeVoiceButtonProps) {
  const pulseOpacity = useSharedValue(1)
  const scale = useSharedValue(1)

  useEffect(() => {
    if (status === 'active') {
      pulseOpacity.value = withRepeat(
        withTiming(0.6, { duration: 800 }),
        -1,
        true
      )
      cancelAnimation(scale)
      scale.value = withTiming(1, { duration: 200 })
    } else if (status === 'speaking') {
      cancelAnimation(pulseOpacity)
      pulseOpacity.value = withTiming(1, { duration: 200 })
      scale.value = withRepeat(
        withTiming(1.1, { duration: 600 }),
        -1,
        true
      )
    } else {
      cancelAnimation(pulseOpacity)
      cancelAnimation(scale)
      pulseOpacity.value = withTiming(1, { duration: 200 })
      scale.value = withTiming(1, { duration: 200 })
    }
  }, [status, pulseOpacity, scale])

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: pulseOpacity.value,
    transform: [{ scale: scale.value }],
  }))

  const isDisabled = status === 'connecting' || status === 'ending'

  const accessibilityLabel =
    status === 'idle'
      ? 'Start voice conversation'
      : status === 'connecting'
        ? 'Connecting'
        : status === 'active'
          ? 'Voice conversation active, tap to end'
          : status === 'speaking'
            ? 'AI is speaking, tap to end'
            : 'Ending conversation'

  if (status === 'connecting' || status === 'ending') {
    return (
      <AnimatedTouchable
        onPress={onPress}
        disabled
        className="w-11 h-11 items-center justify-center"
        style={animatedStyle}
        accessibilityLabel={accessibilityLabel}
        accessibilityRole="button"
        accessibilityState={{ disabled: true }}
      >
        <ActivityIndicator
          color={status === 'connecting' ? '#0a7ea4' : '#9BA1A6'}
          size={18}
        />
      </AnimatedTouchable>
    )
  }

  return (
    <AnimatedTouchable
      onPress={onPress}
      disabled={isDisabled}
      className="w-11 h-11 items-center justify-center"
      style={animatedStyle}
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
    >
      {status === 'idle' ? (
        <IconSymbol name="phone.fill" size={22} color="#9BA1A6" />
      ) : (
        <IconSymbol name="waveform" size={22} color="#0a7ea4" />
      )}
    </AnimatedTouchable>
  )
}
