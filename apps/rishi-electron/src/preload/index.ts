import { contextBridge, ipcRenderer } from "electron";
import type { ElectronAPI } from "./types.js";

const electronAPI: ElectronAPI = {
  // Book operations
  getBooks: () => ipcRenderer.invoke("books:getAll"),
  getBook: (bookId: number) => ipcRenderer.invoke("books:get", bookId),
  saveBook: (book: unknown) => ipcRenderer.invoke("books:save", book),
  deleteBook: (bookId: number) => ipcRenderer.invoke("books:delete", bookId),
  updateBookCover: (bookId: number, cover: number[]) =>
    ipcRenderer.invoke("books:updateCover", bookId, cover),
  updateBookLocation: (bookId: number, location: string) =>
    ipcRenderer.invoke("books:updateLocation", bookId, location),
  hasSavedEpubData: (bookId: number) =>
    ipcRenderer.invoke("books:hasSavedEpubData", bookId),

  // Page/chunk data
  savePageDataMany: (pageData: unknown[]) =>
    ipcRenderer.invoke("chunks:saveMany", pageData),
  getAllPageDataByBookId: (bookId: number) =>
    ipcRenderer.invoke("chunks:getByBookId", bookId),

  // Search
  searchBookText: (query: string, bookId: number) =>
    ipcRenderer.invoke("search:text", query, bookId),
  getTextFromVectorId: (vectorId: number) =>
    ipcRenderer.invoke("search:textFromVectorId", vectorId),
  getContextForQuery: (queryText: string, bookId: number, k: number) =>
    ipcRenderer.invoke("search:contextForQuery", queryText, bookId, k),

  // Vector operations
  embed: (params: unknown[]) => ipcRenderer.invoke("vectors:embed", params),
  saveVectors: (name: string, dim: number, vectors: unknown[]) =>
    ipcRenderer.invoke("vectors:save", name, dim, vectors),
  searchVectors: (name: string, query: number[], dim: number, k: number) =>
    ipcRenderer.invoke("vectors:search", name, query, dim, k),

  // File format operations
  getBookData: (path: string) => ipcRenderer.invoke("formats:getBookData", path),
  getPdfData: (path: string) => ipcRenderer.invoke("formats:getPdfData", path),
  getMobiData: (path: string) => ipcRenderer.invoke("formats:getMobiData", path),
  getDjvuData: (path: string) => ipcRenderer.invoke("formats:getDjvuData", path),
  getMobiChapter: (path: string, chapterIndex: number) =>
    ipcRenderer.invoke("formats:getMobiChapter", path, chapterIndex),
  getMobiChapterCount: (path: string) =>
    ipcRenderer.invoke("formats:getMobiChapterCount", path),
  getMobiText: (path: string, chapterIndex: number) =>
    ipcRenderer.invoke("formats:getMobiText", path, chapterIndex),
  getDjvuPage: (path: string, pageNumber: number, dpi: number) =>
    ipcRenderer.invoke("formats:getDjvuPage", path, pageNumber, dpi),
  getDjvuPageCount: (path: string) =>
    ipcRenderer.invoke("formats:getDjvuPageCount", path),
  getDjvuPageText: (path: string, pageNumber: number) =>
    ipcRenderer.invoke("formats:getDjvuPageText", path, pageNumber),

  // File system
  checkFileSize: (path: string, format: string) =>
    ipcRenderer.invoke("fs:checkFileSize", path, format),
  unzip: (filePath: string, outDir: string) =>
    ipcRenderer.invoke("fs:unzip", filePath, outDir),
  copyFile: (src: string, dest: string) =>
    ipcRenderer.invoke("fs:copyFile", src, dest),
  getAppDataPath: () => ipcRenderer.invoke("fs:getAppDataPath"),
  readFile: (path: string) => ipcRenderer.invoke("fs:readFile", path),
  writeFile: (path: string, data: unknown) =>
    ipcRenderer.invoke("fs:writeFile", path, data),
  exists: (path: string) => ipcRenderer.invoke("fs:exists", path),
  mkdir: (path: string) => ipcRenderer.invoke("fs:mkdir", path),
  readDir: (path: string) => ipcRenderer.invoke("fs:readDir", path),
  removeFile: (path: string) => ipcRenderer.invoke("fs:removeFile", path),
  getDirSize: (path: string) => ipcRenderer.invoke("fs:getDirSize", path),
  getCacheFileStats: (path: string) =>
    ipcRenderer.invoke("fs:getCacheFileStats", path),

  // Vector operations (batch)
  processJob: (
    pageNumber: number,
    bookId: number,
    pageData: Array<{ text: string; id: number }>,
  ) =>
    ipcRenderer.invoke("vectors:processJob", pageNumber, bookId, pageData),

  // Scanner
  getDefaultBookFolders: () => ipcRenderer.invoke("scanner:getDefaultFolders"),
  scanForBooks: (mode: string) => ipcRenderer.invoke("scanner:scan", mode),
  cancelScan: () => ipcRenderer.invoke("scanner:cancel"),

  // Auth
  getAuthToken: () => ipcRenderer.invoke("auth:getToken"),
  saveAuthToken: (token: string, expiresAt: number) =>
    ipcRenderer.invoke("auth:saveToken", token, expiresAt),
  clearAuth: () => ipcRenderer.invoke("auth:clear"),
  getUserFromStore: () => ipcRenderer.invoke("auth:getUserFromStore"),
  saveUserToStore: (user: unknown) =>
    ipcRenderer.invoke("auth:saveUserToStore", user),

  // Deep-link auth (PKCE)
  getOAuthState: () => ipcRenderer.invoke("auth:getOAuthState"),
  completeAuth: (state: string) => ipcRenderer.invoke("auth:completeAuth", state),
  checkAuthStatus: (state: string) =>
    ipcRenderer.invoke("auth:checkAuthStatus", state),
  signout: () => ipcRenderer.invoke("auth:signout"),
  refreshAuthToken: () => ipcRenderer.invoke("auth:refreshToken"),
  getUser: (userId: string) => ipcRenderer.invoke("auth:getUser", userId),
  logAuthDebug: (step: string, data?: string, error?: string) =>
    ipcRenderer.invoke("auth:logDebug", step, data, error),
  getAuthDebug: (state: string) => ipcRenderer.invoke("auth:getDebug", state),
  onDeepLink: (callback: (url: string) => void) => {
    const handler = (_event: unknown, url: string) => callback(url);
    ipcRenderer.on("deep-link", handler);
    return () => {
      ipcRenderer.removeListener("deep-link", handler);
    };
  },

  // Debug/error
  dumpError: (error: unknown) => ipcRenderer.invoke("debug:dumpError", error),
  readErrorDump: () => ipcRenderer.invoke("debug:readErrorDump"),
  clearErrorDump: () => ipcRenderer.invoke("debug:clearErrorDump"),

  // Settings store
  getStoreValue: (key: string) => ipcRenderer.invoke("store:get", key),
  setStoreValue: (key: string, value: unknown) =>
    ipcRenderer.invoke("store:set", key, value),

  // Utilities
  isDev: () => ipcRenderer.invoke("util:isDev"),
  getDevBypassSecret: () => ipcRenderer.invoke("util:getDevBypassSecret"),
  getRealtimeClientSecret: () =>
    ipcRenderer.invoke("util:getRealtimeClientSecret"),
  showOpenDialog: (options: unknown) =>
    ipcRenderer.invoke("dialog:showOpen", options),
  openExternal: (url: string) => ipcRenderer.invoke("shell:openExternal", url),
  getOsInfo: () => ipcRenderer.invoke("util:getOsInfo"),

  // Database (direct Kysely-style queries from renderer)
  dbQuery: (sql: string, params?: unknown[]) =>
    ipcRenderer.invoke("db:query", sql, params),
  dbRun: (sql: string, params?: unknown[]) =>
    ipcRenderer.invoke("db:run", sql, params),

  // Event system
  on: (channel: string, callback: (...args: unknown[]) => void) => {
    const subscription = (_event: unknown, ...args: unknown[]) =>
      callback(...args);
    ipcRenderer.on(channel, subscription);
    return () => {
      ipcRenderer.removeListener(channel, subscription);
    };
  },
  once: (channel: string, callback: (...args: unknown[]) => void) => {
    ipcRenderer.once(channel, (_event, ...args) => callback(...args));
  },
  send: (channel: string, ...args: unknown[]) => {
    ipcRenderer.send(channel, ...args);
  },
};

contextBridge.exposeInMainWorld("electron", electronAPI);
