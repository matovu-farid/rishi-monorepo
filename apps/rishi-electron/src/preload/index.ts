import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { Api, AuthUser, ElectronAPI } from './types.js'
import { invoke } from './ipc-contract.js'
import { parseWindowIdentity } from './windowIdentity'

const electronAPI: ElectronAPI = {
  // Book operations
  getBooks: () => invoke('books:getAll'),
  getBook: (bookId) => invoke('books:get', bookId),
  saveBook: (book) => invoke('books:save', book),
  deleteBook: (bookId) => invoke('books:delete', bookId),
  updateBookCover: (bookId, cover) => invoke('books:updateCover', bookId, cover),
  updateBookLocation: (bookId, location) => invoke('books:updateLocation', bookId, location),
  hasSavedEpubData: (bookId) => invoke('books:hasSavedEpubData', bookId),
  getBookOutline: (bookId) => invoke('books:getOutline', bookId),

  // Page/chunk data
  savePageDataMany: (pageData) => invoke('chunks:saveMany', pageData),
  getAllPageDataByBookId: (bookId) => invoke('chunks:getByBookId', bookId),
  getIndexedPageNumbers: (bookId) => invoke('chunks:getIndexedPages', bookId),

  // Search
  searchBookText: (query, bookId) => invoke('search:text', query, bookId),
  getTextFromVectorId: (vectorId) => invoke('search:textFromVectorId', vectorId),

  // Vector operations
  embed: (params) => invoke('vectors:embed', params),
  saveVectors: (name, dim, vectors) => invoke('vectors:save', name, dim, vectors),
  searchVectors: (name, query, dim, k) => invoke('vectors:search', name, query, dim, k),
  hasVectorsForBook: (bookId) => invoke('vectors:hasFor', bookId),

  // File format operations
  getBookData: (path) => invoke('formats:getBookData', path),
  getPdfData: (path) => invoke('formats:getPdfData', path),
  getMobiData: (path) => invoke('formats:getMobiData', path),
  getAzw3Data: (path) => invoke('formats:getAzw3Data', path),
  getMobiChapter: (path, chapterIndex) => invoke('formats:getMobiChapter', path, chapterIndex),
  getMobiChapterCount: (path) => invoke('formats:getMobiChapterCount', path),
  getMobiText: (path, chapterIndex) => invoke('formats:getMobiText', path, chapterIndex),

  // File system
  checkFileSize: (path, format) => invoke('fs:checkFileSize', path, format),
  unzip: (filePath, outDir) => invoke('fs:unzip', filePath, outDir),
  copyFile: (src, dest) => invoke('fs:copyFile', src, dest),
  getAppDataPath: () => invoke('fs:getAppDataPath'),
  readFile: (path) => invoke('fs:readFile', path),
  writeFile: (path, data) => invoke('fs:writeFile', path, data),
  exists: (path) => invoke('fs:exists', path),
  mkdir: (path) => invoke('fs:mkdir', path),
  readDir: (path) => invoke('fs:readDir', path),
  removeFile: (path) => invoke('fs:removeFile', path),
  getDirSize: (path) => invoke('fs:getDirSize', path),
  getCacheFileStats: (path) => invoke('fs:getCacheFileStats', path),
  getPathForFile: (file) => webUtils.getPathForFile(file),

  // Vector operations (batch)
  processJob: (pageNumber, bookId, pageData) =>
    invoke('vectors:processJob', pageNumber, bookId, pageData),

  // Scanner
  getDefaultBookFolders: () => invoke('scanner:getDefaultFolders'),
  scanForBooks: (mode) => invoke('scanner:scan', mode),
  cancelScan: () => invoke('scanner:cancel'),

  // Legacy auth shims — kept for backwards-compat with renderer code that
  // hasn't been ported off the old Clerk-shaped helpers yet. The Better
  // Auth surface lives on `window.api.auth.*` instead (see below).
  clearAuth: () => invoke('auth:clear'),
  getUserFromStore: () => invoke('auth:getUserFromStore'),
  saveUserToStore: (user) => invoke('auth:saveUserToStore', user),

  // Debug/error
  dumpError: (error) => invoke('debug:dumpError', error),
  readErrorDump: () => invoke('debug:readErrorDump'),
  clearErrorDump: () => invoke('debug:clearErrorDump'),
  dumpState: (json) => invoke('debug:dumpState', json),
  readStateDump: () => invoke('debug:readStateDump'),

  // Settings store
  getStoreValue: (key) => invoke('store:get', key),
  setStoreValue: (key, value) => invoke('store:set', key, value),

  // Utilities
  isDev: () => invoke('util:isDev'),
  getDevBypassSecret: () => invoke('util:getDevBypassSecret'),
  showOpenDialog: (options) => invoke('dialog:showOpen', options),
  showMessageBox: (options) => invoke('dialog:showMessageBox', options),
  openExternal: (url) => invoke('shell:openExternal', url),
  getOsInfo: () => invoke('util:getOsInfo'),
  getPendingOpenFiles: () => invoke('files:getPending'),

  // Books extra (typed)
  booksGetSyncId: (bookId) => invoke('books:getSyncId', bookId),
  booksUpdateFilepath: (bookId, filepath) => invoke('books:updateFilepath', bookId, filepath),
  booksUpdateFileHash: (bookId, fileHash, fileR2Key) =>
    invoke('books:updateFileHash', bookId, fileHash, fileR2Key),

  // Bookmarks (typed)
  bookmarksList: (bookId) => invoke('bookmarks:list', bookId),
  bookmarksSave: (params) => invoke('bookmarks:save', params),
  bookmarksDelete: (bookmarkId) => invoke('bookmarks:delete', bookmarkId),

  // Highlights (typed)
  highlightsList: (bookId) => invoke('highlights:list', bookId),
  highlightsSave: (params) => invoke('highlights:save', params),
  highlightsDelete: (bookSyncId, cfiRange) => invoke('highlights:delete', bookSyncId, cfiRange),
  highlightsDeleteById: (highlightId) => invoke('highlights:deleteById', highlightId),
  highlightsUpdateNote: (highlightId, note) => invoke('highlights:updateNote', highlightId, note),
  highlightsUpdateColor: (highlightId, color) =>
    invoke('highlights:updateColor', highlightId, color),

  // Conversations (typed)
  conversationsFindForBook: (bookSyncId) => invoke('conversations:findForBook', bookSyncId),
  conversationsCreate: (params) => invoke('conversations:create', params),
  conversationsUpdateTimestamp: (conversationId) =>
    invoke('conversations:updateTimestamp', conversationId),

  // Messages (typed)
  messagesList: (conversationId) => invoke('messages:list', conversationId),
  messagesCreate: (params) => invoke('messages:create', params),
  messagesGetChunkPage: (bookId, text) => invoke('messages:getChunkPage', bookId, text),

  // Sync (typed)
  syncGetDirtyBooks: () => invoke('sync:getDirtyBooks'),
  syncGetDirtyHighlights: () => invoke('sync:getDirtyHighlights'),
  syncGetDirtyConversations: () => invoke('sync:getDirtyConversations'),
  syncGetDirtyMessages: () => invoke('sync:getDirtyMessages'),
  syncGetLastVersion: () => invoke('sync:getLastVersion'),
  syncMarkBooksClean: (ids, syncVersion) => invoke('sync:markBooksClean', ids, syncVersion),
  syncMarkHighlightsClean: (ids, syncVersion) =>
    invoke('sync:markHighlightsClean', ids, syncVersion),
  syncMarkConversationsClean: (ids, syncVersion) =>
    invoke('sync:markConversationsClean', ids, syncVersion),
  syncMarkMessagesClean: (ids, syncVersion) => invoke('sync:markMessagesClean', ids, syncVersion),
  syncApplyBookConflict: (conflict, syncVersion) =>
    invoke('sync:applyBookConflict', conflict, syncVersion),
  syncApplyHighlightConflict: (conflict, syncVersion) =>
    invoke('sync:applyHighlightConflict', conflict, syncVersion),
  syncApplyConversationConflict: (conflict, syncVersion) =>
    invoke('sync:applyConversationConflict', conflict, syncVersion),
  syncUpsertBook: (remote) => invoke('sync:upsertBook', remote),
  syncUpsertHighlight: (remote) => invoke('sync:upsertHighlight', remote),
  syncUpsertConversation: (remote) => invoke('sync:upsertConversation', remote),
  syncInsertMessage: (remote) => invoke('sync:insertMessage', remote),
  syncUpdateLastVersion: (version) => invoke('sync:updateLastVersion', version),

  // Updater
  checkForUpdates: () => invoke('updater:check'),
  downloadUpdate: () => invoke('updater:download'),
  installUpdate: () => invoke('updater:install'),
  getAppVersion: () => invoke('updater:getAppVersion'),

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
  },

  // Window identity + menu API
  windowIdentity: parseWindowIdentity(process.argv),
  onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => {
    const handler = (_e: unknown, payload: { command: string; arg?: unknown }): void => cb(payload)
    ipcRenderer.on('menu:command', handler)
    return () => {
      ipcRenderer.removeListener('menu:command', handler)
    }
  },
  setMenuContext: (partial: Record<string, unknown>) => {
    ipcRenderer.send('menu:setContext', partial)
  },
  refreshMenu: () => {
    ipcRenderer.send('menu:refresh')
  },
  openBook: (bookId) => invoke('window:openBook', bookId),
  closeBook: (bookId) => invoke('window:closeBook', bookId),
  focusLibrary: () => invoke('window:focusLibrary'),
  listOpenBooks: () => invoke('window:list')
}

const api: Api = {
  auth: {
    startMagicLink: (email) => invoke('auth:start-magic-link', email),
    startGoogle: () => invoke('auth:start-google'),
    getSession: () => invoke('auth:get-session'),
    signOut: () => invoke('auth:sign-out'),
    deleteAccount: () => invoke('auth:delete-account'),
    getToken: () => invoke('auth:get-token'),
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
