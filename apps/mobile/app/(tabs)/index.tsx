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
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'
import { BookRow } from '@/components/BookRow'
import { LibraryEmptyState } from '@/components/LibraryEmptyState'
import { getBooks, deleteBook, getLastReadBook } from '@/lib/book-storage'
import {
  importBookFile,
  type ImportFailureStage,
} from '@/lib/file-import'
import { Book } from '@/types/book'
import { useTourTargetLayout } from '@/lib/onboarding/useTourTarget'
import { useTheme } from '@/lib/theme'
import { formatReadingNowProgress } from '@/lib/reading-now-progress'

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
  // P1-AB: gate the empty / populated branches on the first load so we
  // don't flash "No books yet" while getBooks() is still settling.
  const [hasLoadedOnce, setHasLoadedOnce] = useState(false)

  // Tour targets (G28): the import button and the library grid get
  // registered with `lib/onboarding/registry` so the first-launch
  // tutorial can spotlight them.
  const importTarget = useTourTargetLayout('import-books')
  const gridTarget = useTourTargetLayout('book-grid')

  // #32 — When a "Reading Now" card is surfaced above the list we
  // must NOT also render the same book as a FlatList row, otherwise
  // the user sees a small cover + chevron (the card) directly above a
  // larger cover + title + delete row (the list cell) and reads it as
  // one broken entry whose cover is duplicated. We always drop the
  // last-read book from the list — the Reading Now card is its single
  // surface. If a search query is active, scoring still happens over
  // the de-duplicated set so the card+row pair never reappears.
  const filteredBooks = useMemo(() => {
    const base = lastReadBook
      ? books.filter((book) => book.id !== lastReadBook.id)
      : books
    if (!searchQuery.trim()) return base
    const query = searchQuery.toLowerCase()
    return base.filter(
      (book) =>
        book.title.toLowerCase().includes(query) ||
        (book.author && book.author.toLowerCase().includes(query))
    )
  }, [books, lastReadBook, searchQuery])

  const loadBooks = useCallback(() => {
    const loaded = getBooks()
    setBooks(loaded)
    setLastReadBook(getLastReadBook())
    setHasLoadedOnce(true)
  }, [])

  useFocusEffect(
    useCallback(() => {
      loadBooks()
    }, [loadBooks])
  )

  // P0-K: map an import failure stage to user-facing copy. The
  // 'picker-cancel' stage is silently swallowed — the user already
  // knows they backed out of the picker.
  const importErrorCopy = useCallback(
    (stage: ImportFailureStage, format: string): string | null => {
      const fmt = format.toUpperCase()
      switch (stage) {
        case 'picker-cancel':
          return null
        case 'parse':
        case 'unsupported':
          return `This file looks corrupted or isn't a valid ${fmt}. Try a different copy of the book.`
        case 'storage-full':
          return 'Your device is out of storage. Free up some space and try again.'
        case 'permission':
          return "Rishi doesn't have permission to read that file. Check the app's file-access settings."
        case 'network':
          return 'Could not download the book. Check your connection and try again.'
        case 'duplicate':
          return 'You already have this book in your library.'
        case 'copy':
        case 'save':
        case 'unknown':
        default:
          return `Could not import the ${fmt}. Please try again.`
      }
    },
    [],
  )

  const handleImport = useCallback(async () => {
    setImporting(true)
    try {
      const result = await importBookFile()
      if (result.ok) {
        loadBooks()
      } else {
        const message = importErrorCopy(result.stage, 'book')
        if (message) {
          Alert.alert('Import Failed', message)
        }
        console.warn(
          `[library] import failed at stage=${result.stage}: ${result.error}`,
        )
      }
    } catch (error) {
      Alert.alert(
        'Import Failed',
        'Could not import the book. Please try again.',
      )
      console.error('Import error:', error)
    } finally {
      setImporting(false)
    }
  }, [loadBooks, importErrorCopy])

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

  // P1-AF — Virtualize the library list for users with 1000+ books.
  // BookRow is a fixed-height cell: the row body is `delete-button` (44pt)
  // plus 2 × spacing.lg padding, trailed by a 1pt Hairline. We pin a
  // single constant so `getItemLayout` can skip the on-mount measurement
  // pass that was tanking scroll perf in QA.
  const BOOK_ROW_HEIGHT = 88
  const getBookRowLayout = useCallback(
    (_data: ArrayLike<Book> | null | undefined, index: number) => ({
      length: BOOK_ROW_HEIGHT,
      offset: BOOK_ROW_HEIGHT * index,
      index,
    }),
    [],
  )

  // #112 / PRF-008 — keep `keyExtractor` and `renderItem` identities
  // stable across parent re-renders. The search input drives a
  // setState on every keystroke; if these callbacks were inline they
  // would be fresh closures each frame and React Native's
  // VirtualizedList would treat that as a cell-shape change and
  // remount every BookRow. Stable identities ➜ the only thing that
  // changes is `data`, so unaffected cells stay mounted.
  const bookKeyExtractor = useCallback((item: Book) => item.id, [])
  const renderBookRow = useCallback(
    ({ item }: { item: Book }) => (
      <BookRow
        book={item}
        onPress={handleBookPress}
        onDelete={handleDelete}
      />
    ),
    [handleBookPress, handleDelete],
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
          accessibilityLabel="Add book"
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

  // P1-AB: render the skeleton placeholder until the FIRST load
  // resolves. This avoids flashing the "No books yet" empty state for
  // a frame on cold launches.
  if (!hasLoadedOnce) {
    const placeholderKeys = ['s0', 's1', 's2', 's3', 's4']
    return (
      <SafeAreaView
        style={{ flex: 1, backgroundColor: colors.background.primary }}
      >
        {renderHeader()}
        <View
          testID="library-skeleton"
          style={{ paddingHorizontal: spacing['2xl'], paddingTop: spacing.lg }}
        >
          {placeholderKeys.map((key) => (
            <View
              key={key}
              testID={`library-skeleton-row-${key}`}
              style={{
                height: 72,
                marginBottom: spacing.md,
                borderRadius: radius.md,
                backgroundColor: colors.fill.tertiary,
              }}
            />
          ))}
        </View>
      </SafeAreaView>
    )
  }

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
              testID="reading-now-cover"
              uri={lastReadBook.coverPath ?? undefined}
              title={lastReadBook.title}
              size="sm"
              // #96 / STA-021 — when the book's cover hasn't been
              // extracted yet (coverPath null) AND extraction has not
              // been attempted-and-failed, render the dashed "pending"
              // placeholder instead of the hash-based letter tile so
              // the user can tell "cover loading" from "no cover".
              loading={
                lastReadBook.coverPath == null &&
                lastReadBook.coverExtractionFailed !== true
              }
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
            {(() => {
              // #41 — Format-aware progress subline. The formatter returns
              // null for legacy rows with no progress data; in that case
              // we render no extra Text node so we don't surface a stale
              // or misleading "0%" label.
              const progressSubline = formatReadingNowProgress({
                format: lastReadBook.format,
                currentPage: lastReadBook.currentPage,
                lastProgressPercent: lastReadBook.lastProgressPercent,
              })
              if (!progressSubline) return null
              return (
                <Text
                  testID="library-reading-now-progress"
                  accessibilityLabel={`Progress: ${progressSubline}`}
                  numberOfLines={1}
                  style={{
                    fontSize: typography.scale.caption.fontSize,
                    lineHeight: typography.scale.caption.lineHeight,
                    color: colors.label.tertiary,
                    marginTop: 2,
                  }}
                >
                  {progressSubline}
                </Text>
              )
            })()}
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
          keyExtractor={bookKeyExtractor}
          renderItem={renderBookRow}
          contentContainerStyle={{ paddingBottom: spacing['5xl'] }}
          getItemLayout={getBookRowLayout}
          removeClippedSubviews
          windowSize={10}
          initialNumToRender={12}
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
