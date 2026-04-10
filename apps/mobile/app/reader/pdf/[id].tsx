import { useCallback, useEffect, useRef, useState } from 'react'
import {
  View,
  Text,
  TouchableOpacity,
  AppState,
  AppStateStatus,
  Dimensions,
  Alert,
  Platform,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useLocalSearchParams, useRouter } from 'expo-router'
import Pdf from 'react-native-pdf'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { getBookForReading, updateBookPage } from '@/lib/book-storage'
import { Book } from '@/types/book'
import { ThumbnailModal } from './thumbnail-modal'

export default function PdfReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const [book, setBook] = useState<Book | null>(null)
  const [currentPage, setCurrentPage] = useState(1)
  const [targetPage, setTargetPage] = useState<number | null>(null)
  const [totalPages, setTotalPages] = useState(0)
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const [thumbnailModalVisible, setThumbnailModalVisible] = useState(false)

  const currentPageRef = useRef(1)
  const pageSaveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const [loading, setLoading] = useState(true)

  // Load book from DB (async -- may download file from R2 for synced books)
  useEffect(() => {
    if (id) {
      setLoading(true)
      getBookForReading(id)
        .then((loaded) => {
          if (loaded) {
            setBook(loaded)
            const startPage = loaded.currentPage || 1
            setCurrentPage(startPage)
            setTargetPage(startPage)
            currentPageRef.current = startPage
          }
        })
        .catch((err) => console.error('Failed to load book for reading:', err))
        .finally(() => setLoading(false))
    }
  }, [id])

  // Save page position on app background
  useEffect(() => {
    const handleAppStateChange = (nextState: AppStateStatus) => {
      if (nextState === 'background' || nextState === 'inactive') {
        if (book?.id && currentPageRef.current) {
          updateBookPage(book.id, currentPageRef.current)
        }
      }
    }
    const sub = AppState.addEventListener('change', handleAppStateChange)
    return () => sub.remove()
  }, [book?.id])

  // Auto-hide toolbar after 3 seconds
  useEffect(() => {
    if (toolbarVisible) {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
      toolbarTimerRef.current = setTimeout(() => setToolbarVisible(false), 3000)
    }
    return () => {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
    }
  }, [toolbarVisible])

  // Debounced page save on page change
  const handlePageChange = useCallback(
    (page: number) => {
      currentPageRef.current = page
      setCurrentPage(page)

      if (pageSaveTimeoutRef.current) {
        clearTimeout(pageSaveTimeoutRef.current)
      }
      pageSaveTimeoutRef.current = setTimeout(() => {
        if (book?.id) {
          updateBookPage(book.id, page)
        }
      }, 500)
    },
    [book?.id]
  )

  // Back navigation -- save position before leaving
  const handleBack = useCallback(() => {
    if (book?.id && currentPageRef.current) {
      updateBookPage(book.id, currentPageRef.current)
    }
    router.back()
  }, [book?.id, router])

  // Toggle toolbar on tap
  const handleTap = useCallback(() => {
    setToolbarVisible((prev) => !prev)
  }, [])

  // Go to specific page via prompt
  const handleGoToPage = useCallback(() => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        'Go to Page',
        `Enter a page number (1-${totalPages})`,
        (text) => {
          const page = parseInt(text, 10)
          if (page >= 1 && page <= totalPages) {
            setTargetPage(page)
          }
        },
        'plain-text',
        String(currentPageRef.current)
      )
    } else {
      // Android fallback: simple alert with instruction
      Alert.alert('Go to Page', `Current page: ${currentPageRef.current} of ${totalPages}`)
    }
  }, [totalPages])

  // Navigate to selected thumbnail page
  const handleThumbnailSelect = useCallback((page: number) => {
    setTargetPage(page)
    setThumbnailModalVisible(false)
  }, [])

  // Navigate to previous page
  const handlePrevPage = useCallback(() => {
    if (currentPageRef.current > 1) {
      setTargetPage(currentPageRef.current - 1)
    }
  }, [])

  // Navigate to next page
  const handleNextPage = useCallback(() => {
    if (currentPageRef.current < totalPages) {
      setTargetPage(currentPageRef.current + 1)
    }
  }, [totalPages])

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#fff', fontSize: 16 }}>Loading book...</Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    return (
      <View style={{ flex: 1, backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#fff', fontSize: 16 }}>Book file not available</Text>
      </View>
    )
  }

  return (
    <View testID="pdf-reader" style={{ flex: 1, backgroundColor: '#000' }}>
      <TouchableOpacity
        activeOpacity={1}
        onPress={handleTap}
        style={{ flex: 1 }}
      >
        <Pdf
          source={{ uri: book.filePath }}
          page={targetPage || 1}
          horizontal={true}
          enablePaging={true}
          onLoadComplete={(numberOfPages) => setTotalPages(numberOfPages)}
          onPageChanged={(page) => handlePageChange(page)}
          onError={(error) => console.error('PDF error:', error)}
          style={{ flex: 1, width: Dimensions.get('window').width }}
          trustAllCerts={false}
        />
      </TouchableOpacity>

      {/* Top toolbar */}
      {toolbarVisible && (
        <SafeAreaView
          edges={['top']}
          style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            backgroundColor: 'rgba(0,0,0,0.7)',
          }}
        >
          <View
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              paddingHorizontal: 12,
              paddingVertical: 10,
            }}
          >
            <TouchableOpacity
              onPress={handleBack}
              hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
              style={{ width: 44, height: 44, justifyContent: 'center', alignItems: 'center' }}
            >
              <IconSymbol name="chevron.left" size={24} color="#fff" />
            </TouchableOpacity>

            <Text
              numberOfLines={1}
              style={{
                flex: 1,
                color: '#fff',
                fontSize: 16,
                fontWeight: '600',
                textAlign: 'center',
                marginHorizontal: 8,
              }}
            >
              {book.title}
            </Text>

            <Text style={{ color: '#fff', fontSize: 13, minWidth: 70, textAlign: 'right' }}>
              Page {currentPage} of {totalPages}
            </Text>
          </View>
        </SafeAreaView>
      )}

      {/* Bottom navigation bar */}
      {toolbarVisible && (
        <SafeAreaView
          edges={['bottom']}
          style={{
            position: 'absolute',
            bottom: 0,
            left: 0,
            right: 0,
            backgroundColor: 'rgba(0,0,0,0.7)',
          }}
        >
          <View
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'center',
              paddingVertical: 10,
              gap: 24,
            }}
          >
            <TouchableOpacity
              onPress={() => {
                setThumbnailModalVisible(true)
                setToolbarVisible(false)
              }}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
              }}
            >
              <IconSymbol name="square.grid.2x2" size={24} color="#fff" />
            </TouchableOpacity>

            <TouchableOpacity
              onPress={handlePrevPage}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentPage <= 1 ? 0.3 : 1,
              }}
              disabled={currentPage <= 1}
            >
              <IconSymbol name="chevron.left" size={28} color="#fff" />
            </TouchableOpacity>

            <TouchableOpacity onPress={handleGoToPage}>
              <Text style={{ color: '#fff', fontSize: 16, fontWeight: '500' }}>
                {currentPage} / {totalPages}
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              onPress={handleNextPage}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentPage >= totalPages ? 0.3 : 1,
              }}
              disabled={currentPage >= totalPages}
            >
              <IconSymbol name="chevron.right" size={28} color="#fff" />
            </TouchableOpacity>
          </View>
        </SafeAreaView>
      )}
      {book?.filePath && (
        <ThumbnailModal
          visible={thumbnailModalVisible}
          onClose={() => setThumbnailModalVisible(false)}
          onSelectPage={handleThumbnailSelect}
          filePath={book.filePath}
          totalPages={totalPages}
          currentPage={currentPage}
        />
      )}
    </View>
  )
}
