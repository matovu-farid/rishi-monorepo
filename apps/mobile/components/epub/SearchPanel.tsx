/**
 * EPUB Search bottom-sheet panel — extracted from
 * `apps/mobile/app/reader/[id].tsx` (Batch 7 G12) so the reader screen
 * stays manageable and the search UI is reusable. Matches electron's
 * `apps/rishi-electron/src/renderer/src/components/search/SearchPanel.tsx`
 * in UX.
 */
import React, { useEffect, useRef } from 'react'
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { useTheme } from '@/lib/theme'
import type { ReaderTheme } from '@/types/book'

export interface SearchResult {
  cfi: string
  excerpt: string
  section?: { label?: string } | null
}

/**
 * SearchPanel — dual-API during the Phase 3 reader-UI migration.
 *
 * Preserves Detox testIDs `search-input`, `search-no-results`, and
 * `search-prompt`.
 */
export interface SearchPanelProps {
  // New API
  isOpen?: boolean
  onClose?: () => void

  // Legacy API (deprecated)
  sheetRef?: React.RefObject<BottomSheet | null>
  theme?: ReaderTheme
  onChange?: (index: number) => void

  query: string
  results: SearchResult[]
  isSearching: boolean
  onChangeQuery: (value: string) => void
  onSelectResult: (cfi: string) => void
}

export function SearchPanel({
  isOpen,
  onClose,
  sheetRef: externalSheetRef,
  theme,
  query,
  results,
  isSearching,
  onChangeQuery,
  onSelectResult,
  onChange,
}: SearchPanelProps) {
  const { colors, scheme } = useTheme()
  const internalRef = useRef<BottomSheet>(null)
  const sheetRef = externalSheetRef ?? internalRef

  useEffect(() => {
    if (typeof isOpen !== 'boolean') return
    if (isOpen) sheetRef.current?.snapToIndex(0)
    else sheetRef.current?.close()
  }, [isOpen, sheetRef])

  // Theme-driven palette with legacy override pathway.
  const sheetBg = theme?.background ?? colors.background.secondary
  const textColor = theme?.color ?? colors.label.primary
  const secondaryColor = colors.label.secondary
  const tertiaryColor = colors.label.tertiary
  const indicatorColor = theme?.toolbarText ?? theme?.color ?? colors.fill.tertiary
  const dark = theme ? theme.name === 'dark' : scheme === 'dark'
  const inputBg = dark ? colors.fill.secondary : colors.fill.tertiary
  const dividerBg = colors.separator.nonOpaque

  return (
    <BottomSheet
      ref={sheetRef}
      index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      backgroundStyle={{ backgroundColor: sheetBg }}
      handleIndicatorStyle={{ backgroundColor: indicatorColor }}
      onChange={(index) => {
        onChange?.(index)
        if (index === -1) onClose?.()
      }}
    >
      <View style={{ flex: 1, paddingHorizontal: 16 }}>
        <View
          style={{
            flexDirection: 'row',
            alignItems: 'center',
            backgroundColor: inputBg,
            borderRadius: 8,
            paddingHorizontal: 12,
            marginBottom: 12,
          }}
        >
          <IconSymbol name="magnifyingglass" size={18} color={tertiaryColor} />
          <TextInput
            testID="search-input"
            style={{
              flex: 1,
              marginLeft: 8,
              paddingVertical: 10,
              fontSize: 16,
              color: textColor,
            }}
            placeholder="Search in book..."
            placeholderTextColor={tertiaryColor}
            value={query}
            onChangeText={onChangeQuery}
            autoCapitalize="none"
            autoCorrect={false}
            returnKeyType="search"
            autoFocus
          />
        </View>

        {isSearching ? (
          <View style={{ alignItems: 'center', paddingVertical: 16 }}>
            <ActivityIndicator size="small" />
            <Text style={{ color: secondaryColor, marginTop: 8, fontSize: 14 }}>Searching...</Text>
          </View>
        ) : null}

        {!isSearching && results.length > 0 ? (
          <FlatList
            data={results}
            keyExtractor={(_, idx) => String(idx)}
            renderItem={({ item }) => (
              <Pressable
                onPress={() => onSelectResult(item.cfi)}
                style={{
                  paddingVertical: 12,
                  paddingHorizontal: 4,
                  borderBottomWidth: 1,
                  borderBottomColor: dividerBg,
                }}
                accessibilityRole="button"
                accessibilityLabel={`Jump to ${item.section?.label ?? 'result'}`}
              >
                <Text style={{ color: textColor, fontSize: 14 }} numberOfLines={2}>
                  {item.excerpt}
                </Text>
                {item.section?.label ? (
                  <Text style={{ color: secondaryColor, fontSize: 12, marginTop: 4 }}>
                    {item.section.label}
                  </Text>
                ) : null}
              </Pressable>
            )}
          />
        ) : null}

        {!isSearching && query.length > 1 && results.length === 0 ? (
          <Text
            style={{
              color: secondaryColor,
              textAlign: 'center',
              paddingVertical: 24,
              fontSize: 14,
            }}
            testID="search-no-results"
          >
            No results found
          </Text>
        ) : null}

        {!isSearching && query.length <= 1 ? (
          <View
            style={{ alignItems: 'center', justifyContent: 'center', paddingVertical: 32 }}
            testID="search-prompt"
          >
            <Text style={{ color: textColor, fontSize: 16, fontWeight: '600' }}>
              Search this book
            </Text>
            <Text
              style={{
                color: secondaryColor,
                marginTop: 4,
                fontSize: 13,
                textAlign: 'center',
                paddingHorizontal: 24,
              }}
            >
              Type to find text in the current book.
            </Text>
          </View>
        ) : null}
      </View>
    </BottomSheet>
  )
}
