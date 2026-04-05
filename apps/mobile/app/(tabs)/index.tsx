import { useCallback, useEffect, useState } from 'react'
import { View, FlatList, TouchableOpacity, Alert, Text } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useRouter } from 'expo-router'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { BookRow } from '@/components/BookRow'
import { LibraryEmptyState } from '@/components/LibraryEmptyState'
import { getBooks } from '@/lib/book-storage'
import { importEpubFile } from '@/lib/file-import'
import { Book } from '@/types/book'

export default function LibraryScreen() {
  const router = useRouter()
  const [books, setBooks] = useState<Book[]>([])
  const [importing, setImporting] = useState(false)

  const loadBooks = useCallback(() => {
    const loaded = getBooks()
    setBooks(loaded)
  }, [])

  useEffect(() => {
    loadBooks()
  }, [loadBooks])

  const handleImport = useCallback(async () => {
    setImporting(true)
    try {
      const book = await importEpubFile()
      if (book) {
        loadBooks()
      }
    } catch (error) {
      Alert.alert(
        'Import Failed',
        'Could not import book. The file may be corrupted or not a valid EPUB.'
      )
      console.error('Import error:', error)
    } finally {
      setImporting(false)
    }
  }, [loadBooks])

  const handleBookPress = useCallback(
    (book: Book) => {
      router.push(`/reader/${book.id}`)
    },
    [router]
  )

  if (books.length === 0) {
    return (
      <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
        <LibraryEmptyState onImport={handleImport} importing={importing} />
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
      <View className="px-6 pt-4 pb-2">
        <Text className="text-2xl font-semibold text-gray-900 dark:text-white">
          Library
        </Text>
      </View>
      <FlatList
        data={books}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => (
          <BookRow book={item} onPress={handleBookPress} />
        )}
        contentContainerClassName="pb-24"
      />
      {/* FAB for importing when library has books */}
      <TouchableOpacity
        className="absolute bottom-6 right-6 w-14 h-14 rounded-full bg-[#0a7ea4] items-center justify-center shadow-lg"
        onPress={handleImport}
        disabled={importing}
        accessibilityRole="button"
        accessibilityLabel="Import Book"
      >
        <IconSymbol name="plus" size={24} color="#FFFFFF" />
      </TouchableOpacity>
    </SafeAreaView>
  )
}
