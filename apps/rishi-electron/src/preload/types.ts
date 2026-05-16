import type { IpcContract } from './ipc-contract'

// ---------------------------------------------------------------------------
// Renderer-facing API surface
//
// `ElectronAPI` is derived from `IpcContract` (the single source of truth for
// the IPC surface) so its method signatures cannot drift from what the main
// process actually accepts/returns. The non-invoke pieces below (event-based
// `on/once/send`, the window identity, the menu helpers) live outside the
// contract because they're not request/response — they keep their hand-written
// shapes.
// ---------------------------------------------------------------------------

/**
 * Mapping from IPC channel name → renderer method name. Every entry in
 * `IpcContract` must appear here (compile-time-checked below).
 *
 * Channel names are kebab-case-ish and namespaced (`books:getAll`); method
 * names are flat camelCase chosen to read naturally at the call site
 * (`window.electron.getBooks()`). Keeping the mapping explicit here avoids
 * a fragile string transformation while preserving a single source of truth.
 */
export type ChannelToMethod = {
  // Books
  'books:getAll': 'getBooks'
  'books:get': 'getBook'
  'books:save': 'saveBook'
  'books:delete': 'deleteBook'
  'books:updateCover': 'updateBookCover'
  'books:updateLocation': 'updateBookLocation'
  'books:hasSavedEpubData': 'hasSavedEpubData'
  'books:getOutline': 'getBookOutline'
  'books:getSyncId': 'booksGetSyncId'
  'books:updateFilepath': 'booksUpdateFilepath'
  'books:updateFileHash': 'booksUpdateFileHash'

  // Chunks
  'chunks:saveMany': 'savePageDataMany'
  'chunks:getByBookId': 'getAllPageDataByBookId'
  'chunks:getIndexedPages': 'getIndexedPageNumbers'

  // Search
  'search:text': 'searchBookText'
  'search:textFromVectorId': 'getTextFromVectorId'

  // Vectors
  'vectors:embed': 'embed'
  'vectors:save': 'saveVectors'
  'vectors:search': 'searchVectors'
  'vectors:hasFor': 'hasVectorsForBook'
  'vectors:processJob': 'processJob'

  // Formats
  'formats:getBookData': 'getBookData'
  'formats:getPdfData': 'getPdfData'
  'formats:getMobiData': 'getMobiData'
  'formats:getAzw3Data': 'getAzw3Data'
  'formats:getMobiChapter': 'getMobiChapter'
  'formats:getMobiChapterCount': 'getMobiChapterCount'
  'formats:getMobiText': 'getMobiText'

  // FS
  'fs:checkFileSize': 'checkFileSize'
  'fs:unzip': 'unzip'
  'fs:copyFile': 'copyFile'
  'fs:getAppDataPath': 'getAppDataPath'
  'fs:readFile': 'readFile'
  'fs:writeFile': 'writeFile'
  'fs:exists': 'exists'
  'fs:mkdir': 'mkdir'
  'fs:readDir': 'readDir'
  'fs:removeFile': 'removeFile'
  'fs:getDirSize': 'getDirSize'
  'fs:getCacheFileStats': 'getCacheFileStats'

  // Scanner
  'scanner:getDefaultFolders': 'getDefaultBookFolders'
  'scanner:scan': 'scanForBooks'
  'scanner:cancel': 'cancelScan'

  // Auth (cached profile)
  'auth:clear': 'clearAuth'
  'auth:getUserFromStore': 'getUserFromStore'
  'auth:saveUserToStore': 'saveUserToStore'

  // Debug
  'debug:dumpError': 'dumpError'
  'debug:readErrorDump': 'readErrorDump'
  'debug:clearErrorDump': 'clearErrorDump'
  'debug:dumpState': 'dumpState'
  'debug:readStateDump': 'readStateDump'

  // Store
  'store:get': 'getStoreValue'
  'store:set': 'setStoreValue'

  // Utilities
  'util:isDev': 'isDev'
  'util:getDevBypassSecret': 'getDevBypassSecret'
  'util:getOsInfo': 'getOsInfo'
  'shell:openExternal': 'openExternal'
  'dialog:showOpen': 'showOpenDialog'
  'dialog:showMessageBox': 'showMessageBox'
  'files:getPending': 'getPendingOpenFiles'

  // Bookmarks
  'bookmarks:list': 'bookmarksList'
  'bookmarks:save': 'bookmarksSave'
  'bookmarks:delete': 'bookmarksDelete'

  // Highlights
  'highlights:list': 'highlightsList'
  'highlights:save': 'highlightsSave'
  'highlights:delete': 'highlightsDelete'
  'highlights:deleteById': 'highlightsDeleteById'
  'highlights:updateNote': 'highlightsUpdateNote'
  'highlights:updateColor': 'highlightsUpdateColor'

  // Conversations / Messages
  'conversations:findForBook': 'conversationsFindForBook'
  'conversations:create': 'conversationsCreate'
  'conversations:updateTimestamp': 'conversationsUpdateTimestamp'
  'messages:list': 'messagesList'
  'messages:create': 'messagesCreate'
  'messages:getChunkPage': 'messagesGetChunkPage'

  // Sync
  'sync:getDirtyBooks': 'syncGetDirtyBooks'
  'sync:getDirtyHighlights': 'syncGetDirtyHighlights'
  'sync:getDirtyConversations': 'syncGetDirtyConversations'
  'sync:getDirtyMessages': 'syncGetDirtyMessages'
  'sync:getLastVersion': 'syncGetLastVersion'
  'sync:markBooksClean': 'syncMarkBooksClean'
  'sync:markHighlightsClean': 'syncMarkHighlightsClean'
  'sync:markConversationsClean': 'syncMarkConversationsClean'
  'sync:markMessagesClean': 'syncMarkMessagesClean'
  'sync:applyBookConflict': 'syncApplyBookConflict'
  'sync:applyHighlightConflict': 'syncApplyHighlightConflict'
  'sync:applyConversationConflict': 'syncApplyConversationConflict'
  'sync:upsertBook': 'syncUpsertBook'
  'sync:upsertHighlight': 'syncUpsertHighlight'
  'sync:upsertConversation': 'syncUpsertConversation'
  'sync:insertMessage': 'syncInsertMessage'
  'sync:updateLastVersion': 'syncUpdateLastVersion'

  // Updater
  'updater:check': 'checkForUpdates'
  'updater:download': 'downloadUpdate'
  'updater:install': 'installUpdate'
  'updater:getAppVersion': 'getAppVersion'

  // Window
  'window:openBook': 'openBook'
  'window:closeBook': 'closeBook'
  'window:focusLibrary': 'focusLibrary'
  'window:list': 'listOpenBooks'

  // Better-auth (lives on `window.api.auth`, not `electronAPI` — but we
  // still want the channels to flow through `IpcContract` for the helper
  // wrapper coverage in preload/index.ts).
  'auth:start-magic-link': never
  'auth:start-google': never
  'auth:get-session': never
  'auth:sign-out': never
  'auth:delete-account': never
  'auth:get-token': never
}

// Compile-time check: every channel in IpcContract must appear in ChannelToMethod.
type _AssertChannelToMethodCoversContract = [
  Exclude<keyof IpcContract, keyof ChannelToMethod>
] extends [never]
  ? true
  : [
      'Missing ChannelToMethod entry for channel(s):',
      Exclude<keyof IpcContract, keyof ChannelToMethod>
    ]
type _Check = _AssertChannelToMethodCoversContract
// Reference the alias so unused-type warnings don't strip it.
export type __ChannelToMethodCovers = _Check

/** Maps an IpcContract entry to a method signature on `ElectronAPI`. */
type MethodFromChannel<K extends keyof IpcContract> = (
  ...args: IpcContract[K]['args']
) => Promise<IpcContract[K]['returns']>

/**
 * Channels that are exposed on `window.electron` (i.e. those with a
 * non-`never` mapping entry). The better-auth channels live on
 * `window.api.auth` instead, so they're excluded here.
 */
type ChannelOnElectron = {
  [K in keyof IpcContract]: ChannelToMethod[K] extends string ? K : never
}[keyof IpcContract]

/** The auto-derived invoke surface on `window.electron`. */
type DerivedInvokeApi = {
  [K in ChannelOnElectron as ChannelToMethod[K] & string]: MethodFromChannel<K>
}

/**
 * Renderer-facing API. The invoke surface is auto-derived from
 * `IpcContract`; the event/window/menu helpers below are not request/reply
 * channels, so they're declared explicitly.
 */
export type ElectronAPI = DerivedInvokeApi & {
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

  /**
   * Resolve a renderer-side `File` (from drag-drop or `<input type=file>`)
   * to its absolute filesystem path. Replaces the removed `File.path`
   * augmentation — Electron 32+ requires `webUtils.getPathForFile`.
   */
  getPathForFile: (file: File) => string
}

// ---------------------------------------------------------------------------
// Shared data types
// ---------------------------------------------------------------------------

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
