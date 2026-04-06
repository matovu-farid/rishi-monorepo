import { Image, Pressable, Text, View } from 'react-native'
import type { Conversation } from '@/types/conversation'

interface ConversationRowProps {
  conversation: Conversation
  bookTitle: string
  bookCoverPath: string | null
  lastMessage?: string
  onPress: () => void
  onLongPress: () => void
}

function getRelativeTime(timestamp: number): string {
  const now = Date.now()
  const diffMs = now - timestamp
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHr = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHr / 24)

  if (diffSec < 60) return 'Just now'
  if (diffMin < 60) return `${diffMin}m ago`
  if (diffHr < 24) return `${diffHr}h ago`
  if (diffDay < 7) return `${diffDay}d ago`
  return new Date(timestamp).toLocaleDateString()
}

export function ConversationRow({
  conversation,
  bookTitle,
  bookCoverPath,
  lastMessage,
  onPress,
  onLongPress,
}: ConversationRowProps) {
  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      className="flex-row items-center px-4 py-4 active:bg-gray-100 dark:active:bg-gray-800"
      accessibilityRole="button"
      accessibilityLabel={`Conversation about ${bookTitle}`}
    >
      {/* Book cover thumbnail */}
      {bookCoverPath ? (
        <Image
          source={{ uri: bookCoverPath }}
          className="w-8 h-12 rounded-sm mr-3"
          resizeMode="cover"
        />
      ) : (
        <View className="w-8 h-12 rounded-sm mr-3 bg-gray-200 dark:bg-gray-700" />
      )}

      {/* Text content */}
      <View className="flex-1">
        <Text
          className="text-base font-semibold text-gray-900 dark:text-white"
          numberOfLines={1}
        >
          {bookTitle}
        </Text>
        {lastMessage ? (
          <Text
            className="text-sm text-gray-500 dark:text-gray-400 mt-0.5"
            numberOfLines={1}
          >
            {lastMessage}
          </Text>
        ) : null}
        <Text className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
          {getRelativeTime(conversation.updatedAt)}
        </Text>
      </View>
    </Pressable>
  )
}
