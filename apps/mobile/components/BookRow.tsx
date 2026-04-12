import { View, Text, Pressable, TouchableOpacity } from 'react-native'
import { Book } from '@/types/book'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface BookRowProps {
  book: Book
  onPress: (book: Book) => void
  onDelete: (book: Book) => void
}

export function BookRow({ book, onPress, onDelete }: BookRowProps) {
  const isPdf = book.format === 'pdf'

  return (
    <Pressable
      className="flex-row items-center px-4 py-4 active:bg-gray-100 dark:active:bg-gray-800"
      onPress={() => onPress(book)}
      accessibilityRole="button"
      accessibilityLabel={`Open ${book.title} by ${book.author}`}
    >
      {/* Cover placeholder -- 48px wide, format-colored background, rounded */}
      <View
        className={`w-12 h-16 rounded-md items-center justify-center mr-4 ${
          isPdf
            ? 'bg-red-100 dark:bg-red-900'
            : 'bg-gray-200 dark:bg-gray-700'
        }`}
      >
        <Text className="text-gray-400 dark:text-gray-500 text-xs">
          {book.format.toUpperCase()}
        </Text>
      </View>
      <View className="flex-1">
        <Text
          testID="book-row-title"
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
      {/* Delete button */}
      <TouchableOpacity
        testID="book-delete-button"
        onPress={() => onDelete(book)}
        className="w-11 h-11 items-center justify-center"
        accessibilityRole="button"
        accessibilityLabel={`Delete ${book.title}`}
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
      >
        <IconSymbol name="trash" size={20} color="#DC2626" />
      </TouchableOpacity>
    </Pressable>
  )
}
