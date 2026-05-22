import { View, Text, Pressable, TouchableOpacity } from 'react-native'
import { Book } from '@/types/book'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { BookCover } from '@/components/ui'
import { spacing } from '@/lib/theme'

interface BookRowProps {
  book: Book
  onPress: (book: Book) => void
  onDelete: (book: Book) => void
}

export function BookRow({ book, onPress, onDelete }: BookRowProps) {
  return (
    <Pressable
      testID={`library-book-row-${book.id}`}
      className="flex-row items-center px-4 py-4 active:bg-gray-100 dark:active:bg-gray-800"
      onPress={() => onPress(book)}
      accessibilityRole="button"
      accessibilityLabel={`Open ${book.title} by ${book.author}`}
    >
      <View style={{ marginRight: spacing.lg }}>
        <BookCover
          uri={book.coverPath ?? undefined}
          title={book.title}
          size="sm"
          testID={`book-row-cover-${book.id}`}
        />
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
