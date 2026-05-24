import React, { useCallback, useMemo } from 'react'
import { FlatList, Text, TouchableOpacity, View } from 'react-native'
import { Sheet } from '@/components/ui/Sheet'
import { useTheme } from '@/lib/theme'
import type { Book } from '@/types/book'

/**
 * P1-AH — NewConversationSheet
 *
 * Replaces an `Alert.alert` button list with a scrollable @gorhom/bottom-sheet
 * listing every imported book and its embed-status badge. The legacy Alert
 * silently truncated past iOS's 10-button cap and gave no signal for books
 * that hadn't been embedded yet; this sheet shows the full library plus a
 * "Ready" / "Preparing" affordance per row so users can tell which titles
 * are chat-ready before tapping.
 *
 * Behaviour pinned in __tests__/chat/new-conversation-sheet.test.tsx:
 *   - Lists ALL books, not just embedded ones.
 *   - Each row carries `book-row-<id>-status-{ready|pending}` for tests.
 *   - Tapping a row invokes `onSelectBook(book)` so the parent can route.
 */
export interface NewConversationSheetProps {
  isOpen: boolean
  onClose: () => void
  books: Book[]
  isBookEmbedded: (bookId: string) => boolean
  onSelectBook: (book: Book) => void
}

export function NewConversationSheet({
  isOpen,
  onClose,
  books,
  isBookEmbedded,
  onSelectBook,
}: NewConversationSheetProps): React.JSX.Element {
  const { colors, spacing, typography, radius } = useTheme()

  // #42 — Sort embedded ("Ready") books to the top of the list so users
  // don't have to scroll past "Preparing" titles to find chat-ready ones.
  // Stable partition: preserves the parent's relative order within each
  // group (Array.prototype.sort is stable as of ES2019 / Node 12+).
  const sortedBooks = useMemo(
    () =>
      [...books].sort(
        (a, b) =>
          Number(isBookEmbedded(b.id)) - Number(isBookEmbedded(a.id)),
      ),
    [books, isBookEmbedded],
  )

  const renderItem = useCallback(
    ({ item }: { item: Book }) => {
      const ready = isBookEmbedded(item.id)
      const badgeColor = ready ? colors.accent.success : colors.label.tertiary
      const badgeLabel = ready ? 'Ready' : 'Preparing'
      const statusSuffix = ready ? 'ready' : 'pending'
      return (
        <TouchableOpacity
          testID={`new-conversation-book-row-${item.id}`}
          onPress={() => onSelectBook(item)}
          accessibilityRole="button"
          accessibilityLabel={`Start conversation with ${item.title}, ${badgeLabel}`}
          style={{
            flexDirection: 'row',
            alignItems: 'center',
            paddingVertical: spacing.md,
            paddingHorizontal: spacing.xs,
            gap: spacing.md,
          }}
        >
          <View style={{ flex: 1 }}>
            <Text
              numberOfLines={1}
              style={{
                color: colors.label.primary,
                fontSize: typography.scale.body.fontSize,
                lineHeight: typography.scale.body.lineHeight,
                fontWeight: '600',
              }}
            >
              {item.title}
            </Text>
            {item.author ? (
              <Text
                numberOfLines={1}
                style={{
                  color: colors.label.secondary,
                  fontSize: typography.scale.subhead.fontSize,
                  lineHeight: typography.scale.subhead.lineHeight,
                  marginTop: 2,
                }}
              >
                {item.author}
              </Text>
            ) : null}
          </View>
          <View
            testID={`book-row-${item.id}-status-${statusSuffix}`}
            style={{
              paddingHorizontal: spacing.sm,
              paddingVertical: spacing.xxs,
              borderRadius: radius.full,
              backgroundColor: colors.fill.tertiary,
            }}
          >
            <Text
              style={{
                color: badgeColor,
                fontSize: typography.scale.caption.fontSize,
                fontWeight: '600',
              }}
            >
              {badgeLabel}
            </Text>
          </View>
        </TouchableOpacity>
      )
    },
    [
      colors.accent.success,
      colors.fill.tertiary,
      colors.label.primary,
      colors.label.secondary,
      colors.label.tertiary,
      isBookEmbedded,
      onSelectBook,
      radius.full,
      spacing.md,
      spacing.sm,
      spacing.xs,
      spacing.xxs,
      typography.scale.body.fontSize,
      typography.scale.body.lineHeight,
      typography.scale.caption.fontSize,
      typography.scale.subhead.fontSize,
      typography.scale.subhead.lineHeight,
    ],
  )

  const empty = (
    <View
      testID="new-conversation-empty"
      style={{ paddingVertical: spacing['2xl'], alignItems: 'center' }}
    >
      <Text
        style={{
          color: colors.label.secondary,
          fontSize: typography.scale.body.fontSize,
          textAlign: 'center',
        }}
      >
        Import a book to start a conversation.
      </Text>
    </View>
  )

  return (
    <Sheet
      isOpen={isOpen}
      onClose={onClose}
      title="Start Conversation"
      detent="large"
      accessibilityLabel="Start a new conversation"
    >
      <View testID="new-conversation-sheet" style={{ minHeight: 200 }}>
        <FlatList
          testID="new-conversation-book-list"
          data={sortedBooks}
          keyExtractor={(b) => b.id}
          renderItem={renderItem}
          ListEmptyComponent={empty}
        />
      </View>
    </Sheet>
  )
}
