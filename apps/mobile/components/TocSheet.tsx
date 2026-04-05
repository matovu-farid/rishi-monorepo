import { useCallback } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { ReaderTheme } from '@/types/book'

interface TocItem {
  id: string
  href: string
  label: string
  subitems?: TocItem[]
}

interface TocSheetProps {
  sheetRef: React.RefObject<BottomSheet | null>
  toc: TocItem[]
  currentHref: string | null
  theme: ReaderTheme
  onSelectChapter: (href: string) => void
}

export function TocSheet({ sheetRef, toc, currentHref, theme, onSelectChapter }: TocSheetProps) {
  const renderItem = useCallback(
    ({ item }: { item: TocItem }) => {
      const isCurrent = currentHref !== null && item.href === currentHref
      return (
        <TouchableOpacity
          className="h-12 flex-row items-center px-4"
          style={isCurrent ? { borderLeftWidth: 3, borderLeftColor: '#0a7ea4' } : undefined}
          onPress={() => onSelectChapter(item.href)}
          accessibilityRole="button"
        >
          <Text
            style={{ color: theme.color }}
            className={`text-base ${isCurrent ? 'font-semibold' : 'font-normal'}`}
            numberOfLines={1}
          >
            {item.label}
          </Text>
        </TouchableOpacity>
      )
    },
    [currentHref, theme, onSelectChapter]
  )

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      backgroundStyle={{ backgroundColor: theme.background }}
      handleIndicatorStyle={{ backgroundColor: theme.color, width: 36, height: 4 }}
    >
      <View className="px-4 pb-2">
        <Text style={{ color: theme.color }} className="text-lg font-semibold">
          Contents
        </Text>
      </View>
      <BottomSheetFlatList
        data={toc}
        keyExtractor={(item) => item.id || item.href}
        renderItem={renderItem}
      />
    </BottomSheet>
  )
}
