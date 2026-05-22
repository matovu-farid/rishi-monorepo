import React, { useCallback, useEffect, useRef } from 'react'
import { Alert, Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ReaderTheme } from '@/types/book'
import { Highlight, HIGHLIGHT_COLORS } from '@/types/highlight'
import { useTheme } from '@/lib/theme'

/**
 * HighlightsSheet — dual-API during the Phase 3 reader-UI migration.
 *
 * New callers pass {isOpen, onClose, onNavigate, onDelete}. Legacy
 * callers still use {sheetRef, theme, onNavigateToHighlight,
 * onDeleteHighlight}. Both flows render the same body.
 */
interface HighlightsSheetProps {
  // New API
  isOpen?: boolean
  onClose?: () => void
  onNavigate?: (cfiRange: string) => void
  onDelete?: (id: string) => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme
  onNavigateToHighlight?: (cfiRange: string) => void
  onDeleteHighlight?: (id: string) => void

  highlights: Highlight[]
}

function HighlightRow({
  item,
  textColor,
  secondaryColor,
  onPress,
  onLongPress,
}: {
  item: Highlight
  textColor: string
  secondaryColor: string
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
          <Text style={{ color: secondaryColor }} className="text-xs" numberOfLines={1}>
            {item.chapter}
          </Text>
        ) : null}
      </View>
      <Text style={{ color: textColor }} className="text-sm" numberOfLines={2}>
        {item.text}
      </Text>
      {item.note ? (
        <Text
          style={{ color: secondaryColor, fontStyle: 'italic' }}
          className="text-sm mt-1"
          numberOfLines={1}
        >
          {item.note}
        </Text>
      ) : null}
    </TouchableOpacity>
  )
}

export function HighlightsSheet({
  isOpen,
  onClose,
  onNavigate,
  onDelete,
  sheetRef: externalSheetRef,
  theme,
  onNavigateToHighlight,
  onDeleteHighlight,
  highlights,
}: HighlightsSheetProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  const navigate = onNavigate ?? onNavigateToHighlight ?? (() => undefined)
  const delete_ = onDelete ?? onDeleteHighlight ?? (() => undefined)

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const secondaryColor = colors.label.secondary
  const tertiaryColor = colors.label.tertiary
  const indicatorColor = theme?.color ?? colors.fill.tertiary

  const handleDelete = useCallback(
    (id: string) => {
      Alert.alert(
        'Delete Highlight',
        'This highlight and its note will be removed from all your devices.',
        [
          { text: 'Cancel', style: 'cancel' },
          { text: 'Delete', style: 'destructive', onPress: () => delete_(id) },
        ]
      )
    },
    [delete_]
  )

  const renderItem = useCallback(
    ({ item }: { item: Highlight }) => (
      <HighlightRow
        item={item}
        textColor={textColor}
        secondaryColor={secondaryColor}
        onPress={() => navigate(item.cfiRange)}
        onLongPress={() => handleDelete(item.id)}
      />
    ),
    [textColor, secondaryColor, navigate, handleDelete]
  )

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
      handleIndicatorStyle={{ backgroundColor: indicatorColor, width: 36, height: 4 }}
    >
      <View className="px-4 pb-2">
        <Text style={{ color: textColor }} className="text-lg font-semibold">
          Highlights ({highlights.length})
        </Text>
      </View>

      {highlights.length === 0 ? (
        <View className="flex-1 items-center justify-center p-8">
          <IconSymbol name="pencil.line" size={40} color={tertiaryColor} />
          <Text style={{ color: textColor }} className="text-base font-semibold mt-4">
            No highlights yet
          </Text>
          <Text style={{ color: secondaryColor }} className="text-sm mt-1 text-center">
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
