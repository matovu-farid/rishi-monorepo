import { extOf, formatFor, UnsupportedFormatError } from "./dispatch";
import type {
  BookDataParsed,
  BookFormat,
  BookImportConfig,
  CoverPort,
  DbPort,
  FormatsPort,
  FsPort,
  ImportProgressEvent,
  ImportResult,
  UploadPort,
} from "./types";

export interface ImporterDeps<BookId, Book, BookInsertable> {
  formats: FormatsPort;
  fs: FsPort;
  db: DbPort<BookId, Book, BookInsertable>;
  upload: UploadPort<BookId>;
  cover?: CoverPort;
  config: BookImportConfig;
  buildBookInsertable(opts: {
    bookData: BookDataParsed;
    filePath: string;
    bookPath: string;
    format: BookFormat;
  }): BookInsertable;
  /** Pluck the id off a saved book row (id shape varies per platform). */
  bookIdOf(book: Book): BookId;
}

function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  label: string,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () =>
        reject(
          new Error(`${label} timed out after ${Math.round(ms / 1000)}s`),
        ),
      ms,
    );
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e: unknown) => {
        clearTimeout(timer);
        reject(e instanceof Error ? e : new Error(String(e)));
      },
    );
  });
}

function messageOf(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback;
}

/**
 * Best-effort cleanup of the per-book directory (or just the file, when the
 * platform stores books flat). See `FsPort.removeBookDir` for the contract.
 *
 * Issue #209: failures here MUST NOT replace the original parse / save error
 * — the caller has already classified the failure stage and we want the
 * original message to surface unchanged.
 */
async function rollbackCopy(
  fs: FsPort,
  bookPath: string,
): Promise<void> {
  try {
    if (fs.removeBookDir) {
      await fs.removeBookDir(bookPath);
    } else {
      await fs.removeFile(bookPath);
    }
  } catch {
    /* swallow */
  }
}

/**
 * Best-effort cover extraction + R2 upload. Failures emit upload-failed
 * but never block the result. Runs asynchronously (microtask) so `done`
 * lands first.
 */
function runPostSave<BookId, Book, BookInsertable>(
  deps: ImporterDeps<BookId, Book, BookInsertable>,
  bookId: BookId,
  bookPath: string,
  format: BookFormat,
  filePath: string,
  emit: (event: ImportProgressEvent<BookId>) => void,
): void {
  setTimeout(() => {
    emit({ kind: "upload-started", filePath, bookId });
    void runAsync();
  }, 0);

  async function runAsync(): Promise<void> {
    // Cover first (best-effort, swallowed). We do this before upload so
    // mobile's grid can render with the cover even if the book file upload
    // is still in flight.
    if (deps.cover) {
      try {
        await deps.cover.extractAndStore({
          bookId: bookId as unknown as string | number,
          bookPath,
          format,
        });
      } catch (err) {
        // Cover failure is non-fatal; log via emit for visibility.
        // Don't classify as upload-failed (that's for R2 errors only).
        console.warn("[book-import] cover extraction failed:", err);
      }
    }

    try {
      await deps.upload.hashAndUpload({ bookId, bookPath, format });
    } catch (err) {
      emit({
        kind: "upload-failed",
        filePath,
        bookId,
        error: messageOf(err, "Upload failed"),
      });
    }
  }
}

/**
 * Single-file import pipeline. Sequential stages with per-stage timeouts.
 * Returns a discriminated ImportResult. Rolls back the copied book (file +
 * per-book dir on mobile) on parse OR save failure — see #209.
 */
export async function runImport<BookId, Book, BookInsertable>(
  deps: ImporterDeps<BookId, Book, BookInsertable>,
  filePath: string,
  emit: (event: ImportProgressEvent<BookId>) => void,
): Promise<ImportResult<BookId>> {
  // Stage 1: copy.
  emit({ kind: "copying", filePath });
  let bookPath: string;
  try {
    bookPath = await withTimeout(
      deps.fs.copyBookToAppData(filePath),
      deps.config.copyTimeoutMs,
      "Copying file",
    );
  } catch (err) {
    const error = messageOf(err, "Copy failed");
    emit({ kind: "failed", filePath, stage: "copy", error });
    return { ok: false, filePath, stage: "copy", error };
  }

  // Stage 2a: resolve format BEFORE emitting parsing.
  const extension = extOf(filePath);
  const resolvedFormat = formatFor(extension);
  if (resolvedFormat === null) {
    const err = new UnsupportedFormatError(extension);
    emit({ kind: "failed", filePath, stage: "unsupported", error: err.message });
    return {
      ok: false,
      filePath,
      stage: "unsupported",
      error: err.message,
    };
  }
  const format: BookFormat = resolvedFormat;

  // Stage 2b: parse.
  emit({ kind: "parsing", filePath, format });
  let bookData: BookDataParsed;
  try {
    const parsePromise: Promise<BookDataParsed> =
      format === "epub"
        ? deps.formats.getBookData(filePath)
        : format === "pdf"
          ? deps.formats.getPdfData(filePath)
          : format === "azw3"
            ? deps.formats.getAzw3Data(filePath)
            : format === "mobi"
              ? deps.formats.getMobiData(filePath)
              : // djvu: route through getBookData (degraded metadata).
                deps.formats.getBookData(filePath);
    bookData = await withTimeout(
      parsePromise,
      deps.config.parseTimeoutMs,
      "Extracting metadata",
    );
  } catch (err) {
    const error = messageOf(err, "Parse failed");
    emit({ kind: "failed", filePath, stage: "parse", error });
    // #209: clean up the orphan per-book dir on mobile (or just the copied
    // file on electron). Best-effort — failures here do not replace the
    // parse error.
    await rollbackCopy(deps.fs, bookPath);
    return { ok: false, filePath, stage: "parse", error };
  }

  // Stage 3: save.
  emit({ kind: "saving", filePath, format });
  let book: Book;
  try {
    book = await withTimeout(
      deps.db.saveBook(
        deps.buildBookInsertable({ bookData, filePath, bookPath, format }),
      ),
      deps.config.saveTimeoutMs,
      "Saving to library",
    );
  } catch (err) {
    const error = messageOf(err, "Save failed");
    emit({ kind: "failed", filePath, stage: "save", error });
    // #209: mirror the parse-fail cleanup — the DB insert never persisted a
    // row, so leaving the copied file (and on mobile, the per-book dir)
    // around is a pure leak. Best-effort.
    await rollbackCopy(deps.fs, bookPath);
    return { ok: false, filePath, stage: "save", error };
  }

  const bookId = deps.bookIdOf(book);
  emit({ kind: "done", filePath, bookId, format });

  // Stage 4: fire-and-forget cover + upload.
  runPostSave(deps, bookId, bookPath, format, filePath, emit);

  return { ok: true, bookId, filePath, format };
}
