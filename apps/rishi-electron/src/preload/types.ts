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
  'books:updateLastParagraph': 'updateBookLastParagraph'
  'books:hasSavedEpubData': 'hasSavedEpubData'
  'books:getOutline': 'getBookOutline'
  'books:getSyncId': 'booksGetSyncId'
  'books:updateFilepath': 'booksUpdateFilepath'
  'books:updateFileHash': 'booksUpdateFileHash'
  'books:findByHash': 'findBookByHash'
  'books:getFilepaths': 'getBookFilepaths'
  'books:getCover': 'getCover'

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
  'fs:getFileSize': 'getFileSize'
  'fs:unzip': 'unzip'
  'fs:copyFile': 'copyFile'
  'fs:linkOrCopyFile': 'linkOrCopyFile'
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
  'debug:appendLog': 'appendDebugLog'
  'debug:readDebugLog': 'readDebugLog'
  'debug:clearDebugLog': 'clearDebugLog'

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
  'window:openSettings': 'openSettings'

  // Better-auth (lives on `window.api.auth`, not `electronAPI` — but we
  // still want the channels to flow through `IpcContract` for the helper
  // wrapper coverage in preload/index.ts).
  'auth:start-magic-link': never
  'auth:start-google': never
  'auth:get-session': never
  'auth:sign-out': never
  'auth:delete-account': never
  'auth:get-token': never

  // Sharing (lives on a dedicated `sharing` namespace exposed in preload —
  // see Task 28. Like the better-auth channels above, these are kept in
  // `IpcContract` for helper-wrapper coverage but mapped to `never` so
  // they're excluded from the auto-derived `window.electron` surface.)
  'sharing:getSigningJwt': never
  'sharing:saveTransferredBook': never
  'sharing:discardTransferredBook': never
  'sharing:hasBookFile': never
  'sharing:readBookBytes': never
  'sharing:getConfig': never
  'sharing:registerDeepLinkListener': never
  'sharing:readReconnect': never
  'sharing:writeReconnect': never
  'sharing:clearReconnect': never
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
  // Events — main → renderer push channels (no typed registry; channel names
  // are string literals agreed upon between sender and subscriber).
  //
  // Known push channels (main → renderer):
  //   'open-files'                   — drag-dropped or open-with file paths
  //   'menu:command'                 — native menu action forwarded to focused window
  //   'session-changed'              — auth session update (see window.api.auth)
  //   'update-available'             — auto-updater status
  //   'update-not-available'         — auto-updater status
  //   'download-progress'            — auto-updater download progress
  //   'update-downloaded'            — auto-updater ready to install
  //   'update-error'                 — auto-updater error
  //   'reader:readAloudFromSelection' — (Task 9/10) menu/gesture triggered read-aloud
  on: (channel: string, callback: (...args: unknown[]) => void) => () => void
  once: (channel: string, callback: (...args: unknown[]) => void) => void
  send: (channel: string, ...args: unknown[]) => void

  // Window identity + menu (injected by main via additionalArguments)
  windowIdentity: { kind: 'library' } | { kind: 'book'; bookId: number } | { kind: 'settings' }
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

  /**
   * Shared-reading surface. Mirrors the `sharing:*` IPC channels in
   * `IpcContract`, but exposed under a dedicated namespace because the
   * channels are mapped to `never` in `ChannelToMethod` (they're not part
   * of the auto-derived flat surface). The deep-link listener is a
   * push channel (`sharing:deepLinkReceived`), not an invoke.
   */
  sharing: {
    getSigningJwt: () => Promise<{ jwt: string; expiresAt: number }>
    saveTransferredBook: (params: {
      bookId: string
      contentHash: string
      format: 'epub' | 'pdf'
      blob: number[]
      receivedFromUserId: string
      receivedAt: number
      title: string
    }) => Promise<{ localPath: string; dbBookId: number }>
    discardTransferredBook: (params: { dbBookId: number; localPath: string }) => Promise<void>
    hasBookFile: (params: { contentHash: string }) => Promise<boolean>
    /**
     * Read a locally-stored book's bytes by content hash. Used by the
     * sharing flow on the host side to feed the P2P file-transfer
     * sender. The handler validates the on-disk SHA-256 still matches
     * before returning.
     */
    readBookBytes: (params: { bookId: string; contentHash: string }) => Promise<{
      bytes: number[]
      format: 'epub' | 'pdf'
    }>
    getConfig: () => Promise<{
      wsBaseUrl: string
      workerBaseUrl: string
      iceServers: Array<{ urls: string | string[]; username?: string; credential?: string }>
    }>
    onDeepLink: (cb: (p: { joinToken: string }) => void) => () => void
    /**
     * Reborn-host reconnect persistence. The renderer writes the
     * worker-issued reconnect token + wsUrl on `welcome`, reads it on
     * app start, and clears it on graceful session end.
     */
    readReconnect: (params: { userId: string }) => Promise<{
      sessionId: string
      reconnectToken: string
      wsUrl: string
      reservedUntil: number
      storedAt: number
    } | null>
    writeReconnect: (params: {
      userId: string
      sessionId: string
      reconnectToken: string
      wsUrl: string
      reservedUntil: number
    }) => Promise<void>
    clearReconnect: (params: { userId: string }) => Promise<void>
  }
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
  fileSize?: number | null
  format: string
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
  lastParagraph?: string | null
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
  fileSize?: number | null
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
  format: 'epub' | 'pdf'
  cfiRange: string | null
  locator: string | null
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
