/**
 * EPUB bookmarks list — bottom-sheet UI matching electron's
 * `apps/rishi-electron/src/renderer/src/components/bookmarks/BookmarksList.tsx`
 * in spirit. Renders rows with the label (or location fallback), the
 * created-at date, and a delete affordance.
 *
 * Empty state mirrors electron's "No bookmarks yet" placeholder.
 */
import { useMemo } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { ReaderTheme } from '@/types/book'
import type { Bookmark } from '@/lib/bookmarks/bookmark-storage'

export interface BookmarksListProps {
  sheetRef: React.RefObject<BottomSheet | null>
  bookmarks: Bookmark[]
  theme: ReaderTheme
  onNavigate: (location: string) => void
  onDelete: (id: string) => void
}

export function BookmarksList({
  sheetRef,
  bookmarks,
  theme,
  onNavigate,
  onDelete,
}: BookmarksListProps) {
  const sorted = useMemo(
    () => [...bookmarks].sort((a, b) => b.createdAt - a.createdAt),
    [bookmarks],
  )

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      backgroundStyle={{ backgroundColor: theme.background }}
      handleIndicatorStyle={{ backgroundColor: theme.toolbarText ?? theme.color }}
    >
      <View style={{ paddingHorizontal: 16, paddingBottom: 8 }}>
        <Text style={{ color: theme.color, fontSize: 18, fontWeight: '600' }}>
          Bookmarks
        </Text>
      </View>

      {sorted.length === 0 ? (
        <View
          style={{
            flex: 1,
            justifyContent: 'center',
            alignItems: 'center',
            paddingHorizontal: 24,
          }}
          testID="bookmarks-empty"
        >
          <IconSymbol name="bookmark" size={32} color="#9CA3AF" />
          <Text
            style={{ color: '#9CA3AF', marginTop: 8, fontSize: 14, textAlign: 'center' }}
          >
            No bookmarks yet
          </Text>
        </View>
      ) : (
        <BottomSheetFlatList<Bookmark>
          data={sorted}
          keyExtractor={(item: Bookmark) => item.id}
          contentContainerStyle={{ paddingHorizontal: 8, paddingBottom: 32 }}
          renderItem={({ item }: { item: Bookmark }) => (
            <BookmarkRow
              bookmark={item}
              theme={theme}
              onNavigate={onNavigate}
              onDelete={onDelete}
            />
          )}
        />
      )}
    </BottomSheet>
  )
}

interface RowProps {
  bookmark: Bookmark
  theme: ReaderTheme
  onNavigate: (location: string) => void
  onDelete: (id: string) => void
}

function BookmarkRow({ bookmark, theme, onNavigate, onDelete }: RowProps) {
  const label = bookmark.label && bookmark.label.length > 0
    ? bookmark.label
    : bookmark.location
  const date = new Date(bookmark.createdAt).toLocaleDateString()

  return (
    <View
      testID={`bookmark-row-${bookmark.id}`}
      style={{
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        paddingHorizontal: 12,
        paddingVertical: 10,
        borderRadius: 8,
      }}
    >
      <TouchableOpacity
        onPress={() => onNavigate(bookmark.location)}
        style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 12 }}
        accessibilityRole="button"
        accessibilityLabel={`Navigate to ${label}`}
      >
        <IconSymbol name="bookmark.fill" size={16} color="#ef4444" />
        <View style={{ flex: 1, minWidth: 0 }}>
          <Text
            style={{ color: theme.color, fontSize: 14, fontWeight: '500' }}
            numberOfLines={1}
          >
            {label}
          </Text>
          <Text style={{ color: '#9CA3AF', fontSize: 12, marginTop: 2 }}>{date}</Text>
        </View>
      </TouchableOpacity>
      <TouchableOpacity
        onPress={() => onDelete(bookmark.id)}
        style={{ minWidth: 44, minHeight: 44, justifyContent: 'center', alignItems: 'center' }}
        accessibilityRole="button"
        accessibilityLabel="Delete bookmark"
      >
        <IconSymbol name="trash" size={16} color="#9CA3AF" />
      </TouchableOpacity>
    </View>
  )
}
