import { View, Text, TouchableOpacity } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ReaderTheme } from '@/types/book'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'

interface ReaderToolbarProps {
  visible: boolean
  title: string
  theme: ReaderTheme
  onBack: () => void
  onTocPress: () => void
  onAppearancePress: () => void
}

export function ReaderToolbar({
  visible,
  title,
  theme,
  onBack,
  onTocPress,
  onAppearancePress,
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
            onPress={onAppearancePress}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="Reading appearance"
            accessibilityRole="button"
          >
            <IconSymbol name="paintpalette.fill" size={22} color={theme.toolbarText} />
          </TouchableOpacity>
        </View>
      </View>
    </Animated.View>
  )
}
