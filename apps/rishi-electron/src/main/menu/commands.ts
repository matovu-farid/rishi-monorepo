export type BookFormat = 'pdf' | 'epub' | 'mobi'
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
  // Bookmarks are stored with UUID string ids (see `bookmarks` table); this
  // mirrors that so the menu builder and renderer stay aligned with the DB.
  id: string
  label: string
  location: string
}

export type MenuCommand =
  | { command: 'importBook' }
  | { command: 'openRecent'; arg: { bookId: number } }
  | { command: 'focusLibrary' }
  | { command: 'toggleTheme' }
  | { command: 'toggleTOC' }
  | { command: 'toggleThumbnails' }
  | { command: 'toggleDualPage' }
  | { command: 'addBookmark' }
  | { command: 'showAllBookmarks' }
  | { command: 'jumpToBookmark'; arg: { bookmarkId: string } }
  | { command: 'readAloudToggle' }
  | { command: 'readAloudFromSelection' }
  | { command: 'showHighlights' }
  | { command: 'voiceChat' }
  | { command: 'openChat' }
  | { command: 'openHelp' }
  | { command: 'reportIssue' }
  | { command: 'about' }
  | { command: 'openSettings' }
  | { command: 'checkForUpdates' }

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
