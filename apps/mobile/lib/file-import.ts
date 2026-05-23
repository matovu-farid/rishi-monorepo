/**
 * Mobile file-import — orchestrates EPUB / PDF / MOBI / AZW3 / DJVU
 * imports + URL imports.
 *
 * Architecture: each import wrapper picks (or downloads) the source file,
 * mints a UUID, then runs the shared `@rishi/shared/book-import` service
 * through mobile-specific port adapters. The service handles copy + save
 * + done-event; cover extraction + R2 upload run after `done` as
 * fire-and-forget side-effects.
 */

import { File, Directory, Paths } from "expo-file-system";
import { and, eq } from "drizzle-orm";
import { Book } from "@/types/book";
import { createMobileBookImportService } from "@/lib/book-import";
// Type-only import so file-import.ts does NOT pull adapters.ts's runtime
// graph (jszip, mobi extractor, vector-store) into modules that mock
// only the file-import surface.
import type { CoverExtractionFailureReason } from "@/lib/book-import/adapters";
import { embedBook } from "@/lib/rag/pipeline";
import type { BookFormat } from "@rishi/shared/book-import";
import { IS_E2E_TEST } from "@/app/_layout";
import { getSessionToken } from "@/lib/auth";
import { shouldSkipIndexing } from "@/lib/file-import-index-gate";
import { db } from "@/lib/db";
import { books } from "@rishi/shared/schema";
import { hashBookFile } from "@/lib/sync/file-sync";

const BOOKS_DIR = new Directory(Paths.document, "books");

/**
 * Mobile import-outcome taxonomy (P0-K).
 *
 * The shared service returns `{ok:false, stage: 'unsupported' | 'copy' |
 * 'parse' | 'save' | 'unknown'}`. The mobile wrappers layer additional
 * UX stages on top (`picker-cancel`, `storage-full`, `permission`,
 * `network`, `duplicate`) so the library screen can surface
 * stage-specific copy via Alert.alert.
 *
 * Stages:
 *   - 'picker-cancel'   user dismissed the document picker (no alert)
 *   - 'parse'           shared service couldn't parse the file
 *   - 'storage-full'    write failed with ENOSPC
 *   - 'permission'      filesystem refused access (EACCES / EPERM)
 *   - 'network'         URL import couldn't fetch the file
 *   - 'duplicate'       a book with this id / path already exists
 *   - 'unsupported'     shared service rejected the format
 *   - 'copy' | 'save'   shared service stages
 *   - 'unknown'         anything we couldn't classify
 */
export type ImportFailureStage =
  | "picker-cancel"
  | "parse"
  | "storage-full"
  | "permission"
  | "network"
  | "duplicate"
  | "unsupported"
  | "copy"
  | "save"
  | "unknown";

/**
 * DAT-019 (#131): explicit cover-extraction completion state surfaced
 * to callers. The shared `book-import` service kicks off cover
 * extraction via `setTimeout(…, 0)` after the `done` event, so when
 * `runImportWithService` resolves the cover state is still pending —
 * the library UI used to render a stale letter-tile with no signal
 * whether the cover would arrive, never arrive, or was simply
 * unsupported for the format. `coverPromise` resolves with the
 * eventual state and `coverState` is the initial `'pending'` until
 * then. Callers that don't care can ignore both fields.
 */
export type CoverState =
  | { status: "pending" }
  | { status: "ready"; coverPath: string }
  | { status: "unavailable"; reason: CoverExtractionFailureReason }
  | { status: "unsupported"; format: BookFormat };

export interface ImportSuccess {
  ok: true;
  book: Book;
  /**
   * Resolves to the final cover state once the shared importer's
   * fire-and-forget post-save pipeline finishes. May resolve to
   * `unavailable` (extractor failed; sentinel persisted) or
   * `unsupported` (PDF / DJVU have no extractor). Never rejects.
   */
  coverPromise: Promise<CoverState>;
}

export type ImportOutcome =
  | ImportSuccess
  | { ok: false; stage: ImportFailureStage; error: string };

/**
 * Classifies a shared-service failure stage + raw error string into one
 * of our mobile-facing stages. The shared service only knows about
 * filesystem mechanics; the picker-cancel / storage-full / permission
 * stages are detected here from the error message.
 */
function classifyFailure(
  sharedStage: "unsupported" | "copy" | "parse" | "save" | "unknown",
  error: string,
): ImportFailureStage {
  const msg = error.toLowerCase();
  if (msg.includes("enospc") || msg.includes("no space") || msg.includes("disk full")) {
    return "storage-full";
  }
  if (
    msg.includes("eacces") ||
    msg.includes("eperm") ||
    msg.includes("permission")
  ) {
    return "permission";
  }
  return sharedStage;
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

/**
 * DAT-019 (#131): tiny deferred primitive. Reach for this instead of
 * pulling in a Promise/utility package — we need exactly one
 * "produce-promise-now, settle-later" handoff (the cover lifecycle).
 */
function createDeferred<T>(): {
  promise: Promise<T>;
  resolve: (v: T) => void;
} {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  let settled = false;
  return {
    promise,
    resolve: (v: T) => {
      if (settled) return;
      settled = true;
      resolve(v);
    },
  };
}

/**
 * DAT-013 (#125): module-level counter folded into the fallback UUID
 * generator so two rapid calls cannot collide even if Math.random()
 * returns the same value back-to-back (observed on some cold-started
 * RN runtimes). The host's `crypto.randomUUID` is already collision-safe
 * and is preferred when available.
 */
let fallbackUuidCounter = 0;

function generateUUID(): string {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  // Increment first so two simultaneous calls observe distinct values
  // even before the template string is built.
  fallbackUuidCounter = (fallbackUuidCounter + 1) & 0xffffffff;
  const counter = fallbackUuidCounter;
  // Mix the counter nibble-by-nibble into the template positions. We
  // walk a 32-bit counter across 8 nibbles (xxxxxxxx prefix), then fall
  // through to Math.random() for the rest so the output is still
  // RFC-4122-ish (version 4, variant 1).
  let counterNibblesConsumed = 0;
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    let r: number;
    if (c === "x" && counterNibblesConsumed < 8) {
      // Pull the next nibble from the counter, MSB first.
      const shift = (7 - counterNibblesConsumed) * 4;
      r = (counter >>> shift) & 0xf;
      counterNibblesConsumed += 1;
    } else {
      r = (Math.random() * 16) | 0;
    }
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function titleFromUri(uri: string, extensionRegex: RegExp): string {
  const parts = uri.split("/");
  const rawName = decodeURIComponent(parts[parts.length - 1] || "Unknown Book");
  return rawName.replace(extensionRegex, "");
}

function ensureBooksDir(): void {
  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true });
  }
}

/**
 * DAT-002 (#115): duplicate-by-content guard. Every import path (picker
 * + URL + share sheet) used to mint a brand-new UUID and insert a fresh
 * row even when the user re-imported the same file, leaving the library
 * with two rows pointing at byte-identical content.
 *
 * Hash the source bytes BEFORE creating the per-book directory or
 * inserting the row. If a non-deleted books row already carries that
 * hash, short-circuit to `stage: 'duplicate'`. Hash collisions across
 * different files are vanishingly unlikely (SHA-256), so a positive hit
 * is treated as a confirmed duplicate.
 *
 * Returns the matching book id on hit; null otherwise.
 *
 * Exported so the share-sheet handler (`lib/file-handler.ts`) can reuse
 * the same gate; #115 originally wired only the picker + URL paths.
 */
export async function findDuplicateByHash(
  sourceUri: string,
): Promise<{ existingBookId: string; fileHash: string } | null> {
  let fileHash: string;
  try {
    fileHash = await hashBookFile(sourceUri);
  } catch {
    // Hashing failure must NOT block the import — if the bytes can't be
    // read here, the shared service's copy step will fail anyway with a
    // more accurate stage. Skip the duplicate check and let it through.
    return null;
  }
  if (!fileHash) return null;

  try {
    // Soft-deleted rows must NOT block re-imports. Without the
    // `isDeleted = false` predicate, deleting a book and trying to
    // re-import the same file fails permanently as a duplicate with no
    // recovery short of manual SQL. See PR #207 review.
    const existing = db
      .select()
      .from(books)
      .where(and(eq(books.fileHash, fileHash), eq(books.isDeleted, false)))
      .get();
    if (existing && existing.id) {
      return { existingBookId: String(existing.id), fileHash };
    }
  } catch {
    // Best-effort. A DB error here is non-fatal; the worst case is a
    // duplicate row slips through, which the user can delete manually.
  }
  return null;
}

/**
 * Shared importer driver: pick (or accept) a source URI, mint a UUID, run
 * the shared service, then trigger indexing in the background.
 */
async function runImportWithService(opts: {
  sourceUri: string;
  format: BookFormat;
  title: string;
  author?: string;
}): Promise<ImportOutcome> {
  ensureBooksDir();

  // DAT-002 (#115): duplicate-by-content gate. Runs BEFORE we mint a
  // UUID or touch the filesystem so a duplicate import is a clean no-op
  // (no orphan dir, no Drizzle row attempt).
  const dup = await findDuplicateByHash(opts.sourceUri);
  if (dup) {
    return {
      ok: false,
      stage: "duplicate",
      error: `This book is already in your library (id=${dup.existingBookId}).`,
    };
  }

  const bookId = generateUUID();

  // DAT-019 (#131): track cover-extraction lifecycle so callers can
  // distinguish pending / ready / unavailable / unsupported instead of
  // treating every cover-less book identically. We use a deferred
  // because the shared importer kicks off cover extraction via
  // setTimeout AFTER `importFromPath` resolves; the resolver fires from
  // either `coverPortDeps.updateBookCover` (success or sentinel) or
  // `coverPortDeps.onExtractionFailure` (typed reason), whichever
  // happens first.
  const coverDeferred = createDeferred<CoverState>();
  // Format-level short-circuit: PDF + DJVU have no extractor at all,
  // so the cover port emits `format-unsupported` synchronously. Pin
  // the initial expected status here so the test surface stays stable
  // even if the cover port's call ordering changes.
  const unsupportedFormat =
    opts.format !== "epub" &&
    opts.format !== "mobi" &&
    opts.format !== "azw3";

  const service = createMobileBookImportService({
    bookId,
    format: opts.format,
    title: opts.title,
    author: opts.author,
    coverPortDeps: {
      onExtractionFailure: (id, reason) => {
        if (String(id) !== bookId) return;
        if (reason.kind === "format-unsupported") {
          coverDeferred.resolve({
            status: "unsupported",
            format: reason.format,
          });
        } else {
          // 'no-cover-found' and the genuine failure kinds all surface
          // as 'unavailable' so the UI doesn't have to know which
          // discriminator is which to render the letter-tile. The
          // reason itself is carried through so a future "retry"
          // affordance can branch on it.
          coverDeferred.resolve({ status: "unavailable", reason });
        }
      },
      onExtractionSuccess: (id, coverPath) => {
        if (String(id) !== bookId) return;
        coverDeferred.resolve({ status: "ready", coverPath });
      },
    },
  });

  const result = await service.importFromPath(opts.sourceUri);
  if (!result.ok) {
    console.warn(
      `[file-import] ${opts.format} import failed at stage=${result.stage}: ${result.error}`,
    );
    return {
      ok: false,
      stage: classifyFailure(result.stage, result.error ?? ""),
      error: result.error ?? "",
    };
  }

  const bookPath = `${BOOKS_DIR.uri}/${bookId}/book.${opts.format}`;

  // Indexing runs after the row exists. The shared indexer falls through
  // to embed.generateChunks (mobile path) when neither caller nor DB has
  // chunks. We pass (filePath, format) so the indexer takes that branch.
  //
  // Indexing is fire-and-forget — same semantics as upload. A failure
  // leaves the row in place; the next time the book is opened, the
  // embedder may retry (vector-store.isBookEmbedded gates the work).
  void (async () => {
    const sessionToken = await getSessionToken().catch(() => null);
    if (shouldSkipIndexing({ isE2E: IS_E2E_TEST, sessionToken })) {
      console.info(
        `[file-import] skipping indexBook for ${bookId} (isE2E=${IS_E2E_TEST}, hasToken=${!!sessionToken})`,
      );
      return;
    }
    try {
      await service.indexBook(bookId, undefined, bookPath, opts.format);
    } catch (err) {
      console.warn("[file-import] indexBook failed:", err);
    }
  })();

  // DAT-019 (#131): if the format has no extractor and the shared
  // importer never wires the cover port (because it short-circuits on
  // formats without a known kind), make sure the deferred still
  // resolves — otherwise callers awaiting `coverPromise` would hang
  // forever. The cover port itself emits `format-unsupported`
  // synchronously for these formats, so this is a defensive fallback.
  if (unsupportedFormat) {
    coverDeferred.resolve({ status: "unsupported", format: opts.format });
  }

  // Local Book shape — derive from what the service inserted.
  return {
    ok: true,
    book: {
      id: bookId,
      title: opts.title,
      author: opts.author ?? "Unknown",
      coverPath: null, // CoverPort will patch this on the row asynchronously.
      filePath: bookPath,
      format: opts.format,
      currentCfi: null,
      currentPage: opts.format === "pdf" ? 1 : null,
      createdAt: Date.now(),
    },
    coverPromise: coverDeferred.promise,
  };
}

// ────────────────────────────────────────────────────────────────────────────
// Picker-driven imports
// ────────────────────────────────────────────────────────────────────────────

const PICKER_CANCEL: ImportOutcome = {
  ok: false,
  stage: "picker-cancel",
  error: "User cancelled the document picker",
};

export async function importEpubFile(): Promise<ImportOutcome> {
  const pickedFile = await File.pickFileAsync(undefined, "application/epub+zip");
  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return PICKER_CANCEL;
  }
  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile;
  return runImportWithService({
    sourceUri: sourceFile.uri,
    format: "epub",
    title: titleFromUri(sourceFile.uri, /\.epub$/i),
  });
}

export async function importPdfFile(): Promise<ImportOutcome> {
  const pickedFile = await File.pickFileAsync(undefined, "application/pdf");
  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return PICKER_CANCEL;
  }
  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile;
  return runImportWithService({
    sourceUri: sourceFile.uri,
    format: "pdf",
    title: titleFromUri(sourceFile.uri, /\.pdf$/i),
  });
}

export async function importMobiFile(): Promise<ImportOutcome> {
  const pickedFile = await File.pickFileAsync(
    undefined,
    "application/x-mobipocket-ebook",
  );
  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return PICKER_CANCEL;
  }
  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile;
  const isAzw3 = sourceFile.uri.toLowerCase().endsWith(".azw3");
  const format: BookFormat = isAzw3 ? "azw3" : "mobi";
  return runImportWithService({
    sourceUri: sourceFile.uri,
    format,
    title: titleFromUri(sourceFile.uri, /\.(mobi|azw3)$/i),
  });
}

export async function importDjvuFile(): Promise<ImportOutcome> {
  const pickedFile = await File.pickFileAsync(undefined, "image/vnd.djvu");
  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return PICKER_CANCEL;
  }
  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile;
  return runImportWithService({
    sourceUri: sourceFile.uri,
    format: "djvu",
    title: titleFromUri(sourceFile.uri, /\.djvu$/i),
  });
}

// ────────────────────────────────────────────────────────────────────────────
// URL-driven import
//
// We can't drive this through the shared service's FsPort because the source
// arrives as bytes (HTTP body), not a file path. The URL import path:
//   1. download to a temp file inside the per-book dir
//   2. point the shared service at it (so we still get cover + upload +
//      indexing)
// ────────────────────────────────────────────────────────────────────────────

type UrlFormat = "epub" | "pdf" | "mobi" | "djvu";

function detectFormatFromUrl(url: string): UrlFormat | null {
  const pathname = new URL(url).pathname.toLowerCase();
  if (pathname.endsWith(".epub")) return "epub";
  if (pathname.endsWith(".pdf")) return "pdf";
  if (pathname.endsWith(".mobi") || pathname.endsWith(".azw3")) return "mobi";
  if (pathname.endsWith(".djvu")) return "djvu";
  return null;
}

function detectFormatFromContentType(
  contentType: string | null,
): UrlFormat | null {
  if (!contentType) return null;
  if (contentType.includes("application/epub+zip")) return "epub";
  if (contentType.includes("application/pdf")) return "pdf";
  if (contentType.includes("application/x-mobipocket-ebook")) return "mobi";
  if (contentType.includes("image/vnd.djvu")) return "djvu";
  return null;
}

function extractTitleFromUrl(url: string): string {
  const pathname = new URL(url).pathname;
  const filename = decodeURIComponent(
    pathname.split("/").pop() || "Unknown Book",
  );
  return filename.replace(/\.(epub|pdf|mobi|azw3|djvu)$/i, "");
}

/**
 * Map a non-2xx HTTP status from the download GET to user-facing copy
 * (P1-AD). Previously we surfaced raw `Download failed: {status} {statusText}`
 * to the UI; users could not tell whether the file was missing, gated, or
 * the server was down. The mapping:
 *   - 404         → "We couldn't find that file"
 *   - 401 / 403   → "URL requires permission"
 *   - other       → "Server refused download"
 */
export function mapHttpStatusToUserCopy(status: number): string {
  if (status === 404) {
    return "We couldn't find that file";
  }
  if (status === 401 || status === 403) {
    return "URL requires permission";
  }
  return "Server refused download";
}

/**
 * DAT-012 (#124): hard cap on URL-import size. Reading a 2 GB body
 * straight into `arrayBuffer()` OOMs the JS VM on Android (heap cap is
 * ~512 MB on most devices). 500 MB is comfortably below the cap and
 * still leaves headroom for the existing book covers + chunker
 * allocations.
 *
 * Exported for tests; not part of the public API surface.
 */
export const URL_IMPORT_MAX_BYTES = 500 * 1024 * 1024;

function parseContentLengthOrNull(header: string | null): number | null {
  if (!header) return null;
  // `Number()` is too lenient ("" → 0, " 12 " → 12). We want a strict
  // base-10 integer; anything else is treated as "unknown size".
  if (!/^\d+$/.test(header.trim())) return null;
  const n = Number(header.trim());
  return Number.isFinite(n) && n >= 0 ? n : null;
}

function formatBytesAsMB(bytes: number): string {
  return `${Math.round(bytes / (1024 * 1024))} MB`;
}

/**
 * DAT-017 (#129): caller-controllable cancellation. `UrlImportSheet`
 * holds an `AbortController` for the lifetime of the sheet and aborts
 * it on dismiss so a large download stops buffering immediately
 * instead of stranded in the background. The signal is forwarded to
 * both the HEAD probe and the GET; an aborted signal short-circuits
 * with a standard `AbortError` from `fetch`.
 */
export interface ImportBookFromUrlOptions {
  signal?: AbortSignal;
}

export async function importBookFromUrl(
  url: string,
  options: ImportBookFromUrlOptions = {},
): Promise<Book> {
  if (!url.startsWith("http://") && !url.startsWith("https://")) {
    throw new Error("Invalid URL — must start with http:// or https://");
  }

  const { signal } = options;

  let format = detectFormatFromUrl(url);
  // DAT-012 (#124): track the advertised size from whichever response
  // first reveals it (HEAD or the GET body). A `content-length` over
  // the cap aborts the import BEFORE we materialise the body.
  let advertisedSize: number | null = null;

  if (!format) {
    try {
      const headRes = await fetch(url, { method: "HEAD", signal });
      format = detectFormatFromContentType(headRes.headers.get("content-type"));
      const headSize = parseContentLengthOrNull(
        headRes.headers.get("content-length"),
      );
      if (headSize != null) {
        if (headSize > URL_IMPORT_MAX_BYTES) {
          throw new Error(
            `File is too large to download (${formatBytesAsMB(headSize)}). Size limit is ${formatBytesAsMB(URL_IMPORT_MAX_BYTES)}.`,
          );
        }
        advertisedSize = headSize;
      }
    } catch (err) {
      // Re-throw size-limit rejections AND abort errors; swallow only
      // the network / DNS / CORS failures we expected to be tolerant
      // of here. AbortError must propagate so the caller can switch
      // its UI back to idle.
      if (
        err instanceof Error &&
        (err.name === "AbortError" || /too large/i.test(err.message))
      ) {
        throw err;
      }
      // HEAD failed, will try download anyway and check content-type there
    }
  }

  const downloadRes = await fetch(url, signal ? { signal } : undefined);

  if (!downloadRes.ok) {
    throw new Error(mapHttpStatusToUserCopy(downloadRes.status));
  }

  // DAT-012 (#124): re-check size from the GET response itself; servers
  // sometimes omit Content-Length on HEAD but include it on GET.
  if (advertisedSize == null) {
    const getSize = parseContentLengthOrNull(
      downloadRes.headers.get("content-length"),
    );
    if (getSize != null && getSize > URL_IMPORT_MAX_BYTES) {
      throw new Error(
        `File is too large to download (${formatBytesAsMB(getSize)}). Size limit is ${formatBytesAsMB(URL_IMPORT_MAX_BYTES)}.`,
      );
    }
  }

  if (!format) {
    format = detectFormatFromContentType(downloadRes.headers.get("content-type"));
  }

  if (!format) {
    throw new Error(
      "Unsupported format — only EPUB, PDF, MOBI, and DJVU are supported",
    );
  }

  const arrayBuffer = await downloadRes.arrayBuffer();
  const bytes = new Uint8Array(arrayBuffer);

  ensureBooksDir();
  // Stash the downloaded bytes in a tmp file inside the book dir so the
  // shared service's FsPort can copy from a real URI.
  const bookId = generateUUID();
  const bookDir = new Directory(BOOKS_DIR, bookId);
  bookDir.create({ intermediates: true, idempotent: true });
  const tmpFile = new File(bookDir, `tmp.${format}`);
  tmpFile.write(bytes);

  const title = extractTitleFromUrl(url);
  let result: ImportOutcome;
  try {
    result = await runImportWithService({
      sourceUri: tmpFile.uri,
      format,
      title,
    });
  } catch (err) {
    // DAT-011 (#123): unexpected throws from the shared service must
    // not leave the tmp dir orphaned on disk.
    safeDeleteDirectory(bookDir);
    throw err;
  }

  // Clean up the tmp file; the service copied it to book.<format>.
  try {
    tmpFile.delete();
  } catch {
    /* best-effort */
  }

  if (!result.ok) {
    // DAT-011 (#123) + DAT-002 (#115): on any failure (including
    // duplicate detection), remove the per-book dir we just created so
    // we don't leave an empty `books/<uuid>/` behind. The shared
    // service's own copy step already drops `book.<format>` on success;
    // we only need to clean up when nothing was committed.
    safeDeleteDirectory(bookDir);
    throw new Error(`Import failed at stage=${result.stage}: ${result.error}`);
  }
  return result.book;
}

/**
 * DAT-011 (#123): best-effort recursive delete of an import-time
 * scratch directory. Swallows errors because callers are always in an
 * error-handling branch — surfacing a cleanup failure on top of the
 * original error would only make the user-visible message noisier.
 */
function safeDeleteDirectory(dir: Directory): void {
  try {
    if (dir.exists) {
      dir.delete();
    }
  } catch {
    /* best-effort */
  }
}

// Re-export for callers that still rely on the legacy embedding helper.
export { embedBook };

/**
 * E2E-only entry point: import a book directly from a known file URI,
 * skipping the document picker. The caller controls the book id so the
 * seed function can be idempotent across test runs.
 *
 * Behaviour matches the picker-driven imports: copy + parse + save row +
 * fire-and-forget indexing. Returns the resulting Book or null if the
 * import service rejects the file.
 */
export async function importBookFromFile(opts: {
  sourceUri: string;
  format: BookFormat;
  title: string;
  bookId: string;
  author?: string;
}): Promise<Book | null> {
  ensureBooksDir();

  const service = createMobileBookImportService({
    bookId: opts.bookId,
    format: opts.format,
    title: opts.title,
    author: opts.author,
  });

  const result = await service.importFromPath(opts.sourceUri);
  if (!result.ok) {
    console.warn(
      `[file-import] e2e ${opts.format} import failed at stage=${result.stage}: ${result.error}`,
    );
    return null;
  }

  const bookPath = `${BOOKS_DIR.uri}/${opts.bookId}/book.${opts.format}`;

  // RAG indexing is fire-and-forget — reader E2E tests don't need
  // embeddings to complete before opening the book.
  void (async () => {
    const sessionToken = await getSessionToken().catch(() => null);
    if (shouldSkipIndexing({ isE2E: IS_E2E_TEST, sessionToken })) {
      console.info(
        `[file-import] skipping indexBook for ${opts.bookId} (isE2E=${IS_E2E_TEST}, hasToken=${!!sessionToken})`,
      );
      return;
    }
    try {
      await service.indexBook(opts.bookId, undefined, bookPath, opts.format);
    } catch (err) {
      console.warn("[file-import] e2e indexBook failed:", err);
    }
  })();

  return {
    id: opts.bookId,
    title: opts.title,
    author: opts.author ?? "Unknown",
    coverPath: null,
    filePath: bookPath,
    format: opts.format,
    currentCfi: null,
    currentPage: opts.format === "pdf" ? 1 : null,
    createdAt: Date.now(),
  };
}
