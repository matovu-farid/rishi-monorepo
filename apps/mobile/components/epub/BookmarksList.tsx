/**
 * EPUB bookmarks list — bottom-sheet UI matching electron's
 * `apps/rishi-electron/src/renderer/src/components/bookmarks/BookmarksList.tsx`
 * in spirit. Renders rows with the label (or location fallback), the
 * created-at date, and a delete affordance.
 *
 * Empty state mirrors electron's "No bookmarks yet" placeholder.
 */
import React, { useEffect, useMemo, useRef } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { useTheme } from '@/lib/theme'
import type { ReaderTheme } from '@/types/book'
import type { Bookmark } from '@/lib/bookmarks/bookmark-storage'

/**
 * BookmarksList — dual-API during the Phase 3 reader-UI migration.
 *
 * Detox testIDs preserved: `bookmarks-empty` on the empty state and
 * `bookmark-row-${id}` on each row.
 */
export interface BookmarksListProps {
  // New API
  isOpen?: boolean
  onClose?: () => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme

  bookmarks: Bookmark[]
  onNavigate: (location: string) => void
  onDelete: (id: string) => void
}

export function BookmarksList({
  isOpen,
  onClose,
  sheetRef: externalSheetRef,
  theme,
  bookmarks,
  onNavigate,
  onDelete,
}: BookmarksListProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  const sorted = useMemo(
    () => [...bookmarks].sort((a, b) => b.createdAt - a.createdAt),
    [bookmarks],
  )

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const tertiaryColor = colors.label.tertiary
  const indicatorColor = theme?.toolbarText ?? theme?.color ?? colors.fill.tertiary

  return (
    <BottomSheet
      ref={sheetRef}
      index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      onChange={(index) => {
        if (index === -1) onClose?.()
      }}
      backgroundStyle={{ backgroundColor: sheetBg }}
      handleIndicatorStyle={{ backgroundColor: indicatorColor }}
    >
      <View style={{ paddingHorizontal: 16, paddingBottom: 8 }}>
        <Text style={{ color: textColor, fontSize: 18, fontWeight: '600' }}>
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
          <IconSymbol name="bookmark" size={32} color={tertiaryColor} />
          <Text
            style={{ color: tertiaryColor, marginTop: 8, fontSize: 14, textAlign: 'center' }}
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
              textColor={textColor}
              secondaryColor={tertiaryColor}
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
  textColor: string
  secondaryColor: string
  onNavigate: (location: string) => void
  onDelete: (id: string) => void
}

function BookmarkRow({
  bookmark,
  textColor,
  secondaryColor,
  onNavigate,
  onDelete,
}: RowProps) {
  const { colors } = useTheme()
  const label =
    bookmark.label && bookmark.label.length > 0 ? bookmark.label : bookmark.location
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
        <IconSymbol name="bookmark.fill" size={16} color={colors.accent.error} />
        <View style={{ flex: 1, minWidth: 0 }}>
          <Text
            style={{ color: textColor, fontSize: 14, fontWeight: '500' }}
            numberOfLines={1}
          >
            {label}
          </Text>
          <Text style={{ color: secondaryColor, fontSize: 12, marginTop: 2 }}>{date}</Text>
        </View>
      </TouchableOpacity>
      <TouchableOpacity
        onPress={() => onDelete(bookmark.id)}
        style={{ minWidth: 44, minHeight: 44, justifyContent: 'center', alignItems: 'center' }}
        accessibilityRole="button"
        accessibilityLabel="Delete bookmark"
      >
        <IconSymbol name="trash" size={16} color={secondaryColor} />
      </TouchableOpacity>
    </View>
  )
}
