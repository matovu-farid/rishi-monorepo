import { Pressable, Text } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { SourceChunk } from '@/types/conversation'

interface SourceReferenceProps {
  source: SourceChunk
  onPress: () => void
}

export function SourceReference({ source, onPress }: SourceReferenceProps) {
  const label = source.chapter || 'Source'

  return (
    <Pressable
      onPress={onPress}
      className="flex-row items-center bg-gray-200 dark:bg-gray-700 rounded-full px-2 py-1"
      style={({ pressed }) => ({ opacity: pressed ? 0.7 : 1 })}
      accessibilityLabel={`View source: ${source.chapter || 'passage'}`}
      accessibilityRole="button"
    >
      <IconSymbol name="book.fill" size={12} color="#687076" />
      <Text className="text-xs text-gray-700 dark:text-gray-300 ml-1">
        {label}
      </Text>
    </Pressable>
  )
}
