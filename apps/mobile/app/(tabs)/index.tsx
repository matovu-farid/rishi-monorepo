import { useCallback, useMemo, useState } from 'react'
import {
  View,
  FlatList,
  Alert,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useRouter, useFocusEffect } from 'expo-router'
import { Directory, Paths } from 'expo-file-system'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { BookCover } from '@/components/ui/BookCover'
import { Hairline } from '@/components/ui/Hairline'
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'
import { BookRow } from '@/components/BookRow'
import { LibraryEmptyState } from '@/components/LibraryEmptyState'
import { UrlImportSheet } from '@/components/UrlImportSheet'
import { getBooks, deleteBook, getLastReadBook } from '@/lib/book-storage'
import { importEpubFile, importPdfFile, importMobiFile, importDjvuFile } from '@/lib/file-import'
import { Book } from '@/types/book'
import { useTourTargetLayout } from '@/lib/onboarding/useTourTarget'
import { useTheme } from '@/lib/theme'

/**
 * Library tab (P0-I).
 *
 * Migrated off Tailwind grays + hardcoded `#0a7ea4` onto the iOS design
 * tokens. The Material FAB (`import-book-fab`) was removed in favour of
 * a nav-bar style `+` button (`library-import-button`) that lives in
 * the screen header, matching Apple Books / iOS chrome.
 *
 * Token usage:
 *   - background           ➜ colors.background.primary
 *   - search bar surface   ➜ colors.fill.tertiary
 *   - "Reading Now" eyebrow ➜ colors.accent.primary
 *   - secondary copy       ➜ colors.label.secondary
 *   - separators           ➜ <Hairline /> (replaces ad-hoc card borders)
 */
export default function LibraryScreen() {
  const router = useRouter()
  const { colors, spacing, typography, radius } = useTheme()
  const [books, setBooks] = useState<Book[]>([])
  const [lastReadBook, setLastReadBook] = useState<Book | null>(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [importing, setImporting] = useState(false)
  const [urlSheetVisible, setUrlSheetVisible] = useState(false)

  // Tour targets (G28): the import button and the library grid get
  // registered with `lib/onboarding/registry` so the first-launch
  // tutorial can spotlight them.
  const importTarget = useTourTargetLayout('import-books')
  const gridTarget = useTourTargetLayout('book-grid')

  const filteredBooks = useMemo(() => {
    if (!searchQuery.trim()) return books
    const query = searchQuery.toLowerCase()
    return books.filter(
      (book) =>
        book.title.toLowerCase().includes(query) ||
        (book.author && book.author.toLowerCase().includes(query))
    )
  }, [books, searchQuery])

  const loadBooks = useCallback(() => {
    const loaded = getBooks()
    setBooks(loaded)
    setLastReadBook(getLastReadBook())
  }, [])

  useFocusEffect(
    useCallback(() => {
      loadBooks()
    }, [loadBooks])
  )

  const doImport = useCallback(
    async (format: 'epub' | 'pdf' | 'mobi' | 'djvu') => {
      setImporting(true)
      try {
        const importFns = { epub: importEpubFile, pdf: importPdfFile, mobi: importMobiFile, djvu: importDjvuFile }
        const book = await importFns[format]()
        if (book) {
          loadBooks()
        }
      } catch (error) {
        Alert.alert(
          'Import Failed',
          `Could not import book. The file may be corrupted or not a valid ${format.toUpperCase()}.`
        )
        console.error('Import error:', error)
      } finally {
        setImporting(false)
      }
    },
    [loadBooks]
  )

  const handleImport = useCallback(() => {
    Alert.alert('Import Book', 'Choose file format', [
      { text: 'EPUB', onPress: () => doImport('epub') },
      { text: 'PDF', onPress: () => doImport('pdf') },
      { text: 'MOBI', onPress: () => doImport('mobi') },
      { text: 'DJVU', onPress: () => doImport('djvu') },
      { text: 'From URL', onPress: () => setUrlSheetVisible(true) },
      { text: 'Cancel', style: 'cancel' },
    ])
  }, [doImport])

  const handleBookPress = useCallback(
    (book: Book) => {
      if (book.format === 'pdf') {
        router.push(`/reader/pdf/${book.id}`)
      } else if (book.format === 'mobi') {
        router.push(`/reader/mobi/${book.id}`)
      } else if (book.format === 'djvu') {
        router.push(`/reader/djvu/${book.id}`)
      } else {
        router.push(`/reader/${book.id}`)
      }
    },
    [router]
  )

  const handleDelete = useCallback(
    (book: Book) => {
      Alert.alert(
        'Delete Book',
        `Are you sure you want to delete "${book.title}"? This cannot be undone.`,
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Delete',
            style: 'destructive',
            onPress: () => {
              deleteBook(book.id)
              const bookDir = new Directory(
                new Directory(Paths.document, 'books'),
                book.id
              )
              if (bookDir.exists) {
                bookDir.delete()
              }
              loadBooks()
            },
          },
        ]
      )
    },
    [loadBooks]
  )

  // Nav-bar `+` action (replaces the Material FAB — P0-I). The button is
  // present in BOTH the empty and populated states so the user has a
  // single, predictable affordance for adding a book.
  const renderHeader = () => (
    <View
      style={[
        styles.headerRow,
        { paddingHorizontal: spacing['2xl'], paddingTop: spacing.lg, paddingBottom: spacing.sm },
      ]}
    >
      <Text
        testID="library-title"
        style={{
          fontSize: typography.scale.largeTitle.fontSize,
          lineHeight: typography.scale.largeTitle.lineHeight,
          fontWeight: typography.scale.largeTitle.fontWeight,
          color: colors.label.primary,
        }}
      >
        Library
      </Text>
      <View style={styles.headerActions}>
        <SyncStatusIndicator />
        <Pressable
          testID="library-import-button"
          ref={importTarget.ref as never}
          onLayout={importTarget.onLayout}
          onPress={handleImport}
          disabled={importing}
          accessibilityRole="button"
          accessibilityLabel="Import Book"
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
          style={({ pressed }) => ({
            marginLeft: spacing.md,
            width: 32,
            height: 32,
            alignItems: 'center',
            justifyContent: 'center',
            borderRadius: radius.full,
            opacity: pressed ? 0.6 : importing ? 0.4 : 1,
          })}
        >
          <IconSymbol name="plus" size={24} color={colors.accent.primary} />
        </Pressable>
      </View>
    </View>
  )

  if (books.length === 0) {
    return (
      <SafeAreaView
        style={{ flex: 1, backgroundColor: colors.background.primary }}
      >
        {renderHeader()}
        <LibraryEmptyState
          onImport={handleImport}
          importing={importing}
          importButtonProps={{ onLayout: importTarget.onLayout }}
          containerProps={{ onLayout: gridTarget.onLayout }}
        />
        <UrlImportSheet
          visible={urlSheetVisible}
          onDismiss={() => setUrlSheetVisible(false)}
          onImported={() => loadBooks()}
        />
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView
      style={{ flex: 1, backgroundColor: colors.background.primary }}
    >
      {renderHeader()}
      <View style={{ paddingHorizontal: spacing['2xl'], paddingBottom: spacing.md }}>
        <View
          style={{
            flexDirection: 'row',
            alignItems: 'center',
            backgroundColor: colors.fill.tertiary,
            borderRadius: radius.md,
            paddingHorizontal: spacing.md,
          }}
        >
          <IconSymbol
            name="magnifyingglass"
            size={18}
            color={colors.label.tertiary}
          />
          <TextInput
            testID="library-search"
            style={{
              flex: 1,
              marginLeft: spacing.sm,
              paddingVertical: 10,
              fontSize: typography.scale.body.fontSize,
              color: colors.label.primary,
            }}
            placeholder="Search library..."
            placeholderTextColor={colors.label.tertiary}
            value={searchQuery}
            onChangeText={setSearchQuery}
            autoCapitalize="none"
            autoCorrect={false}
            clearButtonMode="while-editing"
          />
        </View>
      </View>
      {lastReadBook && (
        <Pressable
          onPress={() => handleBookPress(lastReadBook)}
          style={({ pressed }) => ({
            marginHorizontal: spacing['2xl'],
            marginBottom: spacing.lg,
            padding: spacing.lg,
            backgroundColor: pressed ? colors.fill.tertiary : colors.fill.quaternary,
            borderRadius: radius.card,
            flexDirection: 'row',
            alignItems: 'center',
          })}
        >
          <View style={{ marginRight: spacing.md }}>
            <BookCover
              uri={lastReadBook.coverPath ?? undefined}
              title={lastReadBook.title}
              size="sm"
            />
          </View>
          <View style={{ flex: 1 }}>
            <Text
              style={{
                fontSize: typography.scale.caption.fontSize,
                lineHeight: typography.scale.caption.lineHeight,
                fontWeight: '600',
                color: colors.accent.primary,
                marginBottom: 2,
              }}
            >
              Reading Now
            </Text>
            <Text
              numberOfLines={1}
              style={{
                fontSize: typography.scale.subhead.fontSize,
                lineHeight: typography.scale.subhead.lineHeight,
                fontWeight: '600',
                color: colors.label.primary,
              }}
            >
              {lastReadBook.title}
            </Text>
            <Text
              numberOfLines={1}
              style={{
                fontSize: typography.scale.caption.fontSize,
                lineHeight: typography.scale.caption.lineHeight,
                color: colors.label.secondary,
              }}
            >
              {lastReadBook.author}
            </Text>
          </View>
          <IconSymbol
            name="chevron.right"
            size={18}
            color={colors.label.tertiary}
          />
        </Pressable>
      )}
      <View
        style={{ flex: 1 }}
        ref={gridTarget.ref as never}
        onLayout={gridTarget.onLayout}
      >
        <FlatList
          data={filteredBooks}
          keyExtractor={(item) => item.id}
          renderItem={({ item }) => (
            <BookRow
              book={item}
              onPress={handleBookPress}
              onDelete={handleDelete}
            />
          )}
          contentContainerStyle={{ paddingBottom: spacing['5xl'] }}
          ListEmptyComponent={
            searchQuery.trim() ? (
              <View
                testID="library-search-empty"
                style={{
                  paddingHorizontal: spacing['2xl'],
                  paddingVertical: spacing['2xl'],
                  alignItems: 'center',
                }}
              >
                <Text
                  style={{
                    fontSize: typography.scale.body.fontSize,
                    lineHeight: typography.scale.body.lineHeight,
                    color: colors.label.secondary,
                    textAlign: 'center',
                    marginBottom: spacing.lg,
                  }}
                >
                  {`No books match "${searchQuery}"`}
                </Text>
                <Pressable
                  testID="library-search-clear"
                  accessibilityRole="button"
                  accessibilityLabel="Clear search"
                  onPress={() => setSearchQuery('')}
                  hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                  style={({ pressed }) => ({
                    paddingHorizontal: spacing.lg,
                    paddingVertical: spacing.sm,
                    borderRadius: radius.full,
                    backgroundColor: colors.fill.tertiary,
                    opacity: pressed ? 0.6 : 1,
                  })}
                >
                  <Text
                    style={{
                      fontSize: typography.scale.body.fontSize,
                      lineHeight: typography.scale.body.lineHeight,
                      fontWeight: '600',
                      color: colors.accent.primary,
                    }}
                  >
                    Clear search
                  </Text>
                </Pressable>
              </View>
            ) : null
          }
        />
      </View>
      <UrlImportSheet
        visible={urlSheetVisible}
        onDismiss={() => setUrlSheetVisible(false)}
        onImported={() => loadBooks()}
      />
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  headerActions: {
    flexDirection: 'row',
    alignItems: 'center',
  },
})
