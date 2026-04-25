/**
 * API bridge - replaces Tauri invoke() commands with Electron IPC.
 * All functions mirror the original Tauri command signatures.
 */

// Re-export types that match the original generated types
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

export interface EmbedParam {
  text: string;
  metadata: { id: number; pageNumber: number; bookId: number };
}

export interface EmbedResult {
  dim: number;
  embedding: number[];
  text?: string | null;
  metadata: { id: number; pageNumber: number; bookId: number };
}

export interface Vector {
  id: number;
  vector: number[];
}

export type FileSizeCheck = "ok" | "warn" | "blocked";

export interface OAuthStateResponse {
  state: string;
  codeChallenge: string;
}

export interface AuthStatusResponse {
  status?: string | null;
  retryCount?: number | null;
  createdAt?: number | null;
  error?: string | null;
}

// Helper to get the electron API
function api() {
  return window.electron;
}

// ---- Books ----
export async function getBooks(): Promise<Book[]> {
  return api().getBooks();
}
export async function getBook(params: { bookId: number }): Promise<Book | null> {
  return api().getBook(params.bookId);
}
export async function saveBook(params: { book: BookInsertable }): Promise<Book> {
  return api().saveBook(params.book);
}
export async function deleteBook(params: { bookId: number }): Promise<void> {
  return api().deleteBook(params.bookId);
}
export async function updateBookCover(params: { bookId: number; newCover: number[] }): Promise<void> {
  return api().updateBookCover(params.bookId, params.newCover);
}
export async function updateBookLocation(params: { bookId: number; newLocation: string }): Promise<void> {
  return api().updateBookLocation(params.bookId, params.newLocation);
}
export async function hasSavedEpubData(params: { bookId: number }): Promise<boolean> {
  return api().hasSavedEpubData(params.bookId);
}

// ---- Chunks/Page Data ----
export async function savePageDataMany(params: { pageData: ChunkDataInsertable[] }): Promise<void> {
  return api().savePageDataMany(params.pageData);
}
export async function getAllPageDataByBookId(params: { bookId: number }): Promise<PageData[]> {
  return api().getAllPageDataByBookId(params.bookId);
}

// ---- Search ----
export async function searchBookText(params: { query: string; bookId: number }): Promise<TextSearchResult[]> {
  return api().searchBookText(params.query, params.bookId);
}
export async function getTextFromVectorId(params: { vectorId: number }): Promise<string> {
  return api().getTextFromVectorId(params.vectorId);
}
export async function getContextForQuery(params: { queryText: string; bookId: number; k: number }): Promise<string[]> {
  return api().getContextForQuery(params.queryText, params.bookId, params.k);
}

// ---- Vectors ----
export async function embed(params: { embedparams: EmbedParam[] }): Promise<EmbedResult[]> {
  return api().embed(params.embedparams);
}
export async function saveVectors(params: { name: string; dim: number; vectors: Vector[] }): Promise<void> {
  return api().saveVectors(params.name, params.dim, params.vectors);
}
export async function searchVectors(params: { name: string; query: number[]; dim: number; k: number }): Promise<SearchResult[]> {
  return api().searchVectors(params.name, params.query, params.dim, params.k);
}

// ---- File Formats ----
export async function getBookData(params: { path: string }): Promise<BookData> {
  return api().getBookData(params.path);
}
export async function getPdfData(params: { path: string }): Promise<BookData> {
  return api().getPdfData(params.path);
}
export async function getMobiData(params: { path: string }): Promise<BookData> {
  return api().getMobiData(params.path);
}
export async function getDjvuData(params: { path: string }): Promise<BookData> {
  return api().getDjvuData(params.path);
}
export async function getMobiChapter(params: { path: string; chapterIndex: number }): Promise<string> {
  return api().getMobiChapter(params.path, params.chapterIndex);
}
export async function getMobiChapterCount(params: { path: string }): Promise<number> {
  return api().getMobiChapterCount(params.path);
}
export async function getMobiText(params: { path: string; chapterIndex: number }): Promise<string[]> {
  return api().getMobiText(params.path, params.chapterIndex);
}
export async function getDjvuPage(params: { path: string; pageNumber: number; dpi: number }): Promise<number[]> {
  return api().getDjvuPage(params.path, params.pageNumber, params.dpi);
}
export async function getDjvuPageCount(params: { path: string }): Promise<number> {
  return api().getDjvuPageCount(params.path);
}
export async function getDjvuPageText(params: { path: string; pageNumber: number }): Promise<string[]> {
  return api().getDjvuPageText(params.path, params.pageNumber);
}

// ---- File System ----
export async function checkFileSize(params: { path: string; format: string }): Promise<FileSizeCheck> {
  return api().checkFileSize(params.path, params.format);
}
export async function unzip(params: { filePath: string; outDir: string }): Promise<string> {
  return api().unzip(params.filePath, params.outDir);
}

// ---- Scanner ----
export async function getDefaultBookFolders(): Promise<string[]> {
  return api().getDefaultBookFolders();
}
export async function scanForBooks(params: { mode: string }): Promise<number> {
  return api().scanForBooks(params.mode);
}
export async function cancelScan(): Promise<void> {
  return api().cancelScan();
}

// ---- Auth ----
export async function getAuthTokenCmd(): Promise<string | null> {
  return api().getAuthToken();
}
export async function signout(): Promise<void> {
  return api().signout();
}
export async function getUserFromStore(): Promise<User | null> {
  return api().getUserFromStore();
}

// ---- Debug ----
export async function dumpErrorCmd(params: { source: string; location: string; error: string; context?: string | null; stack?: string | null }): Promise<void> {
  return api().dumpError(params);
}
export async function readErrorDump(): Promise<string> {
  return api().readErrorDump();
}
export async function clearErrorDump(): Promise<void> {
  return api().clearErrorDump();
}

// ---- Utilities ----
export async function isDev(): Promise<boolean> {
  return api().isDev();
}
export async function getDevBypassSecret(): Promise<string | null> {
  return api().getDevBypassSecret();
}
export async function getRealtimeClientSecret(): Promise<string> {
  return api().getRealtimeClientSecret();
}

// ---- Process Job (embedding + indexing) ----
export async function processJob(params: { pageNumber: number; bookId: number; pageData: ChunkDataInsertable[] }): Promise<void> {
  // Save page data first to get the actual DB row IDs
  await api().savePageDataMany(params.pageData);

  // Retrieve the saved rows to get their actual auto-incremented IDs
  const savedData = await api().getAllPageDataByBookId(params.bookId);
  // Filter to just the pages we saved (by page number match)
  const relevantChunks = savedData.filter(
    (d) => params.pageData.some((pd) => pd.pageNumber === d.pageNumber && pd.data === d.data)
  );

  if (relevantChunks.length === 0) return;

  // Embed using actual DB row IDs so vector search results can be looked up
  const embedResults = await api().embed(relevantChunks.map((chunk) => ({
    text: chunk.data,
    metadata: { id: chunk.id, pageNumber: chunk.pageNumber, bookId: params.bookId },
  })));
  if (embedResults.length > 0) {
    const vectors = embedResults.map((r) => ({
      id: r.metadata.id,
      vector: r.embedding,
    }));
    await api().saveVectors(`book_${params.bookId}`, embedResults[0].dim, vectors);
  }
}

// ---- Helpers ----
/**
 * Convert a local file path to a URL that the renderer can load.
 * Uses the custom `local-file://` protocol registered in the main process,
 * which serves files from the filesystem securely (like Tauri's asset://).
 */
export function convertFileSrc(filepath: string): string {
  if (filepath.startsWith("local-file://")) return filepath;
  if (filepath.startsWith("file://")) return filepath.replace("file://", "local-file://");
  if (filepath.startsWith("/")) return `local-file://${filepath}`;
  return filepath;
}
