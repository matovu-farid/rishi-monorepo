import React, {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { View } from 'react-native'

import { ReaderTopBar } from '@/components/reader/ReaderTopBar'
import { ReaderBottomBar } from '@/components/reader/ReaderBottomBar'
import { ReaderOverlay } from '@/components/reader/ReaderOverlay'
import type { ReaderProgress } from '@/components/reader/ReaderProgressPill'
import { useAuthStore } from '@/lib/stores/authStore'
import { usePrefsStore } from '@/lib/stores/prefsStore'
import type { ActivationContext } from '@/lib/stores/chatStore'

import { AppearanceSheet } from '@/components/AppearanceSheet'
import { TocSheet } from '@/components/TocSheet'
import { HighlightsSheet } from '@/components/HighlightsSheet'
import { BookmarksList } from '@/components/epub/BookmarksList'
import { SearchPanel } from '@/components/epub/SearchPanel'
import { NoteEditor, type NoteEditableHighlight } from '@/components/NoteEditor'

import type { ReaderSettings, ThemeName } from '@/types/book'
import type { Highlight } from '@/types/highlight'
import type { Bookmark } from '@/lib/bookmarks/bookmark-storage'
import type { SearchResult } from '@/components/epub/SearchPanel'
import type { RealtimeStatus } from '@/lib/realtime/types'

export type ReaderFormat = 'epub' | 'pdf' | 'mobi' | 'djvu'

export type { ReaderProgress }

export interface ReaderShellSheets {
  toc?: boolean
  highlights?: boolean
  bookmarks?: boolean
  search?: boolean
  appearance?: boolean
  noteEditor?: boolean
}

export interface TocItem {
  id?: string
  href: string
  label: string
  subitems?: TocItem[]
}

export interface ReaderShellContextValue {
  bottomBarVisible: boolean
  toggleToolbar: () => void
}

export const ReaderShellContext = createContext<ReaderShellContextValue>({
  bottomBarVisible: false,
  toggleToolbar: () => undefined,
})

export interface ReaderShellProps {
  title: string
  format: ReaderFormat
  children: React.ReactNode
  onBack: () => void
  progress: ReaderProgress
  chapterLabel?: string
  initialToolbarVisible?: boolean
  ttsActive?: boolean
  realtimeActive?: boolean
  centerOverride?: React.ReactNode

  // Floating-widget context (Phase 4)
  bookId?: string
  onChatToggle?: () => void
  /**
   * Lazy provider for the voice-chat activation context (P0-O). Per-format
   * readers supply page text, chapter label, the active TTS paragraph,
   * etc. Threaded straight through to `ReaderOverlay`.
   */
  getActivationContext?: () => ActivationContext

  // Action cluster
  onBookmarkTogglePress?: () => void
  isBookmarked?: boolean
  onTTSPress?: () => void
  ttsButtonActive?: boolean
  onRealtimePress?: () => void
  realtimeStatus?: RealtimeStatus
  onChatPress?: () => void

  sheets?: ReaderShellSheets

  // TOC
  toc?: TocItem[]
  currentHref?: string | null
  onSelectChapter?: (href: string) => void

  // Highlights
  highlights?: Highlight[]
  onNavigateToHighlight?: (cfiRange: string) => void
  onDeleteHighlight?: (id: string) => void

  // Bookmarks
  bookmarks?: Bookmark[]
  onNavigateToBookmark?: (location: string) => void
  onDeleteBookmark?: (id: string) => void

  // Search
  searchQuery?: string
  searchResults?: SearchResult[]
  isSearching?: boolean
  onChangeSearchQuery?: (q: string) => void
  onSelectSearchResult?: (cfi: string) => void
  onSearchSheetClose?: () => void

  // Appearance
  settings?: ReaderSettings
  onSettingsChange?: (next: ReaderSettings) => void

  // NoteEditor (controlled bridge — parent flips `noteEditorOpen`)
  noteEditorHighlight?: NoteEditableHighlight | null
  noteEditorOpen?: boolean
  onSaveNote?: (highlightId: string, note: string) => void
  onDiscardNote?: () => void

  testID?: string
}

const AUTO_HIDE_MS = 3000

const NOOP_SETTINGS: ReaderSettings = {
  themeName: 'white',
  fontSize: 100,
  fontFamily: 'serif',
}

export function ReaderShell({
  title,
  format,
  children,
  onBack,
  progress,
  chapterLabel,
  initialToolbarVisible = true,
  ttsActive = false,
  realtimeActive = false,
  centerOverride,
  bookId,
  onChatToggle,
  getActivationContext,
  onBookmarkTogglePress,
  isBookmarked,
  onTTSPress,
  ttsButtonActive,
  onRealtimePress,
  realtimeStatus,
  onChatPress,
  sheets,
  toc,
  currentHref,
  onSelectChapter,
  highlights,
  onNavigateToHighlight,
  onDeleteHighlight,
  bookmarks,
  onNavigateToBookmark,
  onDeleteBookmark,
  searchQuery,
  searchResults,
  isSearching,
  onChangeSearchQuery,
  onSelectSearchResult,
  onSearchSheetClose,
  settings,
  onSettingsChange,
  noteEditorHighlight,
  noteEditorOpen,
  onSaveNote,
  onDiscardNote,
  testID,
}: ReaderShellProps): React.JSX.Element {
  const [toolbarVisible, setToolbarVisible] = useState<boolean>(
    initialToolbarVisible,
  )

  // P1-T — drive the lock chip overlays on TTS / voice / AI buttons. The
  // bar receives `showLockChips=!isAuthenticated`; the chip is purely a
  // visual affordance, taps still fire and the gate opens via
  // `useRequireAuth`.
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)

  // P1-E — toolbar pinning. When `toolbarPinned` is true, the 3s
  // auto-hide timer is skipped. Toggled by long-pressing the Back
  // chevron in the top bar.
  const toolbarPinned = usePrefsStore((s) => s.toolbarPinned)
  const setToolbarPinned = usePrefsStore((s) => s.setToolbarPinned)
  const handleLongPressBack = useCallback(() => {
    setToolbarPinned(!toolbarPinned)
  }, [setToolbarPinned, toolbarPinned])

  const [tocOpen, setTocOpen] = useState(false)
  const [highlightsOpen, setHighlightsOpen] = useState(false)
  const [bookmarksOpen, setBookmarksOpen] = useState(false)
  const [searchOpen, setSearchOpen] = useState(false)
  const [appearanceOpen, setAppearanceOpen] = useState(false)
  const [internalNoteEditorOpen, setInternalNoteEditorOpen] = useState(false)

  // Mirror parent's controlled `noteEditorOpen` flag into local state so
  // the sheet can also self-close (e.g. via swipe) without dropping the
  // parent's intent on the next render.
  useEffect(() => {
    if (typeof noteEditorOpen === 'boolean') {
      setInternalNoteEditorOpen(noteEditorOpen)
    }
  }, [noteEditorOpen])

  const anySheetOpen =
    tocOpen ||
    highlightsOpen ||
    bookmarksOpen ||
    searchOpen ||
    appearanceOpen ||
    internalNoteEditorOpen

  // Auto-hide timer — re-armed on every toolbar-visible transition and
  // cleared while TTS/voice are running, any sheet is open, or the
  // toolbar is pinned (P1-E).
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
    if (
      toolbarVisible &&
      !ttsActive &&
      !realtimeActive &&
      !anySheetOpen &&
      !toolbarPinned
    ) {
      timerRef.current = setTimeout(() => {
        setToolbarVisible(false)
      }, AUTO_HIDE_MS)
    }
    return () => {
      if (timerRef.current) {
        clearTimeout(timerRef.current)
        timerRef.current = null
      }
    }
  }, [toolbarVisible, ttsActive, realtimeActive, anySheetOpen, toolbarPinned])

  const toggleToolbar = useCallback(() => {
    setToolbarVisible((prev) => !prev)
  }, [])

  const contextValue = useMemo<ReaderShellContextValue>(
    () => ({
      bottomBarVisible: toolbarVisible,
      toggleToolbar,
    }),
    [toolbarVisible, toggleToolbar],
  )

  // Bottom bar handler wiring: only forward handlers when the
  // corresponding sheet is mounted by the parent. Each handler closes
  // any other sheets and opens the target sheet (mimics Apple Books's
  // "one sheet at a time" UX).
  const handleTocPress = sheets?.toc
    ? () => {
        setTocOpen(true)
      }
    : undefined

  const handleHighlightsPress = sheets?.highlights
    ? () => {
        setHighlightsOpen(true)
      }
    : undefined

  const handleBookmarksPress = sheets?.bookmarks
    ? () => {
        setBookmarksOpen(true)
      }
    : undefined

  const handleSearchPress = sheets?.search
    ? () => {
        setSearchOpen(true)
      }
    : undefined

  const handleAppearancePress = sheets?.appearance
    ? () => {
        setAppearanceOpen(true)
      }
    : undefined

  const handleSelectChapter = useCallback(
    (href: string) => {
      onSelectChapter?.(href)
      setTocOpen(false)
    },
    [onSelectChapter],
  )

  const handleNavigateToHighlight = useCallback(
    (cfiRange: string) => {
      onNavigateToHighlight?.(cfiRange)
      setHighlightsOpen(false)
    },
    [onNavigateToHighlight],
  )

  const handleNavigateToBookmark = useCallback(
    (location: string) => {
      onNavigateToBookmark?.(location)
      setBookmarksOpen(false)
    },
    [onNavigateToBookmark],
  )

  const handleSelectSearchResult = useCallback(
    (cfi: string) => {
      onSelectSearchResult?.(cfi)
      setSearchOpen(false)
    },
    [onSelectSearchResult],
  )

  const handleSearchClose = useCallback(() => {
    setSearchOpen(false)
    onSearchSheetClose?.()
  }, [onSearchSheetClose])

  // Appearance handlers — feed back into the parent's settings store via
  // `onSettingsChange`. We branch internally on the field that changed.
  const effectiveSettings = settings ?? NOOP_SETTINGS

  const handleThemeChange = useCallback(
    (name: ThemeName) => {
      onSettingsChange?.({ ...effectiveSettings, themeName: name })
    },
    [effectiveSettings, onSettingsChange],
  )
  const handleFontSizeChange = useCallback(
    (size: number) => {
      onSettingsChange?.({ ...effectiveSettings, fontSize: size })
    },
    [effectiveSettings, onSettingsChange],
  )
  const handleFontFamilyChange = useCallback(
    (family: 'serif' | 'sans-serif') => {
      onSettingsChange?.({ ...effectiveSettings, fontFamily: family })
    },
    [effectiveSettings, onSettingsChange],
  )

  const handleSaveNote = useCallback(
    (highlightId: string, note: string) => {
      onSaveNote?.(highlightId, note)
      setInternalNoteEditorOpen(false)
    },
    [onSaveNote],
  )

  const handleDiscardNote = useCallback(() => {
    onDiscardNote?.()
    setInternalNoteEditorOpen(false)
  }, [onDiscardNote])

  return (
    <ReaderShellContext.Provider value={contextValue}>
      <View testID={testID} style={{ flex: 1 }}>
        {children}

        <ReaderTopBar
          visible={toolbarVisible}
          title={title}
          onBack={onBack}
          onLongPressBack={handleLongPressBack}
          pinned={toolbarPinned}
          testID="reader-top-bar"
        />

        <ReaderBottomBar
          visible={toolbarVisible}
          progress={progress}
          chapterLabel={chapterLabel}
          centerOverride={centerOverride}
          onTocPress={handleTocPress}
          onHighlightsPress={handleHighlightsPress}
          onBookmarksPress={handleBookmarksPress}
          onSearchPress={handleSearchPress}
          onAppearancePress={handleAppearancePress}
          onBookmarkTogglePress={onBookmarkTogglePress}
          isBookmarked={isBookmarked}
          onTTSPress={onTTSPress}
          ttsButtonActive={ttsButtonActive ?? ttsActive}
          onRealtimePress={onRealtimePress}
          realtimeStatus={realtimeStatus}
          onChatPress={onChatPress}
          showLockChips={!isAuthenticated}
          testID="reader-bottom-bar"
        />

        <ReaderOverlay
          bookId={bookId}
          onChatToggle={onChatToggle}
          getActivationContext={getActivationContext}
        />

        {sheets?.toc ? (
          <TocSheet
            isOpen={tocOpen}
            onClose={() => setTocOpen(false)}
            toc={toc ?? []}
            currentHref={currentHref ?? null}
            onSelectChapter={handleSelectChapter}
          />
        ) : null}

        {sheets?.highlights ? (
          <HighlightsSheet
            isOpen={highlightsOpen}
            onClose={() => setHighlightsOpen(false)}
            highlights={highlights ?? []}
            onNavigate={handleNavigateToHighlight}
            onDelete={onDeleteHighlight ?? (() => undefined)}
          />
        ) : null}

        {sheets?.bookmarks ? (
          <BookmarksList
            isOpen={bookmarksOpen}
            onClose={() => setBookmarksOpen(false)}
            bookmarks={bookmarks ?? []}
            onNavigate={handleNavigateToBookmark}
            onDelete={onDeleteBookmark ?? (() => undefined)}
          />
        ) : null}

        {sheets?.search ? (
          <SearchPanel
            isOpen={searchOpen}
            onClose={handleSearchClose}
            query={searchQuery ?? ''}
            results={searchResults ?? []}
            isSearching={isSearching ?? false}
            onChangeQuery={onChangeSearchQuery ?? (() => undefined)}
            onSelectResult={handleSelectSearchResult}
          />
        ) : null}

        {sheets?.appearance ? (
          <AppearanceSheet
            isOpen={appearanceOpen}
            onClose={() => setAppearanceOpen(false)}
            settings={effectiveSettings}
            format={format}
            onThemeChange={handleThemeChange}
            onFontSizeChange={handleFontSizeChange}
            onFontFamilyChange={handleFontFamilyChange}
          />
        ) : null}

        {sheets?.noteEditor ? (
          <NoteEditor
            isOpen={internalNoteEditorOpen}
            onClose={() => setInternalNoteEditorOpen(false)}
            highlight={noteEditorHighlight ?? null}
            onSave={handleSaveNote}
            onDiscard={handleDiscardNote}
          />
        ) : null}
      </View>
    </ReaderShellContext.Provider>
  )
}
