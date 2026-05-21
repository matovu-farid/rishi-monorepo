import { createEmitter } from "./emitter";
import { runImport, type ImporterDeps } from "./importer";
import { indexBook as runIndex } from "./indexer";
import type {
  BookFormat,
  BookImportService,
  BookImportServiceDeps,
  ImportProgressEvent,
  ImportResult,
  PageDataInsertable,
} from "./types";

/**
 * Builds the runtime service. Caller-provided ports do all the platform
 * I/O; this layer only owns:
 *
 *  - event fan-out (emitter)
 *  - sequential `importBatch` loop with isolated failures
 *  - in-flight tracking for `isIndexing(bookId)`
 *  - delegation to `runImport` + `indexBook`
 */
export function createBookImportService<BookId, Book, BookInsertable>(
  deps: BookImportServiceDeps<BookId, Book, BookInsertable> & {
    /** Pluck the id off a saved book row (id shape varies per platform). */
    bookIdOf: (book: Book) => BookId;
  },
): BookImportService<BookId> {
  const progress = createEmitter<ImportProgressEvent<BookId>>();

  const importerDeps: ImporterDeps<BookId, Book, BookInsertable> = {
    formats: deps.formats,
    fs: deps.fs,
    db: deps.db,
    upload: deps.upload,
    cover: deps.cover,
    config: deps.config,
    buildBookInsertable: deps.buildBookInsertable,
    bookIdOf: deps.bookIdOf,
  };

  async function importFromPath(
    filePath: string,
  ): Promise<ImportResult<BookId>> {
    return runImport<BookId, Book, BookInsertable>(
      importerDeps,
      filePath,
      (e) => progress.emit(e),
    );
  }

  async function importBatch(
    filePaths: string[],
  ): Promise<ImportResult<BookId>[]> {
    const results: ImportResult<BookId>[] = [];
    for (const fp of filePaths) {
      // eslint-disable-next-line no-await-in-loop -- backpressure
      results.push(await importFromPath(fp));
    }
    return results;
  }

  const indexingBookIds = new Set<string>();
  const idKey = (id: BookId): string => String(id);

  async function indexBook(
    bookId: BookId,
    pageData?: PageDataInsertable<BookId>[],
    filePath?: string,
    format?: BookFormat,
  ): Promise<void> {
    indexingBookIds.add(idKey(bookId));
    try {
      await runIndex<BookId, Book, BookInsertable>(
        {
          db: deps.db,
          embed: deps.embed,
          embedBatchSize: deps.config.embedBatchSize,
        },
        bookId,
        pageData,
        (e) => progress.emit(e),
        filePath,
        format,
      );
    } finally {
      indexingBookIds.delete(idKey(bookId));
    }
  }

  function isIndexing(bookId: BookId): boolean {
    return indexingBookIds.has(idKey(bookId));
  }

  return {
    importFromPath,
    importBatch,
    indexBook,
    isIndexing,
    onImportProgress: (listener) => progress.on(listener),
  };
}
