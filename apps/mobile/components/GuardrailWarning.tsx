import { Text, View } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface GuardrailWarningProps {
  visible: boolean
}

export function GuardrailWarning({ visible }: GuardrailWarningProps) {
  if (!visible) return null

  return (
    <Animated.View
      entering={FadeIn.duration(200)}
      exiting={FadeOut.duration(200)}
      className="bg-amber-100 dark:bg-amber-900 border border-amber-500 rounded-lg px-4 py-2"
      accessibilityRole="alert"
      accessibilityLiveRegion="assertive"
    >
      <View className="flex-row items-center">
        <IconSymbol name="exclamationmark.triangle.fill" size={16} color="#F59E0B" />
        <Text className="text-sm ml-2 text-amber-900 dark:text-amber-100">
          The AI went off-topic. Redirecting back to your book.
        </Text>
      </View>
    </Animated.View>
  )
}
