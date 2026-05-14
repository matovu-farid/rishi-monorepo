import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FormatsIpc,
  FsIpc,
  ImportProgressEvent,
  ImportResult
} from './types'
import { extOf, formatFor, UnsupportedFormatError } from './dispatch'
import type { BookDataParsed, BookFormat } from './types'

export interface ImporterDeps {
  formats: FormatsIpc
  fs: FsIpc
  db: BookStoreIpc
  fileSync: FileSyncIpc
  config: BookImportConfig
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${Math.round(ms / 1000)}s`)),
      ms
    )
    promise.then(
      (v) => {
        clearTimeout(timer)
        resolve(v)
      },
      (e: unknown) => {
        clearTimeout(timer)
        reject(e instanceof Error ? e : new Error(String(e)))
      }
    )
  })
}

function messageOf(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/**
 * Best-effort hash + R2 upload. Failure does not affect the import result;
 * it only emits an `upload-failed` event. Runs asynchronously (microtask), so
 * `done` lands in the event stream before `upload-started`.
 */
function runUpload(
  deps: ImporterDeps,
  bookId: number,
  bookPath: string,
  format: 'epub' | 'pdf' | 'mobi' | 'azw3',
  filePath: string,
  emit: (event: ImportProgressEvent) => void
): void {
  const formatForUpload: 'epub' | 'pdf' | 'mobi' = format === 'azw3' ? 'mobi' : format
  setTimeout(() => {
    emit({ kind: 'upload-started', filePath, bookId })
    void uploadInner()
  }, 0)

  async function uploadInner(): Promise<void> {
    try {
      const fileHash = await deps.fileSync.hashBookFile(bookPath)
      const { r2Key } = await deps.fileSync.uploadBookFile(bookPath, fileHash, formatForUpload)
      await deps.fileSync.booksUpdateFileHash(bookId, fileHash, r2Key)
    } catch (err) {
      emit({
        kind: 'upload-failed',
        filePath,
        bookId,
        error: messageOf(err, 'Upload failed')
      })
    }
  }
}

/**
 * Single-file import pipeline. Sequential stages with per-stage timeouts.
 * Returns a discriminated ImportResult. Rolls back the copy on parse failure;
 * leaves the copied file on save failure (caller can retry).
 */
export async function runImport(
  deps: ImporterDeps,
  filePath: string,
  emit: (event: ImportProgressEvent) => void
): Promise<ImportResult> {
  // Stage 1: copy.
  emit({ kind: 'copying', filePath })
  let bookPath: string
  try {
    bookPath = await withTimeout(
      deps.fs.copyBookToAppData(filePath),
      deps.config.copyTimeoutMs,
      'Copying file'
    )
  } catch (err) {
    const error = messageOf(err, 'Copy failed')
    emit({ kind: 'failed', filePath, stage: 'copy', error })
    return { ok: false, filePath, stage: 'copy', error }
  }

  // Stage 2a: resolve format (extension check) — short-circuit unsupported
  // BEFORE emitting `parsing`.
  const extension = extOf(filePath)
  const resolvedFormat = formatFor(extension)
  if (resolvedFormat === null) {
    const err = new UnsupportedFormatError(extension)
    emit({ kind: 'failed', filePath, stage: 'unsupported', error: err.message })
    return { ok: false, filePath, stage: 'unsupported', error: err.message }
  }
  const format: BookFormat = resolvedFormat

  // Stage 2b: parse via the right formats IPC.
  emit({ kind: 'parsing', filePath, format })
  let bookData: BookDataParsed
  try {
    const parsePromise: Promise<BookDataParsed> =
      format === 'epub'
        ? deps.formats.getBookData(filePath)
        : format === 'pdf'
          ? deps.formats.getPdfData(filePath)
          : format === 'azw3'
            ? deps.formats.getAzw3Data(filePath)
            : deps.formats.getMobiData(filePath)
    bookData = await withTimeout(parsePromise, deps.config.parseTimeoutMs, 'Extracting metadata')
  } catch (err) {
    const error = messageOf(err, 'Parse failed')
    emit({ kind: 'failed', filePath, stage: 'parse', error })
    // Rollback the copied file (best-effort).
    try {
      await deps.fs.removeFile(bookPath)
    } catch {
      /* swallow */
    }
    return { ok: false, filePath, stage: 'parse', error }
  }

  // Stage 3: save.
  emit({ kind: 'saving', filePath, format })
  let book
  try {
    book = await withTimeout(
      deps.db.saveBook({
        coverKind: bookData.coverKind ?? '',
        title: bookData.title ?? '',
        author: bookData.author ?? '',
        publisher: bookData.publisher ?? '',
        filepath: bookPath,
        location: format === 'mobi' || format === 'azw3' ? '0' : '1',
        version: 0,
        kind: bookData.kind,
        cover: bookData.cover
      }),
      deps.config.saveTimeoutMs,
      'Saving to library'
    )
  } catch (err) {
    const error = messageOf(err, 'Save failed')
    emit({ kind: 'failed', filePath, stage: 'save', error })
    return { ok: false, filePath, stage: 'save', error }
  }

  // Done event fires synchronously; upload starts after.
  emit({ kind: 'done', filePath, bookId: book.id, format })

  // Stage 4: fire-and-forget upload.
  runUpload(deps, book.id, bookPath, format, filePath, emit)

  return { ok: true, bookId: book.id, filePath, format }
}
