import { useCallback, useEffect, useRef, useState } from 'react'
import { View, Text, AppState, AppStateStatus, ActivityIndicator } from 'react-native'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { Reader, ReaderProvider, useReader } from '@epubjs-react-native/core'
import { useFileSystem } from '@epubjs-react-native/expo-file-system'
import BottomSheet from '@gorhom/bottom-sheet'
import { GestureHandlerRootView } from 'react-native-gesture-handler'

import { getBookForReading, updateBookCfi } from '@/lib/book-storage'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { ReaderToolbar } from '@/components/ReaderToolbar'
import { TocSheet } from '@/components/TocSheet'
import { AppearanceSheet } from '@/components/AppearanceSheet'
import { READER_THEMES } from '@/constants/reader-themes'
import { Book, ReaderSettings, ThemeName } from '@/types/book'

export default function ReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const [book, setBook] = useState<Book | null>(null)

  const [loading, setLoading] = useState(true)

  // Load book from DB (async -- may download file from R2 for synced books)
  useEffect(() => {
    if (id) {
      setLoading(true)
      getBookForReading(id)
        .then((loaded) => setBook(loaded))
        .catch((err) => console.error('Failed to load book for reading:', err))
        .finally(() => setLoading(false))
    }
  }, [id])

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" />
        <Text style={{ marginTop: 12, color: '#666' }}>Loading book...</Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    return (
      <View style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#666', fontSize: 16 }}>Book file not available</Text>
      </View>
    )
  }

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <ReaderProvider>
        <ReaderContent book={book} />
      </ReaderProvider>
    </GestureHandlerRootView>
  )
}

function ReaderContent({ book }: { book: Book }) {
  const router = useRouter()
  const { toc, goToLocation, changeTheme, changeFontSize, changeFontFamily } = useReader()

  const tocSheetRef = useRef<BottomSheet>(null)
  const appearanceSheetRef = useRef<BottomSheet>(null)

  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const [currentHref, setCurrentHref] = useState<string | null>(null)
  const currentCfiRef = useRef<string | null>(book.currentCfi)
  const cfiSaveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const theme = READER_THEMES[settings.themeName]

  // Save CFI on app background
  useEffect(() => {
    const handleAppStateChange = (nextState: AppStateStatus) => {
      if (nextState === 'background' || nextState === 'inactive') {
        if (book.id && currentCfiRef.current) {
          updateBookCfi(book.id, currentCfiRef.current)
        }
      }
    }
    const sub = AppState.addEventListener('change', handleAppStateChange)
    return () => sub.remove()
  }, [book.id])

  // Debounced CFI save on location change
  const handleLocationChange = useCallback(
    (_totalLocations: number, currentLocation: any, _progress: number) => {
      if (currentLocation?.start?.cfi) {
        currentCfiRef.current = currentLocation.start.cfi
        setCurrentHref(currentLocation.start.href || null)

        if (cfiSaveTimeoutRef.current) {
          clearTimeout(cfiSaveTimeoutRef.current)
        }
        cfiSaveTimeoutRef.current = setTimeout(() => {
          if (book.id && currentCfiRef.current) {
            updateBookCfi(book.id, currentCfiRef.current)
          }
        }, 500)
      }
    },
    [book.id]
  )

  // Toolbar toggle on tap
  const handleTap = useCallback(() => {
    setToolbarVisible((prev) => !prev)
  }, [])

  // Auto-hide toolbar after 3 seconds
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (toolbarVisible) {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
      toolbarTimerRef.current = setTimeout(() => setToolbarVisible(false), 3000)
    }
    return () => {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
    }
  }, [toolbarVisible])

  // Theme change
  const handleThemeChange = useCallback(
    (name: ThemeName) => {
      const newTheme = READER_THEMES[name]
      const newSettings = { ...settings, themeName: name }
      setSettings(newSettings)
      saveReaderSettings(newSettings)
      changeTheme({ body: { background: newTheme.background, color: newTheme.color } })
    },
    [settings, changeTheme]
  )

  // Font size change
  const handleFontSizeChange = useCallback(
    (size: number) => {
      const newSettings = { ...settings, fontSize: size }
      setSettings(newSettings)
      saveReaderSettings(newSettings)
      changeFontSize(`${size}%`)
    },
    [settings, changeFontSize]
  )

  // Font family change
  const handleFontFamilyChange = useCallback(
    (family: 'serif' | 'sans-serif') => {
      const newSettings = { ...settings, fontFamily: family }
      setSettings(newSettings)
      saveReaderSettings(newSettings)
      changeFontFamily(family)
    },
    [settings, changeFontFamily]
  )

  // TOC chapter selection
  const handleSelectChapter = useCallback(
    (href: string) => {
      goToLocation(href)
      tocSheetRef.current?.close()
    },
    [goToLocation]
  )

  // Back navigation -- save position before leaving
  const handleBack = useCallback(() => {
    if (book.id && currentCfiRef.current) {
      updateBookCfi(book.id, currentCfiRef.current)
    }
    router.back()
  }, [book.id, router])

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <Reader
        src={book.filePath}
        fileSystem={useFileSystem}
        flow="paginated"
        enableSwipe={true}
        enableSelection={false}
        initialLocation={book.currentCfi || undefined}
        defaultTheme={{
          body: {
            background: theme.background,
            color: theme.color,
          },
        }}
        onLocationChange={handleLocationChange}
        onSingleTap={handleTap}
      />

      <ReaderToolbar
        visible={toolbarVisible}
        title={book.title}
        theme={theme}
        onBack={handleBack}
        onTocPress={() => {
          tocSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
        onAppearancePress={() => {
          appearanceSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
      />

      <TocSheet
        sheetRef={tocSheetRef}
        toc={toc || []}
        currentHref={currentHref}
        theme={theme}
        onSelectChapter={handleSelectChapter}
      />

      <AppearanceSheet
        sheetRef={appearanceSheetRef}
        settings={settings}
        theme={theme}
        onThemeChange={handleThemeChange}
        onFontSizeChange={handleFontSizeChange}
        onFontFamilyChange={handleFontFamilyChange}
      />
    </View>
  )
}
