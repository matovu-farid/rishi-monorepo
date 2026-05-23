/**
 * Port implementations binding the shared @rishi/shared/book-import service
 * to mobile's Drizzle DB, expo-file-system, R2 upload, on-device embedder,
 * and EPUB cover extractor.
 *
 * Each adapter is a small wrapper; the heavy lifting lives in the modules
 * they delegate to (book-storage, file-sync, rag/*, extractEpubCover).
 */

import { File, Directory, Paths } from "expo-file-system";
import { eq } from "drizzle-orm";
import type {
  BookFormat,
  CoverPort,
  DbPort,
  EmbedPort,
  FsPort,
  PageDataInsertable,
  UploadPort,
} from "@rishi/shared/book-import";
import { extractEpubCover } from "@rishi/shared/formats/epub-cover";
import { extractMobiCover } from "@rishi/shared/formats/mobi";
import { books } from "@rishi/shared/schema";
import { db } from "@/lib/db";
import { hashBookFile, uploadBookFile, UploadLimitError } from "@/lib/sync/file-sync";
import { useUploadErrorStore } from "@/lib/sync/upload-error-store";
import { triggerSyncOnWrite } from "@/lib/sync/triggers";
import { getChunks } from "@/lib/rag/chunker";
import { embedBatch, isEmbeddingReady } from "@/lib/rag/embedder";
import { embedTextsOnServer } from "@/lib/rag/server-fallback";
import {
  deleteBookChunks,
  insertChunkWithVector,
  isBookEmbedded,
} from "@/lib/rag/vector-store";

/**
 * Mobile-specific Book row shape used by the shared service. Mirrors
 * `@/types/book.Book` but is local to this module so it's clear what the
 * port consumes.
 */
export interface MobileBookRow {
  id: string;
  title: string;
  author: string;
  coverPath: string | null;
  filePath: string;
  format: BookFormat;
  currentCfi: string | null;
  currentPage: number | null;
  createdAt: number;
}

export interface MobileBookInsertable
  extends Omit<MobileBookRow, "id" | "createdAt"> {
  /** UUID generated at import time. */
  id: string;
  createdAt: number;
}

const BOOKS_DIR = new Directory(Paths.document, "books");

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

function fileExtForFormat(format: BookFormat): string {
  // azw3 lives in its own file on disk but shares the .mobi extension in the
  // bucket'd-by-format convention. Keep the literal extension so the file is
  // recognised by readers.
  return format;
}

function ensureBooksDir(): void {
  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true });
  }
}

// ────────────────────────────────────────────────────────────────────────────
// FsPort — copy source file into the per-book directory under app docs
// ────────────────────────────────────────────────────────────────────────────

/**
 * Build an FsPort tied to a specific {bookId, format}. The service calls
 * `copyBookToAppData(filePath)` with the source URI; we copy into
 * `books/<bookId>/book.<format>`.
 *
 * The (bookId, format) baking is necessary because mobile's import flow
 * generates a bookId BEFORE the copy step (Drizzle row is inserted later).
 */
export function createMobileFsPort(opts: {
  bookId: string;
  format: BookFormat;
}): FsPort {
  return {
    async copyBookToAppData(filePath: string): Promise<string> {
      ensureBooksDir();
      const bookDir = new Directory(BOOKS_DIR, opts.bookId);
      bookDir.create({ intermediates: true, idempotent: true });

      const destFile = new File(
        bookDir,
        `book.${fileExtForFormat(opts.format)}`,
      );

      // Source may be a file:// URI or a content:// URI handed back by
      // expo-file-system's picker.
      const sourceFile = new File(filePath);
      try {
        sourceFile.copy(destFile);
      } catch (err) {
        // DAT-011 (#123): if the copy step blows up (ENOSPC, EACCES,
        // truncated source, etc.) the per-book dir we just created is
        // empty — leaving it on disk would litter the app sandbox with
        // dead `books/<uuid>/` entries for every failed picker import.
        // Roll back the dir before re-throwing so the upstream
        // classifyFailure() still sees the original error.
        try {
          if (bookDir.exists) {
            bookDir.delete();
          }
        } catch {
          /* best-effort */
        }
        throw err;
      }
      return destFile.uri;
    },

    async removeFile(path: string): Promise<void> {
      try {
        new File(path).delete();
      } catch {
        // best-effort
      }
    },
  };
}

// ────────────────────────────────────────────────────────────────────────────
// DbPort — wraps Drizzle calls against the books table + chunks store.
// ────────────────────────────────────────────────────────────────────────────

export function createMobileDbPort(): DbPort<
  string,
  MobileBookRow,
  MobileBookInsertable
> {
  return {
    async saveBook(insertable) {
      // DAT-001 (#114): atomic insert. If anything between the row write
      // and returning the row shape throws (e.g. triggerSyncOnWrite blows
      // up on the sync engine, or row-shape construction fails), we MUST
      // roll back the just-inserted row. Otherwise the books table keeps
      // a row pointing at a copied file whose post-save pipeline never
      // completed, and the user sees a permanently broken entry.
      //
      // The shared importer already runs copy BEFORE save (see
      // packages/shared/src/book-import/importer.ts), so a copy failure
      // never reaches this path. This guard covers the other half of the
      // window: failures DURING save itself.
      db.insert(books)
        .values({
          id: insertable.id,
          title: insertable.title,
          author: insertable.author,
          coverPath: insertable.coverPath,
          filePath: insertable.filePath,
          format: insertable.format,
          currentCfi: insertable.currentCfi,
          currentPage: insertable.currentPage,
          createdAt: insertable.createdAt,
          updatedAt: Date.now(),
          isDirty: true,
          isDeleted: false,
        })
        .run();
      try {
        // Without this, the new book row sits with isDirty=true until either
        // the app is backgrounded or the 5-minute periodic timer fires. The
        // legacy `book-storage.insertBook` path triggers sync; we must too
        // so freshly imported books reach D1 promptly. (H3-03)
        triggerSyncOnWrite();
        // Construct the row shape the service expects (the inserted row).
        return {
          id: insertable.id,
          title: insertable.title,
          author: insertable.author,
          coverPath: insertable.coverPath,
          filePath: insertable.filePath,
          format: insertable.format,
          currentCfi: insertable.currentCfi,
          currentPage: insertable.currentPage,
          createdAt: insertable.createdAt,
        };
      } catch (err) {
        // Roll back the orphan row before rethrowing so the import surface
        // sees a clean "save failed" outcome (no row, no file ownership).
        try {
          db.delete(books).where(eq(books.id, insertable.id)).run();
        } catch {
          /* best-effort; the row may still be there if delete itself
             failed, but rethrowing the original error is more useful to
             the caller than masking it. */
        }
        throw err;
      }
    },

    async savePageDataMany(_pageData) {
      // No-op on mobile. EmbedPort.generateChunks already writes both
      // chunks AND vectors via insertChunkWithVector — they're stored
      // together in mobile's sqlite-vec schema, unlike electron which
      // splits chunks and vectors across two tables. The shared
      // indexer still calls this method as part of its contract; mobile
      // simply has nothing left to do.
    },

    async getAllPageDataByBookId(_bookId): Promise<
      PageDataInsertable<string>[]
    > {
      // Mobile doesn't store the same numeric-id chunk shape electron uses;
      // returning [] here forces the generateChunks fallback when chunks
      // aren't found, which matches mobile's import flow where chunks are
      // produced on the fly.
      return [];
    },

    async hasSavedEpubData(bookId): Promise<boolean> {
      return isBookEmbedded(bookId);
    },

    async saveVectors(_name, _dim, _vectors): Promise<void> {
      // No-op on mobile. The chunks + vectors are written together via
      // insertChunkWithVector inside the EmbedPort.embed pathway, NOT via
      // a separate saveVectors call. The shared indexer still calls this
      // method (it's part of the contract) but we have nothing to do.
    },

    async updateBookCover(bookId, coverPath): Promise<void> {
      db.update(books)
        .set({ coverPath, updatedAt: Date.now(), isDirty: true })
        .where(eq(books.id, bookId))
        .run();
      // Same parity reason as saveBook above — cover-only updates must
      // also nudge the sync engine. (H3-03)
      triggerSyncOnWrite();
    },
  };
}

// ────────────────────────────────────────────────────────────────────────────
// UploadPort — hash + R2 upload, then patch the book row.
// ────────────────────────────────────────────────────────────────────────────

export function createMobileUploadPort(): UploadPort<string> {
  return {
    async hashAndUpload({ bookId, bookPath, format }) {
      // 'azw3' lands in the same R2 bucket as 'mobi'.
      const r2Format: "epub" | "pdf" | "mobi" | "djvu" =
        format === "azw3" ? "mobi" : (format as "epub" | "pdf" | "mobi" | "djvu");
      const fileHash = await hashBookFile(bookPath);
      // Compute file size in bytes — required by the worker for storage-cap
      // enforcement (per-file 800 MB, per-user 10 GB / 500 books). Persist
      // onto the local row so it pushes to D1 via the next sync window.
      const fileSize = new File(bookPath).size ?? 0;
      db.update(books)
        .set({ fileHash, fileSize, isDirty: true })
        .where(eq(books.id, bookId))
        .run();
      try {
        const { r2Key } = await uploadBookFile(bookPath, fileHash, r2Format, fileSize);
        db.update(books)
          .set({ fileR2Key: r2Key, isDirty: true })
          .where(eq(books.id, bookId))
          .run();
      } catch (err) {
        // Storage-cap rejection — surface the typed error to the UI via the
        // global upload-error store so the snackbar can render. The book row
        // still exists locally (the user can read it on this device); we
        // simply leave fileR2Key unset so sync won't try to round-trip it.
        if (err instanceof UploadLimitError) {
          useUploadErrorStore.getState().show({
            code: err.code,
            limit: err.limit,
            current: err.current,
          });
        }
        throw err;
      }
    },
  };
}

// ────────────────────────────────────────────────────────────────────────────
// EmbedPort — wraps mobile's chunker + on-device embedder + vector store.
// ────────────────────────────────────────────────────────────────────────────

/**
 * Mobile's embed port. `generateChunks` runs the format-aware chunker (EPUB
 * native, PDF/DJVU via WebView extractors, MOBI/AZW3 via PalmDOC parser)
 * AND writes the chunk-rows + vectors directly via insertChunkWithVector
 * because that's mobile's storage contract.
 *
 * That means by the time `generateChunks` returns, the chunks + vectors are
 * already in sqlite. The returned `PageDataInsertable[]` is a sentinel for
 * the shared indexer ("chunks now exist"); the indexer's
 * `savePageDataMany` is a no-op on mobile (see DbPort above).
 *
 * Why fold the storage into generateChunks: the existing
 * `apps/mobile/lib/rag/pipeline.embedBook` already does this exact
 * sequence, and matching it avoids changing the chunk/vector schema or
 * adding a new pre-vector-row format. The shared indexer's batching is
 * still useful for the regression-recovery branch on electron, so we keep
 * it.
 */
/**
 * DAT-007 (#120): module-level in-flight lock. Concurrent
 * `generateChunks(bookId)` calls must coalesce onto the same Promise so
 * we never run two embed loops for the same book. Previously, two
 * callers (e.g. file-import.runImportWithService's fire-and-forget
 * indexBook AND a user-initiated reindex from the chat screen) could
 * both win the `isBookEmbedded` check before either had written its
 * first chunk, then race each other into duplicate vectors.
 *
 * Keyed on String(bookId); the entry is deleted in a finally block so
 * the lock releases on both success and failure, allowing genuine
 * retries to proceed.
 */
const inFlightEmbedByBookId = new Map<
  string,
  Promise<PageDataInsertable<string>[]>
>();

async function runEmbedPipeline(
  bookId: string,
  filePath: string,
  format: BookFormat,
): Promise<PageDataInsertable<string>[]> {
  if (isBookEmbedded(bookId)) return [];

  const chunks = await getChunks(filePath, format, bookId);
  if (chunks.length === 0) return [];

  const BATCH_SIZE = 10;
  try {
    for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
      const batch = chunks.slice(i, i + BATCH_SIZE);
      const texts = batch.map((c) => c.text);

      let embeddings: number[][];
      if (isEmbeddingReady()) {
        try {
          embeddings = await embedBatch(texts);
        } catch (err) {
          console.warn(
            "[book-import] on-device embed failed, falling back to server:",
            err,
          );
          embeddings = await embedTextsOnServer(texts);
        }
      } else {
        embeddings = await embedTextsOnServer(texts);
      }

      for (let j = 0; j < batch.length; j++) {
        const chunk = batch[j];
        insertChunkWithVector(
          chunk.id,
          bookId,
          chunk.chunkIndex,
          chunk.text,
          chunk.chapter,
          embeddings[j],
        );
      }
    }
  } catch (err) {
    // DAT-004 (#117): mid-batch failure must NOT leave the book
    // half-indexed. `isBookEmbedded` returns true as soon as ≥1 chunk
    // is in sqlite, so without this rollback the book would be stuck
    // in a "partially indexed, will never re-index" state. Delete
    // every chunk we wrote for this book before re-throwing so a
    // retry sees a clean slate.
    try {
      deleteBookChunks(bookId);
    } catch (cleanupErr) {
      console.warn(
        "[book-import] failed to roll back partial chunks after embed error:",
        cleanupErr,
      );
    }
    throw err;
  }

  // Sentinel: signal "chunks exist now" without re-emitting them so the
  // shared indexer's savePageDataMany branch becomes a no-op on mobile.
  return chunks.map((c, idx) => ({
    id: idx,
    pageNumber: idx,
    bookId,
    data: c.text,
  }));
}

export function createMobileEmbedPort(): EmbedPort {
  return {
    async generateChunks({ bookId, filePath, format }) {
      const key = String(bookId);
      const existing = inFlightEmbedByBookId.get(key);
      if (existing) return existing;

      const promise = runEmbedPipeline(key, filePath, format).finally(() => {
        inFlightEmbedByBookId.delete(key);
      });
      inFlightEmbedByBookId.set(key, promise);
      return promise;
    },

    async embed(_params) {
      // Not used by mobile — chunks + vectors are written together in
      // generateChunks above. Returning [] here means the shared indexer's
      // saveVectors loop is a no-op for the data we just wrote.
      return [];
    },

    async isIndexed(bookId) {
      return isBookEmbedded(String(bookId));
    },
  };
}

// ────────────────────────────────────────────────────────────────────────────
// CoverPort — EPUB + MOBI/AZW3. Extracts cover bytes, writes to disk,
// updates row. DJVU first-page raster is parked (it's the same trade-off
// as the PDF cover — needs a WebView round-trip; documented in
// .parity/BATCH-8-NOTES.md).
// ────────────────────────────────────────────────────────────────────────────

const COVERS_DIR = new Directory(Paths.document, "covers");

/**
 * Sentinel value persisted to the `coverPath` column when cover
 * extraction fails (P1-AC). `mapRowToBook` in `lib/book-storage.ts`
 * interprets this as `coverExtractionFailed = true` and normalizes the
 * exposed `coverPath` to `null`. We use a sentinel string rather than
 * adding a new schema column to avoid a migration round-trip — the
 * `coverPath` column is already nullable text, and the sentinel cannot
 * collide with a real `file://` URI. A future migration can promote
 * this to a dedicated boolean column.
 */
export const COVER_EXTRACTION_FAILED_SENTINEL = "__failed";

/**
 * DAT-010 (#122): typed reason for cover-extraction failure. The
 * persisted sentinel `__failed` (above) is opaque to callers and the
 * UI — there is no way to distinguish "we couldn't read the file" from
 * "the extractor crashed" from "the format has no cover extractor at
 * all". This discriminated union surfaces the actual reason at the
 * port boundary so adapters in `index.ts` (and any test harness) can
 * react with the right copy ("Retry", "Format not supported",
 * "Storage error") even before the schema gains a dedicated column.
 *
 * NB: the persisted DB value stays `__failed` to preserve backward
 * compatibility with `book-storage.mapRowToBook`. A future migration
 * can replace the sentinel + this `kind` with a structured column.
 */
export type CoverExtractionFailureReason =
  | { kind: "read-error"; format: BookFormat; cause: unknown }
  | { kind: "parse-error"; format: BookFormat; cause: unknown }
  | { kind: "write-error"; format: BookFormat; cause: unknown }
  | { kind: "no-cover-found"; format: BookFormat }
  | { kind: "format-unsupported"; format: BookFormat };

export interface CoverPortDeps {
  /** Injected for tests. Renamed from `readEpubBytes` in Batch 8 — the
   *  reader is now format-agnostic since MOBI/AZW3 also use it. */
  readBookBytes?: (bookPath: string) => Promise<Uint8Array>;
  /** Injected for tests. */
  writeCoverFile?: (
    bookId: string,
    mimeType: string,
    data: Uint8Array,
  ) => Promise<string>;
  /** Injected for tests. */
  updateBookCover?: (bookId: string, coverPath: string) => Promise<void>;
  /**
   * DAT-010 (#122): typed failure callback. Invoked with the structured
   * reason BEFORE the sentinel is persisted (or instead of, for the
   * non-failure-state kinds like `no-cover-found` / `format-unsupported`).
   * Best-effort — exceptions thrown by the callback are swallowed so
   * the import pipeline is never blocked by an observer.
   */
  onExtractionFailure?: (
    bookId: string,
    reason: CoverExtractionFailureReason,
  ) => void;
  /**
   * DAT-019 (#131): success callback. Invoked with the persisted
   * cover file URI AFTER `updateBookCover` returns. Lets the file-import
   * layer surface `coverState='ready'` without having to hijack the
   * row-update path. Best-effort — exceptions are swallowed.
   */
  onExtractionSuccess?: (bookId: string, coverPath: string) => void;
}

export function createMobileCoverPort(deps: CoverPortDeps = {}): CoverPort {
  const readBookBytes =
    deps.readBookBytes ??
    (async (bookPath: string): Promise<Uint8Array> => {
      const bytes = await new File(bookPath).bytes();
      return bytes;
    });

  const writeCoverFile =
    deps.writeCoverFile ??
    (async (bookId: string, mimeType: string, data: Uint8Array) => {
      if (!COVERS_DIR.exists) {
        COVERS_DIR.create({ intermediates: true });
      }
      const ext = mimeTypeToExt(mimeType);
      const file = new File(COVERS_DIR, `${bookId}.${ext}`);
      file.write(data);
      return file.uri;
    });

  const updateBookCover =
    deps.updateBookCover ??
    (async (bookId: string, coverPath: string) => {
      db.update(books)
        .set({ coverPath, updatedAt: Date.now(), isDirty: true })
        .where(eq(books.id, bookId))
        .run();
      // Same parity reason as DbPort.updateBookCover above. (H3-03)
      triggerSyncOnWrite();
    });

  // DAT-010 (#122): swallow callback errors so an upstream observer
  // can never block the import pipeline.
  const reportFailure = (
    bookId: string,
    reason: CoverExtractionFailureReason,
  ) => {
    try {
      deps.onExtractionFailure?.(bookId, reason);
    } catch {
      /* best-effort */
    }
  };

  return {
    async extractAndStore({ bookId, bookPath, format }) {
      // Format dispatch: EPUB has its own (jszip) extractor; MOBI/AZW3
      // share the PalmDOC image-record extractor. PDF/DJVU covers are
      // deferred (would need a WebView raster round-trip).
      if (format !== "epub" && format !== "mobi" && format !== "azw3") {
        // DAT-010 (#122): emit the typed reason so callers can
        // distinguish "no extractor" from "extractor failed". This is
        // NOT persisted to coverPath (book-storage's sentinel mapper
        // expects either a real path or null for these formats).
        reportFailure(String(bookId), {
          kind: "format-unsupported",
          format,
        });
        return null;
      }

      let bytes: Uint8Array;
      try {
        bytes = await readBookBytes(bookPath);
      } catch (err) {
        console.warn("[book-import] failed to read book bytes for cover:", err);
        reportFailure(String(bookId), {
          kind: "read-error",
          format,
          cause: err,
        });
        return null;
      }

      let cover: { mimeType: string; data: Uint8Array } | null = null;
      try {
        if (format === "epub") {
          cover = await extractEpubCover(bytes);
        } else {
          // MOBI + AZW3 use the same PalmDOC image extractor.
          cover = extractMobiCover(bytes);
        }
      } catch (err) {
        console.warn(`[book-import] cover extraction failed (${format}):`, err);
        reportFailure(String(bookId), {
          kind: "parse-error",
          format,
          cause: err,
        });
        // P1-AC: persist the failure sentinel so the library UI can offer
        // a "Retry cover extraction" affordance instead of silently
        // falling back to the letter-tile.
        try {
          await updateBookCover(
            String(bookId),
            COVER_EXTRACTION_FAILED_SENTINEL,
          );
        } catch {
          /* best-effort — the import itself still succeeded */
        }
        return null;
      }
      if (!cover) {
        // DAT-010 (#122): "no cover" is distinct from "extractor crashed".
        // We don't persist the sentinel here — a book legitimately may
        // have no cover, and the existing letter-tile is the right UI.
        reportFailure(String(bookId), {
          kind: "no-cover-found",
          format,
        });
        return null;
      }

      try {
        const path = await writeCoverFile(
          String(bookId),
          cover.mimeType,
          cover.data,
        );
        await updateBookCover(String(bookId), path);
        // DAT-019 (#131): notify the success channel AFTER both write
        // + DB update succeed, so observers only see a ready state
        // when both halves of the operation landed.
        try {
          deps.onExtractionSuccess?.(String(bookId), path);
        } catch {
          /* best-effort */
        }
        return path;
      } catch (err) {
        console.warn("[book-import] failed to write cover:", err);
        reportFailure(String(bookId), {
          kind: "write-error",
          format,
          cause: err,
        });
        return null;
      }
    },
  };
}

function mimeTypeToExt(mimeType: string): string {
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/gif") return "gif";
  return "jpg";
}

// ────────────────────────────────────────────────────────────────────────────
// FormatsPort — stub. Mobile derives metadata from the source URI itself, so
// the format-extraction call only needs to return a sentinel; the real
// metadata is built in `buildBookInsertable`.
// ────────────────────────────────────────────────────────────────────────────

export function createMobileFormatsPort() {
  const stub = async (path: string) => ({
    kind: path.split(".").pop()?.toLowerCase() ?? "",
    cover: [] as number[],
    title: null,
    author: null,
    publisher: null,
    coverKind: null,
  });
  return {
    getBookData: stub,
    getPdfData: stub,
    getMobiData: stub,
    getAzw3Data: stub,
  };
}
