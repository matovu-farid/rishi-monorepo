export type BookFormat = 'pdf' | 'epub' | 'mobi' | 'djvu'
export type Theme = 'light' | 'dark'

export interface RecentBook {
  bookId: number
  title: string
}
export interface OpenBookTitle {
  bookId: number
  title: string
}
export interface BookmarkSummary {
  id: number
  label: string
  location: string
}

export type MenuCommand =
  | { command: 'importBook' }
  | { command: 'openRecent'; arg: { bookId: number } }
  | { command: 'closeWindow' }
  | { command: 'focusLibrary' }
  | { command: 'toggleTheme' }
  | { command: 'toggleTOC' }
  | { command: 'toggleThumbnails' }
  | { command: 'toggleDualPage' }
  | { command: 'addBookmark' }
  | { command: 'showAllBookmarks' }
  | { command: 'jumpToBookmark'; arg: { bookmarkId: number } }
  | { command: 'readAloudToggle' }
  | { command: 'voiceChat' }
  | { command: 'openChat' }
  | { command: 'openHelp' }
  | { command: 'reportIssue' }
  | { command: 'about' }

export type LibraryMenuContext = {
  kind: 'library'
  theme: Theme
  recentBooks: RecentBook[]
  openBookTitles: OpenBookTitle[]
}

export type BookMenuContext = {
  kind: 'book'
  bookId: number
  format: BookFormat
  title: string
  tocOpen: boolean
  thumbsOpen: boolean
  dualPage: boolean
  isReading: boolean
  theme: Theme
  recentBooks: RecentBook[]
  openBookTitles: OpenBookTitle[]
  bookmarks: BookmarkSummary[]
}

export type MenuContext = LibraryMenuContext | BookMenuContext
