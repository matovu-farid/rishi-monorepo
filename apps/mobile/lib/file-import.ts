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
import { Book } from "@/types/book";
import { createMobileBookImportService } from "@/lib/book-import";
import { embedBook } from "@/lib/rag/pipeline";
import type { BookFormat } from "@rishi/shared/book-import";
import { IS_E2E_TEST } from "@/app/_layout";
import { getSessionToken } from "@/lib/auth";
import { shouldSkipIndexing } from "@/lib/file-import-index-gate";

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

export type ImportOutcome =
  | { ok: true; book: Book }
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

function generateUUID(): string {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
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
  const bookId = generateUUID();

  const service = createMobileBookImportService({
    bookId,
    format: opts.format,
    title: opts.title,
    author: opts.author,
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

export async function importBookFromUrl(url: string): Promise<Book> {
  if (!url.startsWith("http://") && !url.startsWith("https://")) {
    throw new Error("Invalid URL — must start with http:// or https://");
  }

  let format = detectFormatFromUrl(url);

  if (!format) {
    try {
      const headRes = await fetch(url, { method: "HEAD" });
      format = detectFormatFromContentType(headRes.headers.get("content-type"));
    } catch {
      // HEAD failed, will try download anyway and check content-type there
    }
  }

  const downloadRes = await fetch(url);

  if (!downloadRes.ok) {
    throw new Error(
      `Download failed: ${downloadRes.status} ${downloadRes.statusText}`,
    );
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
  const result = await runImportWithService({
    sourceUri: tmpFile.uri,
    format,
    title,
  });

  // Clean up the tmp file; the service copied it to book.<format>.
  try {
    tmpFile.delete();
  } catch {
    /* best-effort */
  }

  if (!result.ok) {
    throw new Error(`Import failed at stage=${result.stage}: ${result.error}`);
  }
  return result.book;
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
