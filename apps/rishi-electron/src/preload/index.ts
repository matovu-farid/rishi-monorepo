import { contextBridge, ipcRenderer } from 'electron'
import type { Api, AuthUser, ElectronAPI } from './types.js'

const electronAPI: ElectronAPI = {
  // Book operations
  getBooks: () => ipcRenderer.invoke('books:getAll'),
  getBook: (bookId: number) => ipcRenderer.invoke('books:get', bookId),
  saveBook: (book: unknown) => ipcRenderer.invoke('books:save', book),
  deleteBook: (bookId: number) => ipcRenderer.invoke('books:delete', bookId),
  updateBookCover: (bookId: number, cover: number[]) =>
    ipcRenderer.invoke('books:updateCover', bookId, cover),
  updateBookLocation: (bookId: number, location: string) =>
    ipcRenderer.invoke('books:updateLocation', bookId, location),
  hasSavedEpubData: (bookId: number) => ipcRenderer.invoke('books:hasSavedEpubData', bookId),
  getBookOutline: (bookId: number) => ipcRenderer.invoke('books:getOutline', bookId),

  // Page/chunk data
  savePageDataMany: (pageData: unknown[]) => ipcRenderer.invoke('chunks:saveMany', pageData),
  getAllPageDataByBookId: (bookId: number) => ipcRenderer.invoke('chunks:getByBookId', bookId),

  // Search
  searchBookText: (query: string, bookId: number) =>
    ipcRenderer.invoke('search:text', query, bookId),
  getTextFromVectorId: (vectorId: number) =>
    ipcRenderer.invoke('search:textFromVectorId', vectorId),
  getContextForQuery: (queryText: string, bookId: number, k: number) =>
    ipcRenderer.invoke('search:contextForQuery', queryText, bookId, k),

  // Vector operations
  embed: (params: unknown[]) => ipcRenderer.invoke('vectors:embed', params),
  saveVectors: (name: string, dim: number, vectors: unknown[]) =>
    ipcRenderer.invoke('vectors:save', name, dim, vectors),
  searchVectors: (name: string, query: number[], dim: number, k: number) =>
    ipcRenderer.invoke('vectors:search', name, query, dim, k),

  // File format operations
  getBookData: (path: string) => ipcRenderer.invoke('formats:getBookData', path),
  getPdfData: (path: string) => ipcRenderer.invoke('formats:getPdfData', path),
  getMobiData: (path: string) => ipcRenderer.invoke('formats:getMobiData', path),
  getDjvuData: (path: string) => ipcRenderer.invoke('formats:getDjvuData', path),
  getMobiChapter: (path: string, chapterIndex: number) =>
    ipcRenderer.invoke('formats:getMobiChapter', path, chapterIndex),
  getMobiChapterCount: (path: string) => ipcRenderer.invoke('formats:getMobiChapterCount', path),
  getMobiText: (path: string, chapterIndex: number) =>
    ipcRenderer.invoke('formats:getMobiText', path, chapterIndex),
  getDjvuPage: (path: string, pageNumber: number, dpi: number) =>
    ipcRenderer.invoke('formats:getDjvuPage', path, pageNumber, dpi),
  getDjvuPageCount: (path: string) => ipcRenderer.invoke('formats:getDjvuPageCount', path),
  getDjvuPageText: (path: string, pageNumber: number) =>
    ipcRenderer.invoke('formats:getDjvuPageText', path, pageNumber),

  // File system
  checkFileSize: (path: string, format: string) =>
    ipcRenderer.invoke('fs:checkFileSize', path, format),
  unzip: (filePath: string, outDir: string) => ipcRenderer.invoke('fs:unzip', filePath, outDir),
  copyFile: (src: string, dest: string) => ipcRenderer.invoke('fs:copyFile', src, dest),
  getAppDataPath: () => ipcRenderer.invoke('fs:getAppDataPath'),
  readFile: (path: string) => ipcRenderer.invoke('fs:readFile', path),
  writeFile: (path: string, data: unknown) => ipcRenderer.invoke('fs:writeFile', path, data),
  exists: (path: string) => ipcRenderer.invoke('fs:exists', path),
  mkdir: (path: string) => ipcRenderer.invoke('fs:mkdir', path),
  readDir: (path: string) => ipcRenderer.invoke('fs:readDir', path),
  removeFile: (path: string) => ipcRenderer.invoke('fs:removeFile', path),
  getDirSize: (path: string) => ipcRenderer.invoke('fs:getDirSize', path),
  getCacheFileStats: (path: string) => ipcRenderer.invoke('fs:getCacheFileStats', path),

  // Vector operations (batch)
  processJob: (pageNumber: number, bookId: number, pageData: Array<{ text: string; id: number }>) =>
    ipcRenderer.invoke('vectors:processJob', pageNumber, bookId, pageData),

  // Scanner
  getDefaultBookFolders: () => ipcRenderer.invoke('scanner:getDefaultFolders'),
  scanForBooks: (mode: string) => ipcRenderer.invoke('scanner:scan', mode),
  cancelScan: () => ipcRenderer.invoke('scanner:cancel'),

  // Legacy auth shims — kept for backwards-compat with renderer code that
  // hasn't been ported off the old Clerk-shaped helpers yet. The Better
  // Auth surface lives on `window.api.auth.*` instead (see below).
  clearAuth: () => ipcRenderer.invoke('auth:clear'),
  getUserFromStore: () => ipcRenderer.invoke('auth:getUserFromStore'),
  saveUserToStore: (user: unknown) => ipcRenderer.invoke('auth:saveUserToStore', user),

  // Debug/error
  dumpError: (error: unknown) => ipcRenderer.invoke('debug:dumpError', error),
  readErrorDump: () => ipcRenderer.invoke('debug:readErrorDump'),
  clearErrorDump: () => ipcRenderer.invoke('debug:clearErrorDump'),

  // Settings store
  getStoreValue: (key: string) => ipcRenderer.invoke('store:get', key),
  setStoreValue: (key: string, value: unknown) => ipcRenderer.invoke('store:set', key, value),

  // Utilities
  isDev: () => ipcRenderer.invoke('util:isDev'),
  getDevBypassSecret: () => ipcRenderer.invoke('util:getDevBypassSecret'),
  showOpenDialog: (options: unknown) => ipcRenderer.invoke('dialog:showOpen', options),
  openExternal: (url: string) => ipcRenderer.invoke('shell:openExternal', url),
  getOsInfo: () => ipcRenderer.invoke('util:getOsInfo'),

  // Books extra (typed)
  booksGetSyncId: (bookId: number) => ipcRenderer.invoke('books:getSyncId', bookId),
  booksUpdateFilepath: (bookId: number, filepath: string) =>
    ipcRenderer.invoke('books:updateFilepath', bookId, filepath),
  booksUpdateFileHash: (bookId: number, fileHash: string, fileR2Key: string) =>
    ipcRenderer.invoke('books:updateFileHash', bookId, fileHash, fileR2Key),

  // Bookmarks (typed)
  bookmarksList: (bookId: string) => ipcRenderer.invoke('bookmarks:list', bookId),
  bookmarksSave: (params: { id: string; bookId: string; location: string; label: string }) =>
    ipcRenderer.invoke('bookmarks:save', params),
  bookmarksDelete: (bookmarkId: string) => ipcRenderer.invoke('bookmarks:delete', bookmarkId),

  // Highlights (typed)
  highlightsList: (bookId: string) => ipcRenderer.invoke('highlights:list', bookId),
  highlightsSave: (params: {
    bookSyncId: string
    cfiRange: string
    text: string
    color?: string
    note?: string
    chapter?: string
  }) => ipcRenderer.invoke('highlights:save', params),
  highlightsDelete: (bookSyncId: string, cfiRange: string) =>
    ipcRenderer.invoke('highlights:delete', bookSyncId, cfiRange),
  highlightsDeleteById: (highlightId: string) =>
    ipcRenderer.invoke('highlights:deleteById', highlightId),
  highlightsUpdateNote: (highlightId: string, note: string) =>
    ipcRenderer.invoke('highlights:updateNote', highlightId, note),
  highlightsUpdateColor: (highlightId: string, color: string) =>
    ipcRenderer.invoke('highlights:updateColor', highlightId, color),

  // Conversations (typed)
  conversationsFindForBook: (bookSyncId: string) =>
    ipcRenderer.invoke('conversations:findForBook', bookSyncId),
  conversationsCreate: (params: { id: string; bookId: string; title: string }) =>
    ipcRenderer.invoke('conversations:create', params),
  conversationsUpdateTimestamp: (conversationId: string) =>
    ipcRenderer.invoke('conversations:updateTimestamp', conversationId),

  // Messages (typed)
  messagesList: (conversationId: string) => ipcRenderer.invoke('messages:list', conversationId),
  messagesCreate: (params: {
    id: string
    conversationId: string
    role: string
    content: string
    sourceChunks?: string
  }) => ipcRenderer.invoke('messages:create', params),
  messagesGetChunkPage: (bookId: number, text: string) =>
    ipcRenderer.invoke('messages:getChunkPage', bookId, text),

  // Sync (typed)
  syncGetDirtyBooks: () => ipcRenderer.invoke('sync:getDirtyBooks'),
  syncGetDirtyHighlights: () => ipcRenderer.invoke('sync:getDirtyHighlights'),
  syncGetDirtyConversations: () => ipcRenderer.invoke('sync:getDirtyConversations'),
  syncGetDirtyMessages: () => ipcRenderer.invoke('sync:getDirtyMessages'),
  syncGetLastVersion: () => ipcRenderer.invoke('sync:getLastVersion'),
  syncMarkBooksClean: (ids: string[], syncVersion: number) =>
    ipcRenderer.invoke('sync:markBooksClean', { ids, syncVersion }),
  syncMarkHighlightsClean: (ids: string[], syncVersion: number) =>
    ipcRenderer.invoke('sync:markHighlightsClean', { ids, syncVersion }),
  syncMarkConversationsClean: (ids: string[], syncVersion: number) =>
    ipcRenderer.invoke('sync:markConversationsClean', { ids, syncVersion }),
  syncMarkMessagesClean: (ids: string[], syncVersion: number) =>
    ipcRenderer.invoke('sync:markMessagesClean', { ids, syncVersion }),
  syncApplyBookConflict: (conflict: Record<string, unknown>, syncVersion: number) =>
    ipcRenderer.invoke('sync:applyBookConflict', { conflict, syncVersion }),
  syncApplyHighlightConflict: (conflict: Record<string, unknown>, syncVersion: number) =>
    ipcRenderer.invoke('sync:applyHighlightConflict', {
      conflict,
      syncVersion
    }),
  syncApplyConversationConflict: (conflict: Record<string, unknown>, syncVersion: number) =>
    ipcRenderer.invoke('sync:applyConversationConflict', {
      conflict,
      syncVersion
    }),
  syncUpsertBook: (remote: Record<string, unknown>) =>
    ipcRenderer.invoke('sync:upsertBook', { remote }),
  syncUpsertHighlight: (remote: Record<string, unknown>) =>
    ipcRenderer.invoke('sync:upsertHighlight', { remote }),
  syncUpsertConversation: (remote: Record<string, unknown>) =>
    ipcRenderer.invoke('sync:upsertConversation', { remote }),
  syncInsertMessage: (remote: Record<string, unknown>) =>
    ipcRenderer.invoke('sync:insertMessage', { remote }),
  syncUpdateLastVersion: (version: number) => ipcRenderer.invoke('sync:updateLastVersion', version),

  // Updater
  checkForUpdates: () => ipcRenderer.invoke('updater:check'),
  downloadUpdate: () => ipcRenderer.invoke('updater:download'),
  installUpdate: () => ipcRenderer.invoke('updater:install'),
  getAppVersion: () => ipcRenderer.invoke('updater:getAppVersion'),

  // Event system
  on: (channel: string, callback: (...args: unknown[]) => void) => {
    const subscription = (_event: unknown, ...args: unknown[]) => callback(...args)
    ipcRenderer.on(channel, subscription)
    return () => {
      ipcRenderer.removeListener(channel, subscription)
    }
  },
  once: (channel: string, callback: (...args: unknown[]) => void) => {
    ipcRenderer.once(channel, (_event, ...args) => callback(...args))
  },
  send: (channel: string, ...args: unknown[]) => {
    ipcRenderer.send(channel, ...args)
  }
}

const api: Api = {
  auth: {
    startMagicLink: (email: string) => ipcRenderer.invoke('auth:start-magic-link', email),
    startGoogle: () => ipcRenderer.invoke('auth:start-google'),
    getSession: () => ipcRenderer.invoke('auth:get-session'),
    signOut: () => ipcRenderer.invoke('auth:sign-out'),
    deleteAccount: () => ipcRenderer.invoke('auth:delete-account'),
    getToken: () => ipcRenderer.invoke('auth:get-token'),
    onSessionChange: (cb: (user: AuthUser | null) => void) => {
      const handler = (_e: unknown, user: AuthUser | null): void => cb(user)
      ipcRenderer.on('session-changed', handler)
      return () => {
        ipcRenderer.removeListener('session-changed', handler)
      }
    },
    isMacAppStore: !!process.mas
  }
}

contextBridge.exposeInMainWorld('electron', electronAPI)
contextBridge.exposeInMainWorld('api', api)
