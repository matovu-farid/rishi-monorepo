import type {
  BookInsertable,
  Book,
  ChunkDataInsertable,
  PageData,
  Vector,
  EmbedParam,
  EmbedResult
} from '@/lib/api'
import type { RagService } from '../rag'

/** Supported file extensions, normalized to lowercase. */
export type BookFormat = 'epub' | 'pdf' | 'mobi' | 'azw3'

/** What a format port returns after parsing. Shape from `@/lib/api`. */
export interface BookDataParsed {
  kind: string
  cover: number[]
  title?: string | null
  author?: string | null
  publisher?: string | null
  coverKind?: string | null
}

/** A single chunk of indexed page data passed into `indexBook`. */
export interface PageDataInsertable {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export interface ImportSuccess {
  ok: true
  bookId: number
  filePath: string
  format: BookFormat
}

export interface ImportFailure {
  ok: false
  filePath: string
  /** Which stage failed. */
  stage: 'unsupported' | 'copy' | 'parse' | 'save' | 'unknown'
  error: string
}

export type ImportResult = ImportSuccess | ImportFailure

/** Per-file pipeline lifecycle event. */
export type ImportProgressEvent =
  | { kind: 'copying'; filePath: string }
  | { kind: 'parsing'; filePath: string; format: BookFormat }
  | { kind: 'saving'; filePath: string; format: BookFormat }
  | { kind: 'upload-started'; filePath: string; bookId: number }
  | { kind: 'upload-failed'; filePath: string; bookId: number; error: string }
  | { kind: 'indexing'; bookId: number; reason: 'chunks-missing' | 'vectors-missing' }
  | { kind: 'indexed'; bookId: number; ok: boolean }
  | { kind: 'done'; filePath: string; bookId: number; format: BookFormat }
  | { kind: 'failed'; filePath: string; stage: ImportFailure['stage']; error: string }

/** Discovered-book record streamed by the scanner port. */
export interface DiscoveredBook {
  filepath: string
  filename: string
  title: string | null
  author: string | null
  format: string
  fileSize: number
  folder: string
  fileHash: string | null
}

export interface ScanProgress {
  folder: string
  scanned: number
  total: number
}

export type DiscoveryEvent =
  | { kind: 'book-found'; book: DiscoveredBook }
  | { kind: 'progress'; progress: ScanProgress }
  | { kind: 'complete'; cancelled: boolean }
  | { kind: 'error'; error: string }

/** The format IPCs the service uses. */
export interface FormatsIpc {
  getBookData(path: string): Promise<BookDataParsed>
  getPdfData(path: string): Promise<BookDataParsed>
  getMobiData(path: string): Promise<BookDataParsed>
  getAzw3Data(path: string): Promise<BookDataParsed>
}

/** Exactly the five DB IPCs the service uses. */
export interface BookStoreIpc {
  saveBook(book: BookInsertable): Promise<Book>
  savePageDataMany(pageData: ChunkDataInsertable[]): Promise<void>
  getAllPageDataByBookId(bookId: number): Promise<PageData[]>
  hasSavedEpubData(bookId: number): Promise<boolean>
  saveVectors(name: string, dim: number, vectors: Vector[]): Promise<void>
}

/** Exactly the six FS IPCs the service uses. */
export interface FsIpc {
  copyBookToAppData(filePath: string): Promise<string>
  removeFile(path: string): Promise<void>
  getAppDataPath(): Promise<string>
}

/** File-hash + R2 upload helpers. Best-effort consumers. */
export interface FileSyncIpc {
  hashBookFile(filePath: string): Promise<string>
  uploadBookFile(
    filePath: string,
    hash: string,
    format: 'epub' | 'pdf' | 'mobi'
  ): Promise<{ r2Key: string }>
  booksUpdateFileHash(bookId: number, hash: string, r2Key: string): Promise<void>
}

/** Scanner port — wraps `window.electron.scanForBooks` + the three IPC events. */
export interface ScannerPort {
  start(mode: 'default' | 'full'): Promise<void>
  cancel(): Promise<void>
  on(kind: 'result', listener: (book: DiscoveredBook) => void): () => void
  on(kind: 'progress', listener: (progress: ScanProgress) => void): () => void
  on(kind: 'complete', listener: () => void): () => void
}

export interface BookImportConfig {
  /** Per-stage timeouts. Defaults match today: 120_000 / 60_000 / 30_000 ms. */
  copyTimeoutMs: number
  parseTimeoutMs: number
  saveTimeoutMs: number
  /** Embedding batch size. Default 2. */
  embedBatchSize: number
}

export interface BookImportServiceDeps {
  formats: FormatsIpc
  db: BookStoreIpc
  fs: FsIpc
  fileSync: FileSyncIpc
  rag: RagService
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  scanner: ScannerPort
  config: BookImportConfig
}

export interface BookImportService {
  /**
   * Single-file import: copy -> parse (by extension) -> save -> fire-and-forget
   * hash+upload -> emit done. Resolves with discriminated `ImportResult`; does
   * not reject for classified failures.
   */
  importFromPath(filePath: string): Promise<ImportResult>

  /**
   * Sequential bulk import. Each file processed via `importFromPath`; failures
   * isolated per item; results returned in input order. Never rejects.
   */
  importBatch(filePaths: string[]): Promise<ImportResult[]>

  /**
   * Run RAG indexing for a book. Skips if both chunks and vectors exist.
   * Re-embeds if chunks exist but vectors missing. If `pageData` omitted, reads
   * chunks from the DB via `db.getAllPageDataByBookId`.
   */
  indexBook(bookId: number, pageData?: PageDataInsertable[]): Promise<void>

  /**
   * Returns true while `indexBook(bookId, …)` is in flight. Used by the
   * voice-chat realtime agent to tell the user "still indexing, try again"
   * instead of returning an empty bookContext result.
   */
  isIndexing(bookId: number): boolean

  /**
   * Start the scanner. Calling while a scan is running cancels the prior scan
   * first (single-flight). Results stream via `onDiscoveryEvent`.
   */
  startDiscovery(mode: 'default' | 'full'): void

  /**
   * Abort the running scan. Idempotent. Emits `{ kind: 'complete', cancelled: true }`.
   */
  cancelDiscovery(): Promise<void>

  onDiscoveryEvent(listener: (event: DiscoveryEvent) => void): () => void
  onImportProgress(listener: (event: ImportProgressEvent) => void): () => void
}
