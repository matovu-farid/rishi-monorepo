import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, TextInput, FlatList, Pressable, AppState, AppStateStatus, ActivityIndicator, AccessibilityInfo } from 'react-native'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { Reader, ReaderProvider, useReader } from '@epubjs-react-native/core'
import { useFileSystem } from '@epubjs-react-native/expo-file-system'
import BottomSheet from '@gorhom/bottom-sheet'
import { GestureHandlerRootView } from 'react-native-gesture-handler'

import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { getBookForReading, updateBookCfi } from '@/lib/book-storage'
import { loadReaderSettings, saveReaderSettings } from '@/lib/reader-settings'
import { insertHighlight, getHighlightsByBookId, updateHighlight, deleteHighlight } from '@/lib/highlight-storage'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ReaderToolbar } from '@/components/ReaderToolbar'
import { TTSControls } from '@/components/TTSControls'
import { useTTSPlayer } from '@/hooks/useTTSPlayer'
import { useRealtimeChat } from '@/hooks/useRealtimeChat'
import { GuardrailWarning } from '@/components/GuardrailWarning'
import { TocSheet } from '@/components/TocSheet'
import { AppearanceSheet } from '@/components/AppearanceSheet'
import { HighlightsSheet } from '@/components/HighlightsSheet'
import { NoteEditor } from '@/components/NoteEditor'
import { AnnotationPopover } from '@/components/AnnotationPopover'
import { READER_THEMES } from '@/constants/reader-themes'
import { Book, ReaderSettings, ThemeName } from '@/types/book'
import type { Highlight, HighlightColor } from '@/types/highlight'
import { HIGHLIGHT_COLORS, HIGHLIGHT_OPACITY } from '@/types/highlight'
import type { Annotation } from '@epubjs-react-native/core'

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
      <View testID="reader-loading" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" />
        <Text style={{ marginTop: 12, color: '#666' }}>Loading book...</Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    return (
      <View testID="reader-error" style={{ flex: 1, backgroundColor: '#FFFFFF', justifyContent: 'center', alignItems: 'center' }}>
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
  const insets = useSafeAreaInsets()
  const {
    toc,
    goToLocation,
    changeTheme,
    changeFontSize,
    changeFontFamily,
    addAnnotation,
    removeAnnotationByCfi,
    search,
    searchResults,
    clearSearchResults,
    isSearching,
  } = useReader()

  const tocSheetRef = useRef<BottomSheet>(null)
  const appearanceSheetRef = useRef<BottomSheet>(null)
  const highlightsSheetRef = useRef<BottomSheet>(null)
  const noteEditorSheetRef = useRef<BottomSheet>(null)
  const searchSheetRef = useRef<BottomSheet>(null)

  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings())
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [currentHref, setCurrentHref] = useState<string | null>(null)
  const currentCfiRef = useRef<string | null>(book.currentCfi)
  const cfiSaveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Highlight state
  const [highlights, setHighlights] = useState<Highlight[]>([])
  const [selectedHighlight, setSelectedHighlight] = useState<Highlight | null>(null)
  const [popoverVisible, setPopoverVisible] = useState(false)
  const [popoverPosition, setPopoverPosition] = useState({ x: 0, y: 0 })

  // TTS playback
  const tts = useTTSPlayer(book.id, book.filePath, book.format as 'epub' | 'pdf')

  // Realtime voice chat
  const { status: realtimeStatus, showGuardrailWarning, toggle: toggleRealtime, isActive: realtimeActive } = useRealtimeChat(book.id)

  const theme = READER_THEMES[settings.themeName]

  // Load highlights on mount
  useEffect(() => {
    if (book.id) {
      setHighlights(getHighlightsByBookId(book.id))
    }
  }, [book.id])

  // Convert highlights to initialAnnotations for Reader
  const initialAnnotations = useMemo(
    () =>
      highlights.map((h) => ({
        type: 'highlight' as const,
        cfiRange: h.cfiRange,
        data: { id: h.id },
        sectionIndex: 0,
        cfiRangeText: h.text,
        styles: {
          color: HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24',
          opacity: HIGHLIGHT_OPACITY,
        },
      })),
    [highlights]
  )

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

  // Toolbar toggle on tap (dismiss popover if visible)
  const handleTap = useCallback(() => {
    if (popoverVisible) {
      setPopoverVisible(false)
      return
    }
    setToolbarVisible((prev) => !prev)
  }, [popoverVisible])

  // Auto-hide toolbar after 3 seconds (disabled when TTS or realtime voice is active)
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (toolbarVisible && !tts.isActive && !realtimeActive) {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
      toolbarTimerRef.current = setTimeout(() => setToolbarVisible(false), 3000)
    }
    return () => {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
    }
  }, [toolbarVisible, tts.isActive, realtimeActive])

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

  // --- Highlight handlers ---

  // Text selection creates a highlight
  const handleSelected = useCallback(
    (selectedText: string, cfiRange: string) => {
      const h = insertHighlight({
        bookId: book.id,
        cfiRange,
        text: selectedText,
        color: 'yellow',
        note: null,
        chapter: currentHref || null,
      })
      const hex = HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24'
      addAnnotation('highlight', cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
      setHighlights((prev) => [h, ...prev])
      AccessibilityInfo.announceForAccessibility('Highlight created')
    },
    [book.id, currentHref, addAnnotation]
  )

  // Menu items for text selection context menu
  const menuItems = useMemo(
    () => [
      {
        label: 'Highlight Text',
        action: (cfiRange: string, text: string) => {
          handleSelected(text, cfiRange)
          return true // dismiss selection
        },
      },
      {
        label: 'Highlight & Note',
        action: (cfiRange: string, text: string) => {
          const h = insertHighlight({
            bookId: book.id,
            cfiRange,
            text,
            color: 'yellow',
            note: null,
            chapter: currentHref || null,
          })
          const hex = HIGHLIGHT_COLORS.find((c) => c.name === h.color)?.hex ?? '#FBBF24'
          addAnnotation('highlight', cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
          setHighlights((prev) => [h, ...prev])
          setSelectedHighlight(h)
          AccessibilityInfo.announceForAccessibility('Highlight created')
          // Open note editor after a brief delay to let state settle
          setTimeout(() => noteEditorSheetRef.current?.snapToIndex(0), 100)
          return true
        },
      },
    ],
    [book.id, currentHref, addAnnotation, handleSelected]
  )

  // Tapping an existing annotation shows the popover
  const handlePressAnnotation = useCallback(
    (annotation: Annotation) => {
      const match = highlights.find(
        (h) => h.cfiRange === annotation.cfiRange || (annotation.data as any)?.id === h.id
      )
      if (match) {
        setSelectedHighlight(match)
        // Position popover roughly in center-top area of screen since we don't get pixel coords
        const screenWidth = require('react-native').Dimensions.get('window').width
        const screenHeight = require('react-native').Dimensions.get('window').height
        setPopoverPosition({ x: screenWidth / 2, y: screenHeight * 0.35 })
        setPopoverVisible(true)
      }
    },
    [highlights]
  )

  // Annotation popover: edit note
  const handleEditNote = useCallback((highlight: Highlight) => {
    setPopoverVisible(false)
    setSelectedHighlight(highlight)
    noteEditorSheetRef.current?.snapToIndex(0)
  }, [])

  // Annotation popover: change color
  const handleChangeColor = useCallback(
    (highlightId: string, color: HighlightColor) => {
      updateHighlight(highlightId, { color })
      const updated = getHighlightsByBookId(book.id)
      setHighlights(updated)
      setPopoverVisible(false)
      // Re-render annotation with new color
      const h = highlights.find((h) => h.id === highlightId)
      if (h) {
        removeAnnotationByCfi(h.cfiRange)
        const hex = HIGHLIGHT_COLORS.find((c) => c.name === color)?.hex ?? '#FBBF24'
        addAnnotation('highlight', h.cfiRange, { id: h.id }, { color: hex, opacity: HIGHLIGHT_OPACITY })
      }
    },
    [book.id, highlights, addAnnotation, removeAnnotationByCfi]
  )

  // Delete highlight
  const handleDeleteHighlight = useCallback(
    (highlightId: string) => {
      const h = highlights.find((h) => h.id === highlightId)
      deleteHighlight(highlightId)
      if (h) removeAnnotationByCfi(h.cfiRange)
      setHighlights(getHighlightsByBookId(book.id))
      setPopoverVisible(false)
    },
    [book.id, highlights, removeAnnotationByCfi]
  )

  // Save note
  const handleSaveNote = useCallback(
    (highlightId: string, note: string) => {
      updateHighlight(highlightId, { note: note || null })
      setHighlights(getHighlightsByBookId(book.id))
      noteEditorSheetRef.current?.close()
    },
    [book.id]
  )

  // Navigate to highlight from list
  const handleNavigateToHighlight = useCallback(
    (cfiRange: string) => {
      goToLocation(cfiRange)
      highlightsSheetRef.current?.close()
    },
    [goToLocation]
  )

  // Search handlers
  const handleSearch = useCallback(
    (query: string) => {
      setSearchQuery(query)
      if (query.trim().length > 1) {
        search(query.trim())
      } else {
        clearSearchResults()
      }
    },
    [search, clearSearchResults]
  )

  const handleSearchResultPress = useCallback(
    (cfi: string) => {
      goToLocation(cfi)
      searchSheetRef.current?.close()
    },
    [goToLocation]
  )

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <Reader
        src={book.filePath}
        fileSystem={useFileSystem}
        flow="paginated"
        enableSwipe={true}
        enableSelection={true}
        initialLocation={book.currentCfi || undefined}
        defaultTheme={{
          body: {
            background: theme.background,
            color: theme.color,
          },
        }}
        menuItems={menuItems}
        initialAnnotations={initialAnnotations}
        onLocationChange={handleLocationChange}
        onSingleTap={handleTap}
        onPressAnnotation={handlePressAnnotation}
      />

      <ReaderToolbar
        visible={toolbarVisible}
        title={book.title}
        theme={theme}
        onBack={handleBack}
        onSearchPress={() => {
          searchSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
        onTocPress={() => {
          tocSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
        onHighlightsPress={() => {
          highlightsSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
        onAppearancePress={() => {
          appearanceSheetRef.current?.snapToIndex(0)
          setToolbarVisible(false)
        }}
        onChatPress={() => router.push(`/chat/${book.id}`)}
        onTTSPress={() => tts.isActive ? tts.stop() : tts.play()}
        ttsActive={tts.isActive}
        onRealtimePress={toggleRealtime}
        realtimeStatus={realtimeStatus}
      />

      <View style={{ position: 'absolute', top: insets.top + 48 + 8, left: 16, right: 16, zIndex: 11 }}>
        <GuardrailWarning visible={showGuardrailWarning} />
      </View>

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

      <HighlightsSheet
        sheetRef={highlightsSheetRef}
        highlights={highlights}
        theme={theme}
        onNavigateToHighlight={handleNavigateToHighlight}
        onDeleteHighlight={handleDeleteHighlight}
      />

      <NoteEditor
        sheetRef={noteEditorSheetRef}
        highlight={selectedHighlight}
        theme={theme}
        onSave={handleSaveNote}
        onDiscard={() => noteEditorSheetRef.current?.close()}
      />

      <BottomSheet
        ref={searchSheetRef}
        index={-1}
        snapPoints={['50%', '90%']}
        enablePanDownToClose
        backgroundStyle={{ backgroundColor: theme.background }}
        handleIndicatorStyle={{ backgroundColor: theme.toolbarText }}
      >
        <View style={{ flex: 1, paddingHorizontal: 16 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', backgroundColor: theme.name === 'dark' ? '#374151' : '#F3F4F6', borderRadius: 8, paddingHorizontal: 12, marginBottom: 12 }}>
            <IconSymbol name="magnifyingglass" size={18} color="#9CA3AF" />
            <TextInput
              style={{ flex: 1, marginLeft: 8, paddingVertical: 10, fontSize: 16, color: theme.color }}
              placeholder="Search in book..."
              placeholderTextColor="#9CA3AF"
              value={searchQuery}
              onChangeText={handleSearch}
              autoCapitalize="none"
              autoCorrect={false}
              returnKeyType="search"
            />
          </View>
          {isSearching && (
            <View style={{ alignItems: 'center', paddingVertical: 16 }}>
              <ActivityIndicator size="small" />
              <Text style={{ color: '#9CA3AF', marginTop: 8, fontSize: 14 }}>Searching...</Text>
            </View>
          )}
          {!isSearching && searchResults.results.length > 0 && (
            <FlatList
              data={searchResults.results}
              keyExtractor={(_, idx) => String(idx)}
              renderItem={({ item }) => (
                <Pressable
                  onPress={() => handleSearchResultPress(item.cfi)}
                  style={{ paddingVertical: 12, paddingHorizontal: 4, borderBottomWidth: 1, borderBottomColor: theme.name === 'dark' ? '#374151' : '#E5E7EB' }}
                >
                  <Text style={{ color: theme.color, fontSize: 14 }} numberOfLines={2}>{item.excerpt}</Text>
                  {item.section?.label && (
                    <Text style={{ color: '#9CA3AF', fontSize: 12, marginTop: 4 }}>{item.section.label}</Text>
                  )}
                </Pressable>
              )}
            />
          )}
          {!isSearching && searchQuery.length > 1 && searchResults.results.length === 0 && (
            <Text style={{ color: '#9CA3AF', textAlign: 'center', paddingVertical: 24, fontSize: 14 }}>No results found</Text>
          )}
        </View>
      </BottomSheet>

      {tts.isActive && (
        <TTSControls
          status={tts.status as 'loading' | 'playing' | 'paused'}
          currentChunkIndex={tts.currentChunkIndex}
          totalChunks={tts.totalChunks}
          onPlay={tts.play}
          onPause={tts.pause}
          onStop={tts.stop}
          onNext={tts.next}
          onPrevious={tts.previous}
        />
      )}

      {popoverVisible && selectedHighlight && (
        <AnnotationPopover
          visible={popoverVisible}
          highlight={selectedHighlight}
          position={popoverPosition}
          theme={theme}
          onEditNote={handleEditNote}
          onChangeColor={handleChangeColor}
          onDelete={handleDeleteHighlight}
          onDismiss={() => setPopoverVisible(false)}
        />
      )}
    </View>
  )
}
