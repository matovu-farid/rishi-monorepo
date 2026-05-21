/**
 * EPUB Search bottom-sheet panel — extracted from
 * `apps/mobile/app/reader/[id].tsx` (Batch 7 G12) so the reader screen
 * stays manageable and the search UI is reusable. Matches electron's
 * `apps/rishi-electron/src/renderer/src/components/search/SearchPanel.tsx`
 * in UX:
 *
 *   - Auto-focus the input when the sheet opens.
 *   - Live FlatList results with the excerpt + section label.
 *   - Loading spinner while `isSearching`.
 *   - Empty state when query.length > 1 and no results.
 *   - "Search this book" placeholder when query is empty.
 *
 * The component is intentionally render-only: it receives the search
 * primitives (`query`, `results`, `isSearching`) from the parent and
 * exposes `onChangeQuery` + `onSelectResult`. Keeps the epubjs-react-
 * native hook coupling out of this file.
 */
import { useEffect } from 'react'
import { ActivityIndicator, FlatList, Pressable, Text, TextInput, View } from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { IconSymbol } from '@/components/ui/icon-symbol'
import type { ReaderTheme } from '@/types/book'

export interface SearchResult {
  cfi: string
  excerpt: string
  section?: { label?: string } | null
}

export interface SearchPanelProps {
  sheetRef: React.RefObject<BottomSheet | null>
  theme: ReaderTheme
  query: string
  results: SearchResult[]
  isSearching: boolean
  onChangeQuery: (value: string) => void
  onSelectResult: (cfi: string) => void
  /** Optional: called whenever the sheet's snap index changes — the
   *  parent can clear search state on close. Sheet ref is the source
   *  of truth otherwise. */
  onChange?: (index: number) => void
}

export function SearchPanel({
  sheetRef,
  theme,
  query,
  results,
  isSearching,
  onChangeQuery,
  onSelectResult,
  onChange,
}: SearchPanelProps) {
  const dark = theme.name === 'dark'
  const inputBg = dark ? '#374151' : '#F3F4F6'
  const dividerBg = dark ? '#374151' : '#E5E7EB'

  // Auto-focus is platform-specific in @gorhom/bottom-sheet and the
  // existing inline implementation didn't use it — keep the simpler
  // contract here.

  useEffect(() => {
    // No-op effect kept for parity with electron's "auto-focus on open"
    // intent. RN's BottomSheet handles focus when the input mounts.
  }, [])

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={['50%', '90%']}
      enablePanDownToClose
      backgroundStyle={{ backgroundColor: theme.background }}
      handleIndicatorStyle={{ backgroundColor: theme.toolbarText }}
      onChange={onChange}
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
          <IconSymbol name="magnifyingglass" size={18} color="#9CA3AF" />
          <TextInput
            testID="search-input"
            style={{
              flex: 1,
              marginLeft: 8,
              paddingVertical: 10,
              fontSize: 16,
              color: theme.color,
            }}
            placeholder="Search in book..."
            placeholderTextColor="#9CA3AF"
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
            <Text style={{ color: '#9CA3AF', marginTop: 8, fontSize: 14 }}>Searching...</Text>
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
                <Text style={{ color: theme.color, fontSize: 14 }} numberOfLines={2}>
                  {item.excerpt}
                </Text>
                {item.section?.label ? (
                  <Text style={{ color: '#9CA3AF', fontSize: 12, marginTop: 4 }}>
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
              color: '#9CA3AF',
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
            <Text style={{ color: theme.color, fontSize: 16, fontWeight: '600' }}>
              Search this book
            </Text>
            <Text
              style={{
                color: '#9CA3AF',
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
