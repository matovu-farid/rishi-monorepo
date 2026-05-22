import { View, Text, Pressable, TouchableOpacity, StyleSheet } from 'react-native'
import { Book } from '@/types/book'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { BookCover } from '@/components/ui/BookCover'
import { Hairline } from '@/components/ui/Hairline'
import { useTheme } from '@/lib/theme'

interface BookRowProps {
  book: Book
  onPress: (book: Book) => void
  onDelete: (book: Book) => void
}

/**
 * BookRow (P1-V).
 *
 * Migrated off Tailwind grays + hardcoded `#DC2626` onto the iOS-flavour
 * design tokens:
 *   - press surface         ➜ colors.fill.quaternary
 *   - title                 ➜ colors.label.primary
 *   - subtitle (author)     ➜ colors.label.secondary
 *   - destructive icon tint ➜ colors.accent.error
 *
 * Adds a trailing `Hairline` so the row reads as a list cell even when
 * the parent FlatList doesn't wire up `ItemSeparatorComponent` (that
 * wiring is deferred to the parent screen change-set).
 */
export function BookRow({ book, onPress, onDelete }: BookRowProps) {
  const { colors, spacing, typography } = useTheme()
  return (
    <View>
      <Pressable
        testID={`library-book-row-${book.id}`}
        onPress={() => onPress(book)}
        accessibilityRole="button"
        accessibilityLabel={`Open ${book.title} by ${book.author}`}
        style={({ pressed }) => [
          styles.row,
          {
            paddingHorizontal: spacing.lg,
            paddingVertical: spacing.lg,
            backgroundColor: pressed ? colors.fill.quaternary : 'transparent',
          },
        ]}
      >
        <View style={{ marginRight: spacing.lg }}>
          <BookCover
            uri={book.coverPath ?? undefined}
            title={book.title}
            size="sm"
            testID={`book-row-cover-${book.id}`}
          />
        </View>
        <View style={styles.titleColumn}>
          <Text
            testID="book-row-title"
            numberOfLines={1}
            style={{
              fontSize: typography.scale.body.fontSize,
              lineHeight: typography.scale.body.lineHeight,
              fontWeight: '600',
              color: colors.label.primary,
            }}
          >
            {book.title}
          </Text>
          <Text
            numberOfLines={1}
            style={{
              fontSize: typography.scale.subhead.fontSize,
              lineHeight: typography.scale.subhead.lineHeight,
              color: colors.label.secondary,
              marginTop: 2,
            }}
          >
            {book.author}
          </Text>
        </View>
        {/* Destructive delete button — surfaced via accent.error rather than a
            hardcoded hex so light/dark mode and accessibility tints win. */}
        <TouchableOpacity
          testID="book-delete-button"
          onPress={() => onDelete(book)}
          style={styles.deleteButton}
          accessibilityRole="button"
          accessibilityLabel={`Delete ${book.title}`}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
        >
          <IconSymbol name="trash" size={20} color={colors.accent.error} />
        </TouchableOpacity>
      </Pressable>
      <Hairline inset={spacing.lg} />
    </View>
  )
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  titleColumn: {
    flex: 1,
  },
  deleteButton: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
})
