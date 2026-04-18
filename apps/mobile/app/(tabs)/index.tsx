import { useCallback, useMemo, useState } from 'react'
import { View, FlatList, TouchableOpacity, Alert, Text, TextInput, Image, Pressable } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useRouter, useFocusEffect } from 'expo-router'
import { Directory, Paths } from 'expo-file-system'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'
import { BookRow } from '@/components/BookRow'
import { LibraryEmptyState } from '@/components/LibraryEmptyState'
import { UrlImportSheet } from '@/components/UrlImportSheet'
import { getBooks, deleteBook, getLastReadBook } from '@/lib/book-storage'
import { importEpubFile, importPdfFile, importMobiFile, importDjvuFile } from '@/lib/file-import'
import { Book } from '@/types/book'

export default function LibraryScreen() {
  const router = useRouter()
  const [books, setBooks] = useState<Book[]>([])
  const [lastReadBook, setLastReadBook] = useState<Book | null>(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [importing, setImporting] = useState(false)
  const [urlSheetVisible, setUrlSheetVisible] = useState(false)

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
              // Delete from DB
              deleteBook(book.id)
              // Delete book files from disk
              const bookDir = new Directory(
                new Directory(Paths.document, 'books'),
                book.id
              )
              if (bookDir.exists) {
                bookDir.delete()
              }
              // Reload library
              loadBooks()
            },
          },
        ]
      )
    },
    [loadBooks]
  )

  if (books.length === 0) {
    return (
      <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
        <LibraryEmptyState onImport={handleImport} importing={importing} />
        <UrlImportSheet visible={urlSheetVisible} onDismiss={() => setUrlSheetVisible(false)} onImported={() => loadBooks()} />
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
        <View className="px-6 pt-4 pb-2 flex-row items-center justify-between">
          <Text testID="library-title" className="text-2xl font-semibold text-gray-900 dark:text-white">
            Library
          </Text>
          <SyncStatusIndicator />
        </View>
        <View className="px-6 pb-3">
          <View className="flex-row items-center bg-gray-100 dark:bg-gray-800 rounded-lg px-3">
            <IconSymbol name="magnifyingglass" size={18} color="#9CA3AF" />
            <TextInput
              testID="library-search"
              className="flex-1 ml-2 py-2.5 text-base text-gray-900 dark:text-white"
              placeholder="Search library..."
              placeholderTextColor="#9CA3AF"
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
            className="mx-6 mb-4 p-4 bg-gray-50 dark:bg-gray-800 rounded-xl flex-row items-center"
            onPress={() => handleBookPress(lastReadBook)}
          >
            {lastReadBook.coverPath ? (
              <Image source={{ uri: lastReadBook.coverPath }} className="w-10 h-14 rounded mr-3" resizeMode="cover" />
            ) : (
              <View className="w-10 h-14 rounded mr-3 bg-gray-200 dark:bg-gray-700 items-center justify-center">
                <Text className="text-gray-400 text-xs">{lastReadBook.format.toUpperCase()}</Text>
              </View>
            )}
            <View className="flex-1">
              <Text className="text-xs text-[#0a7ea4] font-semibold mb-0.5">Reading Now</Text>
              <Text className="text-sm font-semibold text-gray-900 dark:text-white" numberOfLines={1}>{lastReadBook.title}</Text>
              <Text className="text-xs text-gray-500 dark:text-gray-400" numberOfLines={1}>{lastReadBook.author}</Text>
            </View>
            <IconSymbol name="chevron.right" size={18} color="#9CA3AF" />
          </Pressable>
        )}
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
          contentContainerClassName="pb-24"
        />
        {/* FAB for importing when library has books */}
        <TouchableOpacity
          testID="import-book-fab"
          className="absolute bottom-6 right-6 w-14 h-14 rounded-full bg-[#0a7ea4] items-center justify-center shadow-lg"
          onPress={handleImport}
          disabled={importing}
          accessibilityRole="button"
          accessibilityLabel="Import Book"
        >
          <IconSymbol name="plus" size={24} color="#FFFFFF" />
        </TouchableOpacity>
        <UrlImportSheet visible={urlSheetVisible} onDismiss={() => setUrlSheetVisible(false)} onImported={() => loadBooks()} />
      </SafeAreaView>
  )
}
