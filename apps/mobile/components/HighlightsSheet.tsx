import { useCallback } from 'react'
import { Alert, Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ReaderTheme } from '@/types/book'
import { Highlight, HIGHLIGHT_COLORS } from '@/types/highlight'

interface HighlightsSheetProps {
  sheetRef: React.RefObject<BottomSheet | null>
  highlights: Highlight[]
  theme: ReaderTheme
  onNavigateToHighlight: (cfiRange: string) => void
  onDeleteHighlight: (id: string) => void
}

function HighlightRow({
  item,
  theme,
  onPress,
  onLongPress,
}: {
  item: Highlight
  theme: ReaderTheme
  onPress: () => void
  onLongPress: () => void
}) {
  const colorHex = HIGHLIGHT_COLORS.find((c) => c.name === item.color)?.hex ?? '#FBBF24'

  return (
    <TouchableOpacity
      className="p-4"
      onPress={onPress}
      onLongPress={onLongPress}
      accessibilityRole="button"
      accessibilityLabel={`${item.text}${item.chapter ? `, ${item.chapter}` : ''}`}
    >
      <View className="flex-row items-center mb-1">
        <View
          style={{
            width: 10,
            height: 10,
            borderRadius: 5,
            backgroundColor: colorHex,
            marginRight: 8,
          }}
        />
        {item.chapter ? (
          <Text style={{ color: '#687076' }} className="text-xs" numberOfLines={1}>
            {item.chapter}
          </Text>
        ) : null}
      </View>
      <Text style={{ color: theme.color }} className="text-sm" numberOfLines={2}>
        {item.text}
      </Text>
      {item.note ? (
        <Text style={{ color: '#687076', fontStyle: 'italic' }} className="text-sm mt-1" numberOfLines={1}>
          {item.note}
        </Text>
      ) : null}
    </TouchableOpacity>
  )
}

export function HighlightsSheet({
  sheetRef,
  highlights,
  theme,
  onNavigateToHighlight,
  onDeleteHighlight,
}: HighlightsSheetProps) {
  const handleDelete = useCallback(
    (id: string) => {
      Alert.alert(
        'Delete Highlight',
        'This highlight and its note will be removed from all your devices.',
        [
          { text: 'Cancel', style: 'cancel' },
          { text: 'Delete', style: 'destructive', onPress: () => onDeleteHighlight(id) },
        ]
      )
    },
    [onDeleteHighlight]
  )

  const renderItem = useCallback(
    ({ item }: { item: Highlight }) => (
      <HighlightRow
        item={item}
        theme={theme}
        onPress={() => onNavigateToHighlight(item.cfiRange)}
        onLongPress={() => handleDelete(item.id)}
      />
    ),
    [theme, onNavigateToHighlight, handleDelete]
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
          Highlights ({highlights.length})
        </Text>
      </View>

      {highlights.length === 0 ? (
        <View className="flex-1 items-center justify-center p-8">
          <IconSymbol name="pencil.line" size={40} color="#9CA3AF" />
          <Text style={{ color: theme.color }} className="text-base font-semibold mt-4">
            No highlights yet
          </Text>
          <Text style={{ color: '#687076' }} className="text-sm mt-1 text-center">
            Select text while reading to create highlights.
          </Text>
        </View>
      ) : (
        <BottomSheetFlatList
          data={highlights}
          keyExtractor={(item: Highlight) => item.id}
          renderItem={renderItem}
        />
      )}
    </BottomSheet>
  )
}
