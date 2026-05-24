import { Image, Pressable, Text, View } from 'react-native'
import ReanimatedSwipeable from 'react-native-gesture-handler/ReanimatedSwipeable'
import type { Conversation } from '@/types/conversation'

interface ConversationRowProps {
  conversation: Conversation
  bookTitle: string
  bookCoverPath: string | null
  lastMessage?: string
  onPress: () => void
  onLongPress: () => void
  /**
   * #60 — visible delete affordance. When provided, the row is wrapped
   * in a swipe-to-reveal destructive action. Tapping the action invokes
   * this callback. The existing `onLongPress` is preserved as a
   * power-user shortcut so the gesture isn't a regression for muscle
   * memory; the swipe is the discoverable path.
   *
   * Why this prop is OPTIONAL rather than reusing onLongPress: callers
   * that pass only onLongPress (e.g. tests, future surfaces) should not
   * get the swipe UI implicitly. The screen-level wiring is explicit.
   */
  onSwipeDelete?: () => void
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
  onSwipeDelete,
  testID,
}: ConversationRowProps) {
  const row = (
    <Pressable
      testID={testID}
      onPress={onPress}
      onLongPress={onLongPress}
      className="flex-row items-center bg-white dark:bg-[#151718] px-4 py-4 active:bg-gray-100 dark:active:bg-gray-800"
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

  if (!onSwipeDelete) {
    return row
  }

  // #60 — wrap the row in ReanimatedSwipeable so the destructive action
  // is discoverable via the standard iOS / Material swipe-to-delete
  // gesture. We use the Reanimated variant because the legacy `Swipeable`
  // export is `@deprecated` in react-native-gesture-handler 2.28.
  const renderRightActions = () => (
    <Pressable
      testID={testID ? `${testID}-delete-action` : undefined}
      onPress={onSwipeDelete}
      className="bg-red-600 justify-center items-center px-6 active:bg-red-700"
      accessibilityRole="button"
      accessibilityLabel="Delete conversation"
      accessibilityHint="Removes the conversation permanently"
    >
      <Text className="text-white font-semibold">Delete</Text>
    </Pressable>
  )

  return (
    <ReanimatedSwipeable
      renderRightActions={renderRightActions}
      // Match the iOS-Mail feel: a small drag offset prevents accidental
      // reveal during vertical scrolls; the threshold is half-width by
      // default which is fine for a row this height.
      friction={2}
      rightThreshold={40}
    >
      {row}
    </ReanimatedSwipeable>
  )
}
