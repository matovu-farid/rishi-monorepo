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
import { hashBookFile, uploadBookFile } from "@/lib/sync/file-sync";
import { getChunks } from "@/lib/rag/chunker";
import { embedBatch, isEmbeddingReady } from "@/lib/rag/embedder";
import { embedTextsOnServer } from "@/lib/rag/server-fallback";
import { insertChunkWithVector, isBookEmbedded } from "@/lib/rag/vector-store";

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
      sourceFile.copy(destFile);
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
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run();
      const { r2Key } = await uploadBookFile(bookPath, fileHash, r2Format);
      db.update(books)
        .set({ fileR2Key: r2Key, isDirty: true })
        .where(eq(books.id, bookId))
        .run();
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
export function createMobileEmbedPort(): EmbedPort {
  return {
    async generateChunks({ bookId, filePath, format }) {
      if (isBookEmbedded(String(bookId))) return [];

      const chunks = await getChunks(filePath, format, String(bookId));
      if (chunks.length === 0) return [];

      const BATCH_SIZE = 10;
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
            String(bookId),
            chunk.chunkIndex,
            chunk.text,
            chunk.chapter,
            embeddings[j],
          );
        }
      }

      // Sentinel: signal "chunks exist now" without re-emitting them so the
      // shared indexer's savePageDataMany branch becomes a no-op on mobile.
      return chunks.map((c, idx) => ({
        id: idx,
        pageNumber: idx,
        bookId: String(bookId),
        data: c.text,
      }));
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
    });

  return {
    async extractAndStore({ bookId, bookPath, format }) {
      // Format dispatch: EPUB has its own (jszip) extractor; MOBI/AZW3
      // share the PalmDOC image-record extractor. PDF/DJVU covers are
      // deferred (would need a WebView raster round-trip).
      if (format !== "epub" && format !== "mobi" && format !== "azw3") {
        return null;
      }

      let bytes: Uint8Array;
      try {
        bytes = await readBookBytes(bookPath);
      } catch (err) {
        console.warn("[book-import] failed to read book bytes for cover:", err);
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
        return null;
      }
      if (!cover) return null;

      try {
        const path = await writeCoverFile(
          String(bookId),
          cover.mimeType,
          cover.data,
        );
        await updateBookCover(String(bookId), path);
        return path;
      } catch (err) {
        console.warn("[book-import] failed to write cover:", err);
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
