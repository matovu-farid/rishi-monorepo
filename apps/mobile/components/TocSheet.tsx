import React, { useCallback, useEffect, useRef } from 'react'
import { Text, TouchableOpacity, View } from 'react-native'
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet'
import { ReaderTheme } from '@/types/book'
import { useTheme } from '@/lib/theme'

interface TocItem {
  id?: string
  href: string
  label: string
  subitems?: TocItem[]
}

/**
 * TocSheet — dual-API during the Phase 3 reader-UI migration.
 *
 * New callers pass {isOpen, onClose}. Legacy callers still pass
 * {sheetRef, theme}. Both flows share the body.
 */
interface TocSheetProps {
  // New API
  isOpen?: boolean
  onClose?: () => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme

  toc: TocItem[]
  currentHref: string | null
  onSelectChapter: (href: string) => void
}

export function TocSheet({
  isOpen,
  onClose,
  sheetRef: externalSheetRef,
  theme,
  toc,
  currentHref,
  onSelectChapter,
}: TocSheetProps) {
  const { colors } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const indicatorColor = theme?.color ?? colors.fill.tertiary
  const accent = colors.accent.primary

  const renderItem = useCallback(
    ({ item }: { item: TocItem }) => {
      const isCurrent = currentHref !== null && item.href === currentHref
      return (
        <TouchableOpacity
          className="h-12 flex-row items-center px-4"
          style={isCurrent ? { borderLeftWidth: 3, borderLeftColor: accent } : undefined}
          onPress={() => onSelectChapter(item.href)}
          accessibilityRole="button"
        >
          <Text
            style={{ color: textColor }}
            className={`text-base ${isCurrent ? 'font-semibold' : 'font-normal'}`}
            numberOfLines={1}
          >
            {item.label}
          </Text>
        </TouchableOpacity>
      )
    },
    [currentHref, textColor, accent, onSelectChapter]
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
          Contents
        </Text>
      </View>
      <BottomSheetFlatList
        data={toc}
        keyExtractor={(item: TocItem) => item.id || item.href}
        renderItem={renderItem}
      />
    </BottomSheet>
  )
}
