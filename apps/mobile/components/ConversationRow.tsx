import { useCallback } from 'react'
import { Image, Pressable, StyleSheet, Text, View } from 'react-native'
import { useTheme } from '@/lib/theme'
import type { Conversation } from '@/types/conversation'

interface ConversationRowProps {
  conversation: Conversation
  bookTitle: string
  bookCoverPath: string | null
  lastMessage?: string
  onPress: () => void
  onLongPress: () => void
  /**
   * Optional testID forwarded to the outer `Pressable`. Used by E2E
   * tests to target a specific conversation row by id without relying
   * on its rendered text content.
   */
  testID?: string
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
  testID,
}: ConversationRowProps) {
  const { colors } = useTheme()
  // PRF-005 (#110): press feedback was previously driven by NativeWind's
  // `active:bg-gray-100 dark:active:bg-gray-800` className, which forces
  // a className re-parse on every press / theme change. Switch to a
  // StyleSheet-backed `style={({ pressed }) => [...]}` callback so the
  // pressed background is a static reference + a tinted overlay sourced
  // from the theme.
  const pressStyle = useCallback(
    ({ pressed }: { pressed: boolean }) => [
      styles.row,
      pressed ? { backgroundColor: colors.fill.tertiary } : null,
    ],
    [colors.fill.tertiary],
  )
  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      onLongPress={onLongPress}
      style={pressStyle}
      accessibilityRole="button"
      // P1-AE: expose the FULL book title via accessibilityLabel so VoiceOver
      // users hear the untruncated title even when the visible Text below is
      // truncated to a single line.
      accessibilityLabel={bookTitle}
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
          testID={testID ? `${testID}-title` : undefined}
          className="text-base font-semibold text-gray-900 dark:text-white"
          numberOfLines={1}
          // P1-AE: explicit tail-ellipsis so truncation rendering is
          // deterministic across iOS / Android RN runtimes.
          ellipsizeMode="tail"
        >
          {bookTitle}
        </Text>
        {lastMessage ? (
          <Text
            testID={testID ? `${testID}-last-message` : undefined}
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

// PRF-005 (#110): static layout pulled into StyleSheet so the press
// callback only composes the pressed-state background. The earlier
// `flex-row items-center px-4 py-4` className is preserved here as
// equivalent inline RN values so the row keeps its original spacing.
const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 16,
  },
})
