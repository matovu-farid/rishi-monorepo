import { View, Text, TouchableOpacity } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { RealtimeVoiceButton } from '@/components/RealtimeVoiceButton'
import { ReaderTheme } from '@/types/book'
import type { RealtimeStatus } from '@/lib/realtime/types'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'

interface ReaderToolbarProps {
  visible: boolean
  title: string
  theme: ReaderTheme
  onBack: () => void
  onTocPress: () => void
  onHighlightsPress: () => void
  onAppearancePress: () => void
  onChatPress?: () => void
  onTTSPress?: () => void
  ttsActive?: boolean
  onRealtimePress?: () => void
  realtimeStatus?: RealtimeStatus
}

export function ReaderToolbar({
  visible,
  title,
  theme,
  onBack,
  onTocPress,
  onHighlightsPress,
  onAppearancePress,
  onChatPress,
  onTTSPress,
  ttsActive,
  onRealtimePress,
  realtimeStatus,
}: ReaderToolbarProps) {
  const insets = useSafeAreaInsets()

  if (!visible) return null

  return (
    <Animated.View
      entering={FadeIn.duration(200)}
      exiting={FadeOut.duration(200)}
      style={{
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        paddingTop: insets.top,
        backgroundColor: theme.toolbarBg,
        zIndex: 10,
      }}
    >
      <View className="flex-row items-center justify-between h-12 px-4">
        <TouchableOpacity
          onPress={onBack}
          className="w-11 h-11 items-center justify-center"
          accessibilityLabel="Back to library"
          accessibilityRole="button"
        >
          <IconSymbol name="chevron.left" size={22} color={theme.toolbarText} />
        </TouchableOpacity>

        <Text
          style={{ color: theme.toolbarText }}
          className="flex-1 text-base font-semibold text-center mx-2"
          numberOfLines={1}
        >
          {title}
        </Text>

        <View className="flex-row">
          <TouchableOpacity
            onPress={onTocPress}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="Table of contents"
            accessibilityRole="button"
          >
            <IconSymbol name="list.bullet" size={22} color={theme.toolbarText} />
          </TouchableOpacity>
          <TouchableOpacity
            onPress={onHighlightsPress}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="Highlights"
            accessibilityRole="button"
          >
            <IconSymbol name="bookmark.fill" size={22} color={theme.toolbarText} />
          </TouchableOpacity>
          <TouchableOpacity
            onPress={onAppearancePress}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="Reading appearance"
            accessibilityRole="button"
          >
            <IconSymbol name="paintpalette.fill" size={22} color={theme.toolbarText} />
          </TouchableOpacity>
          {onChatPress && (
            <TouchableOpacity
              onPress={onChatPress}
              className="w-11 h-11 items-center justify-center"
              accessibilityLabel="Ask AI about this book"
              accessibilityRole="button"
            >
              <IconSymbol name="message.fill" size={22} color={theme.toolbarText} />
            </TouchableOpacity>
          )}
          {onTTSPress && (
            <TouchableOpacity
              onPress={onTTSPress}
              className="w-11 h-11 items-center justify-center"
              accessibilityLabel={ttsActive ? 'Reading aloud' : 'Read aloud'}
              accessibilityRole="button"
            >
              <IconSymbol name="speaker.wave.2.fill" size={22} color={ttsActive ? '#0a7ea4' : theme.toolbarText} />
            </TouchableOpacity>
          )}
          {onRealtimePress && (
            <RealtimeVoiceButton
              status={realtimeStatus ?? 'idle'}
              onPress={onRealtimePress}
            />
          )}
        </View>
      </View>
    </Animated.View>
  )
}
