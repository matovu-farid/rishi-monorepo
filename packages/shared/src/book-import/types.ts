/**
 * Shared book-import service — port-injected.
 *
 * Ported from `apps/rishi-electron/src/renderer/src/services/book-import/`
 * with two changes:
 *
 * 1. The platform-specific scanner port (folder scan via IPC) is dropped.
 *    Mobile has no folder-scan UX; electron's adapter still lives in the
 *    renderer.
 * 2. `BookId` is generic so electron (numeric D1 ids) and mobile (UUID
 *    strings) can both adopt the service without forcing one to mint
 *    fake ids.
 *
 * The two production callers (electron's `service.ts`, mobile's
 * `file-import.ts`) implement the ports against their own DB, FS, R2
 * upload, embedder, and cover-extractor stacks.
 */

/** Supported file extensions, normalized to lowercase. */
export type BookFormat = "epub" | "pdf" | "mobi" | "azw3" | "djvu";

/** Bare-minimum metadata a `FormatsPort` returns. */
export interface BookDataParsed {
  kind: string;
  cover: number[];
  title?: string | null;
  author?: string | null;
  publisher?: string | null;
  coverKind?: string | null;
}

/** A single chunk passed into `indexBook`. */
export interface PageDataInsertable<BookId> {
  id: number;
  pageNumber: number;
  bookId: BookId;
  data: string;
}

export interface ImportSuccess<BookId> {
  ok: true;
  bookId: BookId;
  filePath: string;
  format: BookFormat;
}

export interface ImportFailure {
  ok: false;
  filePath: string;
  /** Which stage failed. */
  stage: "unsupported" | "copy" | "parse" | "save" | "unknown";
  error: string;
}

export type ImportResult<BookId> = ImportSuccess<BookId> | ImportFailure;

/** Per-file pipeline lifecycle event. Identical to electron's shape. */
export type ImportProgressEvent<BookId> =
  | { kind: "copying"; filePath: string }
  | { kind: "parsing"; filePath: string; format: BookFormat }
  | { kind: "saving"; filePath: string; format: BookFormat }
  | { kind: "upload-started"; filePath: string; bookId: BookId }
  | {
      kind: "upload-failed";
      filePath: string;
      bookId: BookId;
      error: string;
    }
  | {
      kind: "indexing";
      bookId: BookId;
      reason: "chunks-missing" | "vectors-missing";
    }
  | { kind: "indexed"; bookId: BookId; ok: boolean }
  | { kind: "done"; filePath: string; bookId: BookId; format: BookFormat }
  | {
      kind: "failed";
      filePath: string;
      stage: ImportFailure["stage"];
      error: string;
    };

// ────────────────────────────────────────────────────────────────────────────
// Ports — caller-provided adapters
// ────────────────────────────────────────────────────────────────────────────

/** Format extraction (one method per format). */
export interface FormatsPort {
  getBookData(path: string): Promise<BookDataParsed>;
  getPdfData(path: string): Promise<BookDataParsed>;
  getMobiData(path: string): Promise<BookDataParsed>;
  getAzw3Data(path: string): Promise<BookDataParsed>;
}

/**
 * DB port — exactly the operations the service performs. `Book` is the
 * platform's own row shape (electron: `Book` from drizzle/D1; mobile:
 * `Book` from @/types/book).
 */
export interface DbPort<BookId, Book, BookInsertable> {
  /** Persist a parsed book + return the inserted row (with id). */
  saveBook(book: BookInsertable): Promise<Book>;
  /** Persist a batch of chunks. */
  savePageDataMany(
    pageData: PageDataInsertable<BookId>[],
  ): Promise<void>;
  /** Read all chunks for a book (the indexer's recovery path). */
  getAllPageDataByBookId(
    bookId: BookId,
  ): Promise<PageDataInsertable<BookId>[]>;
  /** Does the book have any persisted chunks? */
  hasSavedEpubData(bookId: BookId): Promise<boolean>;
  /**
   * Persist embedding vectors for a book. The `name` is electron's vec
   * database name (`<bookId>-vectordb`); on mobile this is informational.
   */
  saveVectors(
    name: string,
    dim: number,
    vectors: { id: number; vector: number[] }[],
  ): Promise<void>;
  /** Update a book's cover URI after the cover port resolves. */
  updateBookCover?(bookId: BookId, coverPath: string): Promise<void>;
}

/** FS port — only the operations electron-style import needs. */
export interface FsPort {
  copyBookToAppData(filePath: string): Promise<string>;
  removeFile(path: string): Promise<void>;
  /**
   * Remove the per-book directory that contains `bookPath` (issue #209).
   *
   * Mobile mints `books/<bookId>/book.<ext>` and the orphan directory leaks
   * on parse / save failure if only the file is removed. Implementations
   * that own a per-book directory should delete the whole dir here;
   * implementations that don't (electron writes a flat
   * `userData/<filename>`) can omit this and the importer falls back to
   * `removeFile`.
   *
   * Best-effort: implementations MUST NOT throw on a missing dir, and the
   * importer treats any rejection as non-fatal (the original parse / save
   * error is the one propagated to the caller).
   */
  removeBookDir?(bookPath: string): Promise<void>;
}

/** R2 upload port. */
export interface UploadPort<BookId> {
  /** Hash + upload + DB-update. Best-effort. */
  hashAndUpload(opts: {
    bookId: BookId;
    bookPath: string;
    format: BookFormat;
  }): Promise<void>;
}

/** Embedder port — chunk-and-embed for indexing. */
export interface EmbedPort {
  /**
   * Generate text chunks for a book by reading from local storage. Used by
   * the indexer to backfill chunks when none exist yet.
   *
   * Returns an empty array when the format can't be chunked (e.g. missing
   * extractor on mobile). Callers should NOT throw.
   */
  generateChunks(opts: {
    bookId: string | number;
    filePath: string;
    format: BookFormat;
  }): Promise<PageDataInsertable<string | number>[]>;

  /** Embed a batch of texts into vectors. May throw. */
  embed(
    texts: { text: string; metadata: { id: number; pageNumber: number } }[],
  ): Promise<
    { embedding: number[]; metadata: { id: number; pageNumber: number } }[]
  >;

  /** Has this book been fully embedded into the vector store? */
  isIndexed(bookId: string | number): Promise<boolean>;
}

/**
 * Cover extraction + upload port. Mobile uses `extractEpubCover` from
 * `@rishi/shared/formats/epub-cover` plus R2 upload; electron skips this
 * because it stores the cover bytes inline on the row.
 *
 * The returned path is whatever the platform's `<Image>` loads (file://,
 * https://, asset://).
 */
export interface CoverPort {
  extractAndStore(opts: {
    bookId: string | number;
    bookPath: string;
    format: BookFormat;
  }): Promise<string | null>;
}

/** Tiny emitter primitive. */
export interface EmitterPort<T> {
  emit(payload: T): void;
  on(listener: (payload: T) => void): () => void;
}

// ────────────────────────────────────────────────────────────────────────────
// Service config + deps
// ────────────────────────────────────────────────────────────────────────────

export interface BookImportConfig {
  /** Per-stage timeouts. Defaults match today: 120_000 / 60_000 / 30_000 ms. */
  copyTimeoutMs: number;
  parseTimeoutMs: number;
  saveTimeoutMs: number;
  /** Embedding batch size. Default 2. */
  embedBatchSize: number;
}

/**
 * Service deps. Generic over `BookId`, `Book`, `BookInsertable` so the
 * platform's own row types flow through without re-mapping.
 *
 * - `formats`: parse-by-extension. May be null on mobile when the upstream
 *   metadata-extraction lives directly in the importer (the mobile
 *   pipeline doesn't separate parse from save).
 */
export interface BookImportServiceDeps<BookId, Book, BookInsertable> {
  formats: FormatsPort;
  db: DbPort<BookId, Book, BookInsertable>;
  fs: FsPort;
  upload: UploadPort<BookId>;
  embed: EmbedPort;
  cover?: CoverPort;
  config: BookImportConfig;
  /**
   * Build the `BookInsertable` from the parsed format data + the dest
   * file path. Platform-specific (electron uses numeric ids, mobile uses
   * UUIDs and a `coverPath` column).
   */
  buildBookInsertable(opts: {
    bookData: BookDataParsed;
    filePath: string;
    bookPath: string;
    format: BookFormat;
  }): BookInsertable;
}

export interface BookImportService<BookId> {
  /**
   * Single-file import: copy -> parse (by extension) -> save -> emit done.
   * Cover extraction + R2 upload run after `done` as fire-and-forget
   * side-effects.
   */
  importFromPath(filePath: string): Promise<ImportResult<BookId>>;

  /**
   * Sequential bulk import. Each file processed via `importFromPath`;
   * failures isolated per item; results returned in input order. Never
   * rejects.
   */
  importBatch(filePaths: string[]): Promise<ImportResult<BookId>[]>;

  /**
   * Run RAG indexing for a book. Skips if both chunks and vectors exist.
   * Re-embeds if chunks exist but vectors missing.
   *
   * If `pageData` is omitted the indexer reads chunks from the DB via
   * `db.getAllPageDataByBookId`. If no chunks exist either, it falls back
   * to `embed.generateChunks` to create them.
   */
  indexBook(
    bookId: BookId,
    pageData?: PageDataInsertable<BookId>[],
    filePath?: string,
    format?: BookFormat,
  ): Promise<void>;

  /** True while `indexBook(bookId, …)` is in flight. */
  isIndexing(bookId: BookId): boolean;

  onImportProgress(
    listener: (event: ImportProgressEvent<BookId>) => void,
  ): () => void;
}
