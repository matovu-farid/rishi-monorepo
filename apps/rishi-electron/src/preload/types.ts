export interface ElectronAPI {
  // Book operations
  getBooks: () => Promise<Book[]>
  getBook: (bookId: number) => Promise<Book | null>
  saveBook: (book: BookInsertable) => Promise<Book>
  deleteBook: (bookId: number) => Promise<void>
  updateBookCover: (bookId: number, cover: number[]) => Promise<void>
  updateBookLocation: (bookId: number, location: string) => Promise<void>
  hasSavedEpubData: (bookId: number) => Promise<boolean>
  getBookOutline: (bookId: number) => Promise<BookOutline>

  // Page/chunk data
  savePageDataMany: (pageData: ChunkDataInsertable[]) => Promise<void>
  getAllPageDataByBookId: (bookId: number) => Promise<PageData[]>
  getIndexedPageNumbers: (bookId: number) => Promise<number[]>

  // Search
  searchBookText: (query: string, bookId: number) => Promise<TextSearchResult[]>
  getTextFromVectorId: (vectorId: number) => Promise<PageData | undefined>

  // Vector operations
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  saveVectors: (name: string, dim: number, vectors: VectorData[]) => Promise<void>
  searchVectors: (name: string, query: number[], dim: number, k: number) => Promise<SearchResult[]>
  hasVectorsForBook: (bookId: number) => Promise<boolean>

  // File format operations
  getBookData: (path: string) => Promise<BookData>
  getPdfData: (path: string) => Promise<BookData>
  getMobiData: (path: string) => Promise<BookData>
  getAzw3Data: (path: string) => Promise<BookData>
  getMobiChapter: (path: string, chapterIndex: number) => Promise<string>
  getMobiChapterCount: (path: string) => Promise<number>
  getMobiText: (path: string, chapterIndex: number) => Promise<string[]>

  // File system
  checkFileSize: (path: string, format: string) => Promise<FileSizeCheck>
  unzip: (filePath: string, outDir: string) => Promise<string>
  copyFile: (src: string, dest: string) => Promise<void>
  getAppDataPath: () => Promise<string>
  readFile: (path: string) => Promise<ArrayBuffer>
  writeFile: (path: string, data: unknown) => Promise<void>
  exists: (path: string) => Promise<boolean>
  mkdir: (path: string) => Promise<void>
  readDir: (path: string) => Promise<string[]>
  removeFile: (path: string) => Promise<void>
  getDirSize: (path: string) => Promise<number>
  getCacheFileStats: (
    path: string
  ) => Promise<Array<{ path: string; size: number; mtimeMs: number }>>

  // Vector operations (batch)
  processJob: (
    pageNumber: number,
    bookId: number,
    pageData: Array<{ text: string; id: number }>
  ) => Promise<void>

  // Scanner
  getDefaultBookFolders: () => Promise<string[]>
  scanForBooks: (mode: string) => Promise<number>
  cancelScan: () => Promise<void>

  // Auth (cached user profile only — Clerk owns the JWT in the renderer)
  clearAuth: () => Promise<void>
  getUserFromStore: () => Promise<User | null>
  saveUserToStore: (user: User) => Promise<void>

  // Debug
  dumpError: (error: ErrorDump) => Promise<void>
  readErrorDump: () => Promise<string>
  clearErrorDump: () => Promise<void>

  // Settings store
  getStoreValue: (key: string) => Promise<unknown>
  setStoreValue: (key: string, value: unknown) => Promise<void>

  // Utilities
  isDev: () => Promise<boolean>
  getDevBypassSecret: () => Promise<string | null>
  showOpenDialog: (options: unknown) => Promise<{ filePaths: string[] }>
  openExternal: (url: string) => Promise<void>
  getOsInfo: () => Promise<{ platform: string; arch: string; version: string }>
  getPendingOpenFiles: () => Promise<string[]>

  // Books extra (typed)
  booksGetSyncId: (bookId: number) => Promise<string | null>
  booksUpdateFilepath: (bookId: number, filepath: string) => Promise<void>
  booksUpdateFileHash: (bookId: number, fileHash: string, fileR2Key: string) => Promise<void>

  // Bookmarks (typed)
  bookmarksList: (bookId: string) => Promise<BookmarkRow[]>
  bookmarksSave: (params: {
    id: string
    bookId: string
    location: string
    label: string
  }) => Promise<void>
  bookmarksDelete: (bookmarkId: string) => Promise<void>

  // Highlights (typed)
  highlightsList: (bookId: string) => Promise<HighlightRow[]>
  highlightsSave: (params: {
    bookSyncId: string
    cfiRange: string
    text: string
    color?: string
    note?: string
    chapter?: string
  }) => Promise<string>
  highlightsDelete: (bookSyncId: string, cfiRange: string) => Promise<void>
  highlightsDeleteById: (highlightId: string) => Promise<void>
  highlightsUpdateNote: (highlightId: string, note: string) => Promise<void>
  highlightsUpdateColor: (highlightId: string, color: string) => Promise<void>

  // Conversations (typed)
  conversationsFindForBook: (bookSyncId: string) => Promise<ConversationRow | null>
  conversationsCreate: (params: { id: string; bookId: string; title: string }) => Promise<void>
  conversationsUpdateTimestamp: (conversationId: string) => Promise<void>

  // Messages (typed)
  messagesList: (conversationId: string) => Promise<MessageRow[]>
  messagesCreate: (params: {
    id: string
    conversationId: string
    role: string
    content: string
    sourceChunks?: string
  }) => Promise<void>
  messagesGetChunkPage: (bookId: number, text: string) => Promise<number | null>

  // Sync (typed)
  syncGetDirtyBooks: () => Promise<unknown[]>
  syncGetDirtyHighlights: () => Promise<unknown[]>
  syncGetDirtyConversations: () => Promise<unknown[]>
  syncGetDirtyMessages: () => Promise<unknown[]>
  syncGetLastVersion: () => Promise<number>
  syncMarkBooksClean: (ids: string[], syncVersion: number) => Promise<void>
  syncMarkHighlightsClean: (ids: string[], syncVersion: number) => Promise<void>
  syncMarkConversationsClean: (ids: string[], syncVersion: number) => Promise<void>
  syncMarkMessagesClean: (ids: string[], syncVersion: number) => Promise<void>
  syncApplyBookConflict: (conflict: Record<string, unknown>, syncVersion: number) => Promise<void>
  syncApplyHighlightConflict: (
    conflict: Record<string, unknown>,
    syncVersion: number
  ) => Promise<void>
  syncApplyConversationConflict: (
    conflict: Record<string, unknown>,
    syncVersion: number
  ) => Promise<void>
  syncUpsertBook: (remote: Record<string, unknown>) => Promise<void>
  syncUpsertHighlight: (remote: Record<string, unknown>) => Promise<void>
  syncUpsertConversation: (remote: Record<string, unknown>) => Promise<void>
  syncInsertMessage: (remote: Record<string, unknown>) => Promise<void>
  syncUpdateLastVersion: (version: number) => Promise<void>

  // Updater
  checkForUpdates: () => Promise<{ updateAvailable: boolean; version?: string | null }>
  downloadUpdate: () => Promise<void>
  installUpdate: () => Promise<void>
  getAppVersion: () => Promise<string>

  // Events
  on: (channel: string, callback: (...args: unknown[]) => void) => () => void
  once: (channel: string, callback: (...args: unknown[]) => void) => void
  send: (channel: string, ...args: unknown[]) => void

  // Window identity + menu (injected by main via additionalArguments)
  windowIdentity: { kind: 'library' } | { kind: 'book'; bookId: number }
  onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => () => void
  setMenuContext: (partial: Record<string, unknown>) => void
  /**
   * Ask main to rebuild this window's native menu from fresh DB state —
   * refreshes Open Recent / Window submenu lists. Cheap: same path as the
   * focus listener.
   */
  refreshMenu: () => void
  openBook: (bookId: number) => Promise<void>
  closeBook: (bookId: number) => Promise<void>
  focusLibrary: () => Promise<void>
  listOpenBooks: () => Promise<Array<{ bookId: number; title: string }>>
}

export type FileSizeCheck = 'ok' | 'warn' | 'blocked'

export interface User {
  id: string
  firstName?: string | null
  lastName?: string | null
  fullName?: string | null
  username?: string | null
  imageUrl?: string | null
  hasImage: boolean
  lastSignInAt?: number | null
  externalId?: string | null
}

/**
 * Better-Auth user shape returned by the new auth IPC surface.
 * Distinct from the legacy Clerk-shaped `User` above (still consumed by
 * older renderer code until Chunk F migrates it).
 */
export interface AuthUser {
  id: string
  email: string
  name?: string
  image?: string
}

export interface AuthApi {
  startMagicLink: (email: string) => Promise<void>
  startGoogle: () => Promise<void>
  getSession: () => Promise<AuthUser | null>
  signOut: () => Promise<void>
  deleteAccount: () => Promise<void>
  getToken: () => Promise<string | null>
  onSessionChange: (cb: (user: AuthUser | null) => void) => () => void
  isMacAppStore: boolean
}

export interface Api {
  auth: AuthApi
}

export interface BookOutline {
  title: string
  author: string | null
  chapters: string[]
}

export interface Book {
  id: number
  kind: string
  cover: number[]
  title: string
  author: string
  publisher: string
  filepath: string
  location: string
  coverKind: string
  version: number
  syncId?: string | null
  fileHash?: string | null
  fileR2Key?: string | null
  coverR2Key?: string | null
  format: string
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export interface BookInsertable {
  id?: number | null
  kind: string
  cover: number[]
  title: string
  author: string
  publisher: string
  filepath: string
  location: string
  coverKind: string
  version: number
  syncId?: string | null
  fileHash?: string | null
  fileR2Key?: string | null
  coverR2Key?: string | null
  format?: string | null
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion?: number | null
  isDirty?: number | null
  isDeleted?: number | null
}

export interface BookData {
  id: string
  kind: string
  cover: number[]
  title?: string | null
  author?: string | null
  publisher?: string | null
  filepath: string
  location: string
  coverKind?: string | null
  version: number
}

export interface PageData {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export interface ChunkDataInsertable {
  id?: number | null
  pageNumber: number
  bookId: number
  data: string
}

export interface TextSearchResult {
  id: number
  pageNumber: number
  bookId: number
  data: string
  snippet: string
}

export interface SearchResult {
  id: number
  distance: number
}

export interface VectorData {
  id: number
  vector: number[]
}

export interface EmbedParam {
  text: string
  metadata: {
    id: number
    pageNumber: number
    bookId: number
  }
}

export interface EmbedResult {
  dim: number
  embedding: number[]
  text?: string | null
  metadata: {
    id: number
    pageNumber: number
    bookId: number
  }
}

export interface BookmarkRow {
  id: string
  bookId: string
  location: string
  label: string
  pageNumber: number | null
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export interface HighlightRow {
  id: string
  bookId: string
  cfiRange: string
  text: string
  color: string
  note: string
  chapter: string | null
  createdAt: string
  updatedAt: number | null
  syncId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export interface ConversationRow {
  id: string
  bookId: string
  title: string
  userId: string | null
  createdAt: string
  updatedAt: number | null
  syncId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export interface MessageRow {
  id: string
  conversationId: string
  role: string
  content: string
  sourceChunks: string | null
  createdAt: string
  updatedAt: number | null
  syncId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export interface ErrorDump {
  source: string
  location: string
  error: string
  context?: string | null
  stack?: string | null
}

declare global {
  interface Window {
    electron: ElectronAPI
    api: Api
  }
}
