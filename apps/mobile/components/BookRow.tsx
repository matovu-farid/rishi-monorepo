import { View, Text, Pressable } from 'react-native'
import { Book } from '@/types/book'

interface BookRowProps {
  book: Book
  onPress: (book: Book) => void
}

export function BookRow({ book, onPress }: BookRowProps) {
  return (
    <Pressable
      className="flex-row items-center px-4 py-4 active:bg-gray-100 dark:active:bg-gray-800"
      onPress={() => onPress(book)}
      accessibilityRole="button"
      accessibilityLabel={`Open ${book.title} by ${book.author}`}
    >
      {/* Cover placeholder -- 48px wide, gray background, rounded */}
      <View className="w-12 h-16 bg-gray-200 dark:bg-gray-700 rounded-md items-center justify-center mr-4">
        <Text className="text-gray-400 dark:text-gray-500 text-xs">EPUB</Text>
      </View>
      <View className="flex-1">
        <Text
          className="text-base font-semibold text-gray-900 dark:text-white"
          numberOfLines={1}
        >
          {book.title}
        </Text>
        <Text
          className="text-sm text-gray-500 dark:text-gray-400 mt-0.5"
          numberOfLines={1}
        >
          {book.author}
        </Text>
      </View>
    </Pressable>
  )
}
