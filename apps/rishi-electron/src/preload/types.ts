export interface ElectronAPI {
  // Book operations
  getBooks: () => Promise<Book[]>;
  getBook: (bookId: number) => Promise<Book | null>;
  saveBook: (book: BookInsertable) => Promise<Book>;
  deleteBook: (bookId: number) => Promise<void>;
  updateBookCover: (bookId: number, cover: number[]) => Promise<void>;
  updateBookLocation: (bookId: number, location: string) => Promise<void>;
  hasSavedEpubData: (bookId: number) => Promise<boolean>;

  // Page/chunk data
  savePageDataMany: (pageData: ChunkDataInsertable[]) => Promise<void>;
  getAllPageDataByBookId: (bookId: number) => Promise<PageData[]>;

  // Search
  searchBookText: (query: string, bookId: number) => Promise<TextSearchResult[]>;
  getTextFromVectorId: (vectorId: number) => Promise<string>;
  getContextForQuery: (
    queryText: string,
    bookId: number,
    k: number
  ) => Promise<string[]>;

  // Vector operations
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>;
  saveVectors: (
    name: string,
    dim: number,
    vectors: VectorData[]
  ) => Promise<void>;
  searchVectors: (
    name: string,
    query: number[],
    dim: number,
    k: number
  ) => Promise<SearchResult[]>;

  // File format operations
  getBookData: (path: string) => Promise<BookData>;
  getPdfData: (path: string) => Promise<BookData>;
  getMobiData: (path: string) => Promise<BookData>;
  getDjvuData: (path: string) => Promise<BookData>;
  getMobiChapter: (path: string, chapterIndex: number) => Promise<string>;
  getMobiChapterCount: (path: string) => Promise<number>;
  getMobiText: (path: string, chapterIndex: number) => Promise<string[]>;
  getDjvuPage: (
    path: string,
    pageNumber: number,
    dpi: number
  ) => Promise<number[]>;
  getDjvuPageCount: (path: string) => Promise<number>;
  getDjvuPageText: (path: string, pageNumber: number) => Promise<string[]>;

  // File system
  checkFileSize: (path: string, format: string) => Promise<FileSizeCheck>;
  unzip: (filePath: string, outDir: string) => Promise<string>;
  copyFile: (src: string, dest: string) => Promise<void>;
  getAppDataPath: () => Promise<string>;
  readFile: (path: string) => Promise<ArrayBuffer>;
  writeFile: (path: string, data: unknown) => Promise<void>;
  exists: (path: string) => Promise<boolean>;
  mkdir: (path: string) => Promise<void>;
  readDir: (path: string) => Promise<string[]>;
  removeFile: (path: string) => Promise<void>;
  getDirSize: (path: string) => Promise<number>;
  getCacheFileStats: (
    path: string,
  ) => Promise<Array<{ path: string; size: number; mtimeMs: number }>>;

  // Vector operations (batch)
  processJob: (
    pageNumber: number,
    bookId: number,
    pageData: Array<{ text: string; id: number }>,
  ) => Promise<void>;

  // Scanner
  getDefaultBookFolders: () => Promise<string[]>;
  scanForBooks: (mode: string) => Promise<number>;
  cancelScan: () => Promise<void>;

  // Auth
  getAuthToken: () => Promise<string | null>;
  saveAuthToken: (token: string, expiresAt: number) => Promise<void>;
  clearAuth: () => Promise<void>;
  getUserFromStore: () => Promise<User | null>;
  saveUserToStore: (user: User) => Promise<void>;

  // Deep-link auth (PKCE)
  getOAuthState: () => Promise<{ state: string; codeChallenge: string }>;
  completeAuth: (state: string) => Promise<User>;
  checkAuthStatus: (state: string) => Promise<{ status?: string; retryCount?: number; createdAt?: number; error?: string }>;
  signout: () => Promise<void>;
  onDeepLink: (callback: (url: string) => void) => () => void;

  // Token refresh & user fetch
  refreshAuthToken: () => Promise<number | null>;
  getUser: (userId: string) => Promise<User | null>;

  // Auth debug
  logAuthDebug: (step: string, data?: string, error?: string) => Promise<void>;
  getAuthDebug: (state: string) => Promise<unknown[]>;

  // Debug
  dumpError: (error: ErrorDump) => Promise<void>;
  readErrorDump: () => Promise<string>;
  clearErrorDump: () => Promise<void>;
  dumpState: (json: string) => Promise<void>;
  readStateDump: () => Promise<string>;

  // Settings store
  getStoreValue: (key: string) => Promise<unknown>;
  setStoreValue: (key: string, value: unknown) => Promise<void>;

  // Utilities
  isDev: () => Promise<boolean>;
  getDevBypassSecret: () => Promise<string | null>;
  getRealtimeClientSecret: () => Promise<string>;
  showOpenDialog: (options: unknown) => Promise<{ filePaths: string[] }>;
  openExternal: (url: string) => Promise<void>;
  getOsInfo: () => Promise<{ platform: string; arch: string; version: string }>;

  // Database
  dbQuery: (sql: string, params?: unknown[]) => Promise<unknown[]>;
  dbRun: (sql: string, params?: unknown[]) => Promise<{ changes: number; lastInsertRowid: number }>;

  // Events
  on: (channel: string, callback: (...args: unknown[]) => void) => () => void;
  once: (channel: string, callback: (...args: unknown[]) => void) => void;
  send: (channel: string, ...args: unknown[]) => void;
}

export type FileSizeCheck = "ok" | "warn" | "blocked";

export interface User {
  id: string;
  firstName?: string | null;
  lastName?: string | null;
  fullName?: string | null;
  username?: string | null;
  imageUrl?: string | null;
  hasImage: boolean;
  lastSignInAt?: number | null;
  externalId?: string | null;
}

export interface Book {
  id: number;
  kind: string;
  cover: number[];
  title: string;
  author: string;
  publisher: string;
  filepath: string;
  location: string;
  coverKind: string;
  version: number;
  syncId?: string | null;
  fileHash?: string | null;
  fileR2Key?: string | null;
  coverR2Key?: string | null;
  format: string;
  currentCfi?: string | null;
  currentPage?: number | null;
  userId?: string | null;
  syncVersion: number;
  isDirty: number;
  isDeleted: number;
}

export interface BookInsertable {
  id?: number | null;
  kind: string;
  cover: number[];
  title: string;
  author: string;
  publisher: string;
  filepath: string;
  location: string;
  coverKind: string;
  version: number;
  syncId?: string | null;
  fileHash?: string | null;
  fileR2Key?: string | null;
  coverR2Key?: string | null;
  format?: string | null;
  currentCfi?: string | null;
  currentPage?: number | null;
  userId?: string | null;
  syncVersion?: number | null;
  isDirty?: number | null;
  isDeleted?: number | null;
}

export interface BookData {
  id: string;
  kind: string;
  cover: number[];
  title?: string | null;
  author?: string | null;
  publisher?: string | null;
  filepath: string;
  location: string;
  coverKind?: string | null;
  version: number;
}

export interface PageData {
  id: number;
  pageNumber: number;
  bookId: number;
  data: string;
}

export interface ChunkDataInsertable {
  id?: number | null;
  pageNumber: number;
  bookId: number;
  data: string;
}

export interface TextSearchResult {
  id: number;
  pageNumber: number;
  bookId: number;
  data: string;
  snippet: string;
}

export interface SearchResult {
  id: number;
  distance: number;
}

export interface VectorData {
  id: number;
  vector: number[];
}

export interface EmbedParam {
  text: string;
  metadata: {
    id: number;
    pageNumber: number;
    bookId: number;
  };
}

export interface EmbedResult {
  dim: number;
  embedding: number[];
  text?: string | null;
  metadata: {
    id: number;
    pageNumber: number;
    bookId: number;
  };
}

export interface ErrorDump {
  source: string;
  location: string;
  error: string;
  context?: string | null;
  stack?: string | null;
}

declare global {
  interface Window {
    electron: ElectronAPI;
  }
}
